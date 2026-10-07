// The store owns all visitor-side state and is the only place that talks to the
// API and the socket. The UI is a pure function of the snapshot it reads, which
// keeps re-renders cheap and makes the send path (optimistic message, then
// reconciliation by clientMessageId) explicit.

import { ApiError, VisitorApi } from './api.js';
import type { ResolvedOptions } from './config.js';
import { VisitorSocket, type SocketStatus } from './socket.js';
import {
  toChatMessage,
  type ChatMessage,
  type Conversation,
  type Message,
  type RealtimeEvent,
} from './types.js';

const MAX_CACHED_MESSAGES = 300;
const TYPING_TTL_MS = 4_000;

export interface Snapshot {
  status: 'IDLE' | 'BOOTSTRAPPING' | 'READY' | 'FAILED';
  error?: string;
  open: boolean;
  unread: number;
  conversations: Conversation[];
  activeId?: string;
  messages: ChatMessage[];
  hasMore: boolean;
  agentTyping: boolean;
  agentsOnline: number;
  aiEnabled: boolean;
  connection: SocketStatus;
  uploading: number;
  offline: boolean;
  welcomeMessage: string;
  offlineMessage: string;
  rated?: number;
}

interface StoredSession {
  visitorId: string;
  token: string;
  expiresAt: number;
  conversations: Conversation[];
}

type Listener = (snapshot: Snapshot) => void;

function localId(): string {
  return 'local-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8);
}

function mergeMessages(existing: ChatMessage[], incoming: ChatMessage[]): ChatMessage[] {
  const byId = new Map<string, ChatMessage>();
  const byClientId = new Map<string, ChatMessage>();
  for (const message of existing) {
    byId.set(message.id, message);
    if (message.localId) {
      byClientId.set(message.localId, message);
    }
  }
  for (const message of incoming) {
    // A message the server echoes back is the same one we sent optimistically;
    // matching on the local id keeps the row from appearing twice.
    const twin = byClientId.get(message.id);
    if (twin && twin.delivery !== 'SENT') {
      byId.delete(twin.id);
    }
    byId.set(message.id, message);
  }
  const merged = Array.from(byId.values());
  merged.sort((a, b) => {
    if (a.sequence !== b.sequence) {
      // Optimistic messages have no sequence yet; keep them at the end.
      if (a.sequence === 0) {
        return 1;
      }
      if (b.sequence === 0) {
        return -1;
      }
      return a.sequence - b.sequence;
    }
    return a.createdAt.localeCompare(b.createdAt);
  });
  return merged.slice(-MAX_CACHED_MESSAGES);
}

export class ChatStore {
  readonly #options: ResolvedOptions;
  readonly #api: VisitorApi;
  readonly #socket: VisitorSocket;
  readonly #listeners = new Set<Listener>();
  #state: Snapshot;
  #typingTimer?: ReturnType<typeof setTimeout>;
  #typingSentAt = 0;
  #pollTimer?: ReturnType<typeof setInterval>;

  constructor(options: ResolvedOptions) {
    this.#options = options;
    this.#api = new VisitorApi(options.endpoint);
    this.#state = {
      status: 'IDLE',
      open: false,
      unread: 0,
      conversations: [],
      messages: [],
      hasMore: false,
      agentTyping: false,
      agentsOnline: 0,
      aiEnabled: false,
      connection: 'CLOSED',
      uploading: 0,
      offline: false,
      welcomeMessage: options.welcomeMessage,
      offlineMessage: options.offlineMessage,
    };
    this.#socket = new VisitorSocket(options.endpoint, {
      getToken: () => this.#api.token,
      onEvent: (event) => this.#handleEvent(event),
      onStatus: (status) => this.#patch({ connection: status }),
      onReconnect: () => {
        this.#resubscribe();
        void this.#resync();
      },
    });
  }

  get snapshot(): Snapshot {
    return this.#state;
  }

  get options(): ResolvedOptions {
    return this.#options;
  }

  /** Absolute, token-carrying URL for a stored attachment. */
  fileUrl(url: string): string {
    return this.#api.fileUrl(url);
  }

  subscribe(listener: Listener): () => void {
    this.#listeners.add(listener);
    listener(this.#state);
    return () => this.#listeners.delete(listener);
  }

  async init(): Promise<void> {
    if (this.#state.status === 'BOOTSTRAPPING' || this.#state.status === 'READY') {
      return;
    }
    this.#patch({ status: 'BOOTSTRAPPING', error: undefined });
    const cached = this.#readSession();
    try {
      if (cached) {
        this.#api.setToken(cached.token);
        if (cached.conversations.length) {
          this.#patch({ conversations: cached.conversations });
        }
        // Verify the token before trusting it; an expired one answers 401 and
        // falls through to a fresh bootstrap.
        try {
          const live = await this.#api.listConversations();
          this.#patch({
            status: 'READY',
            conversations: live.items ?? [],
            activeId: this.#pickActive(live.items ?? []),
          });
          this.#afterReady();
          return;
        } catch (error) {
          if (!(error instanceof ApiError) || !error.isAuthError) {
            throw error;
          }
        }
      }
      await this.#bootstrap();
    } catch (error) {
      this.#patch({ status: 'FAILED', error: error instanceof Error ? error.message : '初始化失败' });
      this.#emit({ type: 'error', data: this.#state.error });
    }
  }

  async #bootstrap(): Promise<void> {
    const bridge = this.#options.bridge?.getVisitor?.();
    const result = await this.#api.bootstrap({
      inboxKey: this.#options.inboxKey,
      externalId: bridge?.externalId ?? this.#options.externalId,
      displayName: bridge?.displayName ?? this.#options.displayName,
      email: bridge?.email ?? this.#options.email,
      phone: bridge?.phone ?? this.#options.phone,
      locale: this.#options.locale ?? (typeof navigator !== 'undefined' ? navigator.language : undefined),
      attributes: this.#options.attributes,
      referrer: this.#options.referrer ?? (typeof document !== 'undefined' ? document.referrer : undefined),
    });
    this.#api.setToken(result.token);
    this.#writeSession({
      visitorId: result.visitorId,
      token: result.token,
      expiresAt: Date.now() + Math.max(result.expiresIn - 60, 60) * 1000,
      conversations: this.#state.conversations,
    });
    const conversations = await this.#api.listConversations().then((page) => page.items ?? []).catch(() => []);
    this.#patch({
      status: 'READY',
      agentsOnline: result.agentsOnline,
      aiEnabled: result.aiEnabled,
      welcomeMessage: result.inbox.welcomeMessage || this.#options.welcomeMessage,
      offlineMessage: result.inbox.offlineMessage || this.#options.offlineMessage,
      conversations,
      activeId: this.#pickActive(conversations),
    });
    this.#afterReady();
  }

  #afterReady(): void {
    this.#socket.connect();
    if (this.#state.activeId) {
      this.#socket.subscribe(this.#state.activeId);
      void this.#loadMessages(this.#state.activeId);
    }
    this.#emit({ type: 'ready', data: { visitorReady: true } });
    // A slow safety net: notifications are pushed, but a proxy that silently
    // drops an idle socket still resolves within one interval.
    this.#pollTimer = setInterval(() => {
      if (this.#state.open && (this.#state.connection !== 'OPEN' || document.visibilityState === 'visible')) {
        void this.#resync();
      }
    }, 20_000);
  }

  destroy(): void {
    this.#socket.close();
    if (this.#pollTimer) {
      clearInterval(this.#pollTimer);
      this.#pollTimer = undefined;
    }
    if (this.#typingTimer) {
      clearTimeout(this.#typingTimer);
      this.#typingTimer = undefined;
    }
    this.#listeners.clear();
  }

  open(): void {
    this.#patch({ open: true, unread: 0 });
    this.#emit({ type: 'open' });
    if (this.#state.status === 'IDLE') {
      void this.init();
      return;
    }
    if (this.#state.activeId) {
      void this.#markRead();
    }
  }

  close(): void {
    this.#patch({ open: false });
    this.#emit({ type: 'close' });
  }

  toggle(): void {
    if (this.#state.open) {
      this.close();
    } else {
      this.open();
    }
  }

  async selectConversation(id: string): Promise<void> {
    if (this.#state.activeId === id) {
      return;
    }
    const previous = this.#state.activeId;
    if (previous) {
      this.#socket.unsubscribe(previous);
    }
    this.#patch({ activeId: id, messages: [], hasMore: false, rated: undefined });
    this.#socket.subscribe(id);
    await this.#loadMessages(id);
  }

  /** Returns to the conversation picker and drops the open thread. */
  clearActive(): void {
    const previous = this.#state.activeId;
    if (!previous) {
      return;
    }
    this.#socket.unsubscribe(previous);
    this.#patch({ activeId: undefined, messages: [], hasMore: false, rated: undefined, agentTyping: false });
  }

  /** Starts a new conversation, optionally with the first message included. */
  async startConversation(content: string, subject?: string): Promise<void> {
    const optimistic: ChatMessage | undefined = content.trim()
      ? {
          id: localId(),
          localId: '',
          conversationId: '',
          senderType: 'VISITOR',
          sequence: 0,
          messageType: 'TEXT',
          content,
          attachments: [],
          createdAt: new Date().toISOString(),
          delivery: 'SENDING',
        }
      : undefined;
    if (optimistic) {
      optimistic.localId = optimistic.id;
      this.#patch({ messages: [...this.#state.messages, optimistic] });
    }
    try {
      const created = await this.#api.createConversation(subject ?? this.#options.subject ?? '', content, this.#options.embedded ? 'APP' : 'WEB');
      const conversations = [created.conversation, ...this.#state.conversations.filter((item) => item.id !== created.conversation.id)];
      this.#patch({ conversations, activeId: created.conversation.id });
      this.#writeSession({ ...this.#requireSession(), conversations });
      this.#socket.subscribe(created.conversation.id);
      await this.#loadMessages(created.conversation.id);
      this.#emit({ type: 'conversation', data: created.conversation });
    } catch (error) {
      if (optimistic) {
        this.#failMessage(optimistic.localId, error);
      }
      this.#emit({ type: 'error', data: error instanceof Error ? error.message : '创建会话失败' });
    }
  }

  async loadMore(): Promise<void> {
    const id = this.#state.activeId;
    if (!id) {
      return;
    }
    const first = this.#state.messages.find((message) => message.sequence > 0);
    const before = first?.sequence ?? 0;
    if (before <= 1) {
      this.#patch({ hasMore: false });
      return;
    }
    const page = await this.#api.listMessages(id, 0, 200).catch(() => undefined);
    if (!page?.items) {
      return;
    }
    // The endpoint pages forward only, so "load more" moves the window back by
    // asking for the oldest slice and keeping the newest cached messages.
    const older = page.items.filter((message) => message.sequence < before).map(toChatMessage);
    this.#patch({ messages: mergeMessages([...older, ...this.#state.messages], []), hasMore: older.length >= 200 });
  }

  async send(content: string, attachmentIds: string[] = [], messageType: ChatMessage['messageType'] = 'TEXT'): Promise<void> {
    let id = this.#state.activeId;
    const text = content.trim();
    if (!text && attachmentIds.length === 0) {
      return;
    }
    const optimistic: ChatMessage = {
      id: localId(),
      localId: '',
      conversationId: id ?? '',
      senderType: 'VISITOR',
      sequence: 0,
      messageType,
      content: text,
      attachments: [],
      createdAt: new Date().toISOString(),
      delivery: 'SENDING',
    };
    optimistic.localId = optimistic.id;
    this.#patch({ messages: [...this.#state.messages, optimistic] });

    if (!id) {
      await this.startConversation(text);
      return;
    }
    try {
      const saved = await this.#api.sendMessage(id, {
        content: text,
        clientMessageId: optimistic.localId,
        messageType,
        attachmentIds,
      });
      saved.attachments = this.#resolveAttachments(saved, optimistic);
      this.#patch({ messages: mergeMessages(this.#state.messages, [toChatMessage(saved)]) });
      this.#emit({ type: 'sent', data: saved });
      void this.#refreshActiveSummary(id);
    } catch (error) {
      if (error instanceof ApiError && error.isAuthError) {
        await this.#recoverToken();
      }
      this.#failMessage(optimistic.localId, error);
      this.#emit({ type: 'failed', data: { localId: optimistic.localId, message: error instanceof Error ? error.message : '发送失败' } });
    }
  }

  async sendFiles(files: FileList | File[]): Promise<void> {
    const id = this.#state.activeId;
    const list = Array.from(files);
    if (!list.length) {
      return;
    }
    if (!id) {
      this.#emit({ type: 'error', data: '请先发送一条消息以开始对话' });
      return;
    }
    for (const file of list) {
      await this.#sendOneFile(id, file);
    }
  }

  async #sendOneFile(conversationId: string, file: File): Promise<void> {
    const placeholder: ChatMessage = {
      id: localId(),
      localId: '',
      conversationId,
      senderType: 'VISITOR',
      sequence: 0,
      messageType: file.type.startsWith('image/') ? 'IMAGE' : 'FILE',
      content: file.name,
      attachments: [
        {
          id: '',
          fileName: file.name,
          contentType: file.type || 'application/octet-stream',
          sizeBytes: file.size,
          url: file.type.startsWith('image/') ? URL.createObjectURL(file) : '',
        },
      ],
      createdAt: new Date().toISOString(),
      delivery: 'SENDING',
    };
    placeholder.localId = placeholder.id;
    this.#patch({ messages: [...this.#state.messages, placeholder], uploading: this.#state.uploading + 1 });
    try {
      const uploaded = await this.#api.upload(conversationId, file);
      const saved = await this.#api.sendMessage(conversationId, {
        content: file.name,
        clientMessageId: placeholder.localId,
        messageType: placeholder.messageType,
        attachmentIds: [uploaded.id],
      });
      saved.attachments = saved.attachments?.length ? saved.attachments : [uploaded];
      this.#patch({ messages: mergeMessages(this.#state.messages, [toChatMessage(saved)]) });
      this.#emit({ type: 'sent', data: saved });
      void this.#refreshActiveSummary(conversationId);
    } catch (error) {
      this.#failMessage(placeholder.localId, error);
      this.#emit({ type: 'failed', data: { localId: placeholder.localId, message: error instanceof Error ? error.message : '上传失败' } });
    } finally {
      this.#patch({ uploading: Math.max(this.#state.uploading - 1, 0) });
    }
  }

  /** Re-sends a message that failed, reusing its original local id. */
  async retry(localIdValue: string): Promise<void> {
    const target = this.#state.messages.find((message) => message.localId === localIdValue);
    if (!target) {
      return;
    }
    const attachmentIds = target.attachments.map((attachment) => attachment.id).filter(Boolean);
    this.#patch({
      messages: this.#state.messages.map((message) =>
        message.localId === localIdValue ? { ...message, delivery: 'SENDING', error: undefined } : message,
      ),
    });
    const id = this.#state.activeId;
    if (!id) {
      await this.startConversation(target.content);
      return;
    }
    try {
      const saved = await this.#api.sendMessage(id, {
        content: target.content,
        clientMessageId: target.localId,
        messageType: target.messageType,
        attachmentIds,
      });
      this.#patch({ messages: mergeMessages(this.#state.messages, [toChatMessage(saved)]) });
    } catch (error) {
      this.#failMessage(localIdValue, error);
    }
  }

  async rate(score: number, comment = ''): Promise<void> {
    const id = this.#state.activeId;
    if (!id) {
      return;
    }
    try {
      await this.#api.rate(id, score, comment);
      this.#patch({ rated: score });
      this.#emit({ type: 'rating', data: { score } });
    } catch (error) {
      this.#emit({ type: 'error', data: error instanceof Error ? error.message : '评价失败' });
    }
  }

  /** Mentions that the visitor is composing, throttled to one frame per 3s. */
  notifyTyping(): void {
    const id = this.#state.activeId;
    if (!id) {
      return;
    }
    const now = Date.now();
    if (now - this.#typingSentAt < 3_000) {
      return;
    }
    this.#typingSentAt = now;
    if (this.#socket.connected) {
      this.#socket.sendTyping(id);
    } else {
      void this.#api.typing(id).catch(() => undefined);
    }
  }

  async #markRead(): Promise<void> {
    const id = this.#state.activeId;
    if (!id || this.#state.status !== 'READY') {
      return;
    }
    const last = this.#state.messages[this.#state.messages.length - 1];
    if (this.#socket.connected) {
      this.#socket.sendRead(id);
    } else {
      await this.#api.markRead(id, last?.sequence ?? 0).catch(() => undefined);
    }
    this.#patch({
      conversations: this.#state.conversations.map((item) => (item.id === id ? { ...item, visitorUnread: 0 } : item)),
    });
  }

  async #loadMessages(id: string): Promise<void> {
    try {
      const page = await this.#api.listMessages(id, 0, 100);
      const messages = (page.items ?? []).map(toChatMessage);
      this.#patch({ messages: mergeMessages(this.#state.messages, messages), hasMore: page.hasMore });
      if (this.#state.open) {
        void this.#markRead();
      }
    } catch (error) {
      if (error instanceof ApiError && error.isAuthError) {
        await this.#recoverToken();
      }
    }
  }

  /**
   * Pulls the conversation list and the active thread from REST. Runs after a
   * reconnect and on a slow timer, so a missed push can only ever be a delay.
   */
  async #resync(): Promise<void> {
    if (this.#state.status !== 'READY') {
      return;
    }
    try {
      const conversations = await this.#api.listConversations();
      this.#patch({ conversations: conversations.items ?? [], agentsOnline: this.#state.agentsOnline });
      const id = this.#state.activeId;
      if (!id) {
        return;
      }
      const last = this.#state.messages.filter((message) => message.sequence > 0).at(-1);
      const page = await this.#api.listMessages(id, last?.sequence ?? 0, 100);
      if (page.items?.length) {
        this.#patch({ messages: mergeMessages(this.#state.messages, page.items.map(toChatMessage)) });
        if (this.#state.open) {
          void this.#markRead();
        }
      }
      const fresh = (conversations.items ?? []).find((item) => item.id === id);
      if (fresh) {
        this.#patch({ rated: fresh.status === 'RESOLVED' ? this.#state.rated : undefined });
      }
    } catch (error) {
      if (error instanceof ApiError && error.isAuthError) {
        await this.#recoverToken();
      }
    }
  }

  async #refreshActiveSummary(id: string): Promise<void> {
    const conversation = await this.#api.getConversation(id).catch(() => undefined);
    if (!conversation) {
      return;
    }
    const conversations = this.#state.conversations.map((item) => (item.id === id ? conversation : item));
    if (!conversations.some((item) => item.id === id)) {
      conversations.unshift(conversation);
    }
    this.#patch({ conversations });
    this.#writeSession({ ...this.#requireSession(), conversations });
  }

  #handleEvent(event: RealtimeEvent): void {
    switch (event.type) {
      case 'message.created': {
        const message = event.data as Message | undefined;
        if (!message?.id || !message.conversationId) {
          return;
        }
        if (message.conversationId === this.#state.activeId) {
          this.#patch({ messages: mergeMessages(this.#state.messages, [toChatMessage(message)]) });
          if (this.#state.open) {
            void this.#markRead();
          }
        } else if (message.senderType !== 'VISITOR' && !this.#state.open) {
          this.#patch({ unread: this.#state.unread + 1 });
          this.#emit({ type: 'unread', data: { count: this.#state.unread } });
        }
        this.#emit({ type: 'message', data: message });
        const known = this.#state.conversations.find((item) => item.id === message.conversationId);
        if (!known) {
          void this.#resync();
        } else {
          this.#patch({
            conversations: this.#state.conversations.map((item) =>
              item.id === message.conversationId
                ? {
                    ...item,
                    lastSequence: Math.max(item.lastSequence, message.sequence),
                    lastMessagePreview: message.content.slice(0, 80),
                    lastMessageAt: message.createdAt,
                    status: item.status === 'RESOLVED' ? 'OPEN' : item.status,
                  }
                : item,
            ),
          });
        }
        break;
      }
      case 'conversation.created':
      case 'conversation.updated':
      case 'conversation.closed': {
        const conversation = event.data as Conversation | undefined;
        if (!conversation?.id) {
          void this.#resync();
          return;
        }
        const exists = this.#state.conversations.some((item) => item.id === conversation.id);
        const conversations = exists
          ? this.#state.conversations.map((item) => (item.id === conversation.id ? { ...item, ...conversation } : item))
          : [conversation, ...this.#state.conversations];
        this.#patch({ conversations });
        if (conversation.id === this.#state.activeId) {
          this.#patch({ rated: conversation.status === 'RESOLVED' ? this.#state.rated : undefined });
        }
        this.#emit({ type: 'conversation', data: conversation });
        break;
      }
      case 'conversation.assigned': {
        const data = event.data as { assigneeId?: string } | undefined;
        if (event.conversationId === this.#state.activeId && data?.assigneeId) {
          this.#patch({ rated: this.#state.rated });
        }
        void this.#resync();
        break;
      }
      case 'typing': {
        const data = event.data as { actorType?: string; actorName?: string } | undefined;
        if (event.conversationId !== this.#state.activeId || data?.actorType !== 'AGENT') {
          return;
        }
        this.#patch({ agentTyping: true });
        if (this.#typingTimer) {
          clearTimeout(this.#typingTimer);
        }
        this.#typingTimer = setTimeout(() => this.#patch({ agentTyping: false }), TYPING_TTL_MS);
        break;
      }
      case 'conversation.read': {
        break;
      }
      default:
        break;
    }
  }

  #resolveAttachments(saved: Message, optimistic: ChatMessage): Message['attachments'] {
    if (saved.attachments?.length) {
      return saved.attachments;
    }
    // The save response can race the attachment link read; fall back to what we
    // already know locally so the thumbnail does not disappear.
    const known = this.#state.messages.find((message) => message.localId === optimistic.localId);
    return known?.attachments.length ? (known.attachments as Message['attachments']) : saved.attachments;
  }

  #failMessage(localIdValue: string, error: unknown): void {
    const message = error instanceof Error ? error.message : '发送失败';
    this.#patch({
      messages: this.#state.messages.map((item) =>
        item.localId === localIdValue ? { ...item, delivery: 'FAILED', error: message } : item,
      ),
    });
  }

  /** Re-bootstraps silently when the visitor token has expired mid-session. */
  async #recoverToken(): Promise<void> {
    try {
      await this.#bootstrap();
    } catch {
      this.#patch({ status: 'FAILED', error: '登录状态已过期，请刷新页面' });
    }
  }

  #pickActive(conversations: Conversation[]): string | undefined {
    const open = conversations.find((item) => item.status !== 'RESOLVED');
    return (open ?? conversations[0])?.id;
  }

  #resubscribe(): void {
    for (const conversation of this.#state.conversations.slice(0, 10)) {
      this.#socket.subscribe(conversation.id);
    }
  }

  #emit(event: { type: string; data?: unknown }): void {
    this.#options.onEvent?.(event as never);
    this.#options.bridge?.postMessage?.(JSON.stringify(event));
  }

  #patch(partial: Partial<Snapshot>): void {
    this.#state = { ...this.#state, ...partial };
    for (const listener of this.#listeners) {
      listener(this.#state);
    }
  }

  #storageKey(): string {
    return `${this.#options.storage}.${this.#options.inboxKey}`;
  }

  #readSession(): StoredSession | undefined {
    if (!this.#options.storage || typeof localStorage === 'undefined') {
      return undefined;
    }
    try {
      const raw = localStorage.getItem(this.#storageKey());
      if (!raw) {
        return undefined;
      }
      const parsed = JSON.parse(raw) as StoredSession;
      if (!parsed.token || !parsed.expiresAt || parsed.expiresAt < Date.now()) {
        return undefined;
      }
      return parsed;
    } catch {
      return undefined;
    }
  }

  #writeSession(session: StoredSession): void {
    if (!this.#options.storage || typeof localStorage === 'undefined') {
      return;
    }
    try {
      localStorage.setItem(this.#storageKey(), JSON.stringify(session));
    } catch {
      // Private mode or a full quota: the session simply is not remembered.
    }
  }

  #requireSession(): StoredSession {
    return (
      this.#readSession() ?? {
        visitorId: '',
        token: this.#api.token,
        expiresAt: Date.now() + 3_600_000,
        conversations: this.#state.conversations,
      }
    );
  }
}
