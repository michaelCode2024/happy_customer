import type { ChannelPresentation, ChannelItem } from "./types.js";
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
  type QuotedMessage,
  type RealtimeEvent,
  type SearchHit,
} from './types.js';

const MAX_CACHED_MESSAGES = 300;
const TYPING_TTL_MS = 4_000;
const PAGE_SIZE = 50;

export interface Snapshot {
 automation?: ChannelPresentation;
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
  /** The message being quoted, set while the visitor composes a reply to it. */
  replyTo?: QuotedMessage;
  /** Highest sequence in the open thread at the moment it was last read. */
  readBoundary: number;
  loadingOlder: boolean;
  search: {
    query: string;
    running: boolean;
    hits: SearchHit[];
    error?: string;
  };
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

/**
 * Merges a reaction update into a thread. The server publishes one event per
 * toggle carrying the full aggregate for that message, so an event replaces the
 * reactions of the message it names and leaves the rest alone. Matching on the
 * message id rather than on the event's position matters when a reaction lands
 * out of order, which the socket does not promise.
 */
function mergeReactions(messages: ChatMessage[], messageId: string, reactions: ChatMessage['reactions']): ChatMessage[] {
  return messages.map((message) => (message.id === messageId ? { ...message, reactions } : message));
}

function mergeMessages(existing: ChatMessage[], incoming: ChatMessage[]): ChatMessage[] {
  const byId = new Map<string, ChatMessage>();
  // The optimistic row a send created is keyed by its local id, and the server
  // echoes that id back as clientMessageId. Indexing on both is what stops a
  // sent message from appearing twice: once greyed out and once delivered.
  const byClientId = new Map<string, ChatMessage>();
  for (const message of existing) {
    byId.set(message.id, message);
    byClientId.set(message.clientMessageId ?? message.localId, message);
  }
  for (const message of incoming) {
    const twin = byClientId.get(message.clientMessageId ?? message.localId);
    if (twin && twin.id !== message.id) {
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
  // 原始文件仅保留在当前页面内，用于上传失败重试，不写入本地持久化存储。
  readonly #pendingFiles = new Map<string, File>();
  #attachmentConversation?: Promise<void>;
  #typingTimer?: ReturnType<typeof setTimeout>;
  #typingSentAt = 0;
  #pollTimer?: ReturnType<typeof setInterval>;
  #deliveredSequence = 0;
  #receivedEvents = new Set<string>();
  #readAcknowledged = new Map<string, number>();
  #deliveredTimer?: ReturnType<typeof setTimeout>;

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
      readBoundary: 0,
      loadingOlder: false,
      search: { query: '', running: false, hits: [] },
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
    // 登录身份切换时重新验证票据，不能沿用匿名或上一个用户的缓存身份。
    const cached = (this.#options.identityToken || this.#options.bridge?.getVisitor?.()?.identityToken) ? undefined : this.#readSession();
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
            agentsOnline: live.agentsOnline ?? 0,
            aiEnabled: live.aiEnabled ?? false,
            automation: live.automation,
            welcomeMessage: live.welcomeMessage || this.#options.welcomeMessage,
            offlineMessage: live.offlineMessage || this.#options.offlineMessage,
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
      identityToken: bridge?.identityToken ?? this.#options.identityToken,
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
      automation: result.inbox.automation,
      welcomeMessage: result.inbox.welcomeMessage || this.#options.welcomeMessage,
      offlineMessage: result.inbox.offlineMessage || this.#options.offlineMessage,
      conversations,
      activeId: this.#pickActive(conversations),
    });
    this.#afterReady();
  }

  #onVisible = (): void => { if (this.#state.open && document.visibilityState === 'visible') { void this.#resync(); } };

  #afterReady(): void {
    if (typeof document !== 'undefined') document.addEventListener('visibilitychange', this.#onVisible);
    if (typeof window !== 'undefined') window.addEventListener('focus', this.#onVisible);
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
    if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', this.#onVisible);
    if (typeof window !== 'undefined') window.removeEventListener('focus', this.#onVisible);
    this.#pendingFiles.clear();
    this.#socket.close();
    if (this.#pollTimer) {
      clearInterval(this.#pollTimer);
      this.#pollTimer = undefined;
    }
    if (this.#typingTimer) {
      clearTimeout(this.#typingTimer);
      this.#typingTimer = undefined;
    }
    if (this.#deliveredTimer) {
      clearTimeout(this.#deliveredTimer);
      this.#deliveredTimer = undefined;
    }
    this.#listeners.clear();
  }

  open(): void {
    this.#patch({ open: true });
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
    this.#patch({
      activeId: id,
      messages: [],
      hasMore: false,
      rated: undefined,
      replyTo: undefined,
      readBoundary: 0,
      search: { query: '', running: false, hits: [] },
    });
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
    this.#patch({
      activeId: undefined,
      messages: [],
      hasMore: false,
      rated: undefined,
      agentTyping: false,
      replyTo: undefined,
      readBoundary: 0,
      search: { query: '', running: false, hits: [] },
    });
  }

  /**
   * Quotes a message in the composer. The quote is a snapshot taken now: if the
   * original is edited or recalled later, the visitor's reply still shows what
   * they were answering.
   */
  quote(message: ChatMessage): void {
    this.#patch({
      replyTo: {
        id: message.id,
        sequence: message.sequence,
        senderType: message.senderType,
        senderName: message.senderName,
        messageType: message.messageType,
        content: message.content,
        deletedAt: message.deletedAt,
      },
    });
  }

  clearQuote(): void {
    this.#patch({ replyTo: undefined });
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
          reactions: [],
        }
      : undefined;
    if (optimistic) {
      optimistic.localId = optimistic.id;
      this.#patch({ messages: [...this.#state.messages, optimistic] });
    }
    try {
      const created = await this.#api.createConversation(subject ?? this.#options.subject ?? '', content, this.#options.source ?? (this.#options.embedded ? 'APP' : 'WEB'));
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

  /**
   * Reads one page further back in history. `before` is the sequence of the
   * oldest message currently rendered, so the server returns what precedes it
   * without re-sending what is already on screen.
   */
  async loadOlder(): Promise<void> {
    const id = this.#state.activeId;
    if (!id || this.#state.loadingOlder) {
      return;
    }
    const oldest = this.#state.messages.find((message) => message.sequence > 0);
    if (!oldest) {
      return;
    }
    this.#patch({ loadingOlder: true });
    try {
      const page = await this.#api.pageMessages(id, { before: oldest.sequence, limit: PAGE_SIZE });
      const older = (page.items ?? []).map(toChatMessage);
      this.#patch({
        messages: mergeMessages([...older, ...this.#state.messages], []),
        hasMore: page.hasOlder,
      });
    } catch {
      // A failed page leaves the scroll position alone; the visitor can retry
      // by scrolling again.
    } finally {
      this.#patch({ loadingOlder: false });
    }
  }

  /** Kept as an alias so existing call sites keep working. */
  async loadMore(): Promise<void> {
    return this.loadOlder();
  }

  /**
   * Searches the open thread. The server returns excerpts with the matched
   * terms already wrapped in << >>, so the UI highlights what the database
   * actually matched rather than re-implementing the tokenizer in the browser.
   */
  async search(query: string): Promise<void> {
    const id = this.#state.activeId;
    const trimmed = query.trim();
    if (!id) {
      return;
    }
    if (!trimmed) {
      this.#patch({ search: { query: '', running: false, hits: [] } });
      return;
    }
    this.#patch({ search: { query: trimmed, running: true, hits: this.#state.search.hits } });
    try {
      const result = await this.#api.search(id, trimmed);
      // A slow response must not overwrite a newer query's results.
      if (this.#state.search.query !== trimmed) {
        return;
      }
      this.#patch({ search: { query: trimmed, running: false, hits: result.items ?? [] } });
    } catch (error) {
      if (this.#state.search.query !== trimmed) {
        return;
      }
      this.#patch({
        search: {
          query: trimmed,
          running: false,
          hits: [],
          error: error instanceof Error ? error.message : '搜索失败',
        },
      });
    }
  }

  clearSearch(): void {
    this.#patch({ search: { query: '', running: false, hits: [] } });
  }

  async selectChannelItem(item: ChannelItem): Promise<void> {
    if (item.action === 'LINK') return;
    // 菜单动作由服务器重新校验，客户端不能指定任意机器人回复内容。
    await this.send(item.title, [], 'TEXT', undefined, { menuId: item.id });
  }

  async send(
    content: string,
    attachmentIds: string[] = [],
    messageType: ChatMessage['messageType'] = 'TEXT',
    replyToId?: string,
    metadata?: Record<string, unknown>,
  ): Promise<void> {
    let id = this.#state.activeId;
    const text = content.trim();
    if (!text && attachmentIds.length === 0) {
      return;
    }
    const quote = this.#state.replyTo;
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
      replyTo: quote,
      metadata,
      reactions: [],
    };
    optimistic.localId = optimistic.id;
    this.#patch({ messages: [...this.#state.messages, optimistic], replyTo: undefined });

    if (!id) {
      // 首条文字也走带 clientMessageId 的发送接口，避免建会话首消息
      // 与乐观消息使用不同标识，造成重复气泡和永久“发送中”。
      id = await this.#ensureAttachmentConversation();
      if (!id) {
        this.#failMessage(optimistic.localId, new Error('创建会话失败，请重试'));
        return;
      }
      optimistic.conversationId = id;
    }
    try {
      const saved = await this.#api.sendMessage(id, {
        content: text,
        clientMessageId: optimistic.localId,
        messageType,
        attachmentIds,
        replyToId: replyToId ?? quote?.id,
        metadata,
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

  /**
   * Sends a recorded voice note. The browser records to a Blob, the upload
   * endpoint stores it as an attachment, and the message that references it is
   * typed AUDIO so the transcript renders a player rather than a download link.
   * Duration travels in metadata because the player needs it before the audio
   * element has loaded enough to report it.
   */
  async sendVoice(blob: Blob, durationMs: number): Promise<void> {
    const id = await this.#ensureAttachmentConversation();
    if (!id) {
      this.#emit({ type: 'error', data: '请先发送一条消息以开始对话' });
      return;
    }
    const extension = blob.type.includes('ogg') ? 'ogg' : blob.type.includes('mp4') ? 'm4a' : 'webm';
    const file = new File([blob], `voice-${Date.now()}.${extension}`, {
      type: blob.type || 'audio/webm',
    });
    const placeholder: ChatMessage = {
      id: localId(),
      localId: '',
      conversationId: id,
      senderType: 'VISITOR',
      sequence: 0,
      messageType: 'AUDIO',
      content: '语音消息',
      attachments: [
        {
          id: '',
          fileName: file.name,
          contentType: file.type,
          sizeBytes: file.size,
          url: URL.createObjectURL(blob),
        },
      ],
      createdAt: new Date().toISOString(),
      delivery: 'SENDING',
      reactions: [],
      metadata: { durationMs: Math.round(durationMs) },
    };
    placeholder.localId = placeholder.id;
    this.#pendingFiles.set(placeholder.localId, file);
    this.#patch({ messages: [...this.#state.messages, placeholder], uploading: this.#state.uploading + 1 });
    try {
      const uploaded = await this.#api.upload(id, file);
      placeholder.attachments = [uploaded];
      const saved = await this.#api.sendMessage(id, {
        content: '语音消息',
        clientMessageId: placeholder.localId,
        messageType: 'AUDIO',
        attachmentIds: [uploaded.id],
        metadata: { durationMs: Math.round(durationMs) },
      });
      saved.attachments = saved.attachments?.length ? saved.attachments : [uploaded];
      this.#pendingFiles.delete(placeholder.localId);
      this.#patch({ messages: mergeMessages(this.#state.messages, [toChatMessage(saved)]) });
      this.#emit({ type: 'sent', data: saved });
      void this.#refreshActiveSummary(id);
    } catch (error) {
      this.#failMessage(placeholder.localId, error);
      this.#emit({ type: 'failed', data: { localId: placeholder.localId, message: error instanceof Error ? error.message : '语音发送失败' } });
    } finally {
      this.#patch({ uploading: Math.max(this.#state.uploading - 1, 0) });
    }
  }

  async sendFiles(files: FileList | File[]): Promise<void> {
    const list = Array.from(files);
    if (!list.length) {
      return;
    }
    const id = await this.#ensureAttachmentConversation();
    if (!id) {
      this.#emit({ type: 'error', data: '请先发送一条消息以开始对话' });
      return;
    }
    for (const file of list) {
      await this.#sendOneFile(id, file);
    }
  }

  async #ensureAttachmentConversation(): Promise<string | undefined> {
    if (this.#state.activeId) return this.#state.activeId;
    // 首条消息允许是附件；并发选择文件时共享建会话请求，避免重复会话。
    this.#attachmentConversation ??= this.startConversation('');
    try {
      await this.#attachmentConversation;
      return this.#state.activeId;
    } finally {
      this.#attachmentConversation = undefined;
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
      reactions: [],
    };
    placeholder.localId = placeholder.id;
    this.#pendingFiles.set(placeholder.localId, file);
    this.#patch({ messages: [...this.#state.messages, placeholder], uploading: this.#state.uploading + 1 });
    try {
      const uploaded = await this.#api.upload(conversationId, file);
      placeholder.attachments = [uploaded];
      const saved = await this.#api.sendMessage(conversationId, {
        content: file.name,
        clientMessageId: placeholder.localId,
        messageType: placeholder.messageType,
        attachmentIds: [uploaded.id],
      });
      saved.attachments = saved.attachments?.length ? saved.attachments : [uploaded];
      this.#pendingFiles.delete(placeholder.localId);
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
    try {
      await this.#ensureAttachmentConversation();
      const id = this.#state.activeId!;
      if (target.messageType !== 'TEXT' && attachmentIds.length === 0) {
        const file = this.#pendingFiles.get(localIdValue);
        if (!file) throw new Error('原始文件已不可用，请重新选择文件');
        const uploaded = await this.#api.upload(id, file);
        target.attachments = [uploaded];
        attachmentIds.push(uploaded.id);
      }
      const saved = await this.#api.sendMessage(id, {
        content: target.content,
        clientMessageId: target.localId,
        messageType: target.messageType,
        attachmentIds,
        replyToId: target.replyTo?.id,
        metadata: target.metadata as Record<string, unknown> | undefined,
      });
      this.#pendingFiles.delete(localIdValue);
      saved.attachments = saved.attachments?.length ? saved.attachments : target.attachments;
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

  /**
   * 上报本机已持有的最高 sequence，让客服气泡出现「已送达」。
   * 送达 ≠ 已读：面板收起、后台标签、页面失焦时只要消息已进本地列表就应送达；
   * 只有访客真正打开并看见会话时才走 #markRead →「已读」。
   * 水位只前进；突发消息用短防抖合并成一次 REST。
   */
  #markDelivered(): void {
    const id = this.#state.activeId;
    // 故意不要求 open / visible / focus，否则已送达会被已读盖掉，三态只剩未读与已读。
    if (!id || this.#state.status !== 'READY') {
      return;
    }
    const last = this.#state.messages.filter((message) => message.sequence > 0).at(-1);
    if (!last || last.sequence <= this.#deliveredSequence) {
      return;
    }
    this.#deliveredSequence = last.sequence;
    if (this.#deliveredTimer) {
      return;
    }
    this.#deliveredTimer = setTimeout(() => {
      this.#deliveredTimer = undefined;
      const sequence = this.#deliveredSequence;
      if (sequence > 0) {
        void this.#api.markDelivered(id, sequence).catch(() => undefined);
      }
    }, 400);
  }

  /**
   * Clears the unread badge and moves the divider. The boundary is captured
   * before it is cleared so the UI can draw "以下为新消息" once and not again on
   * the next render.
   */
  async #markRead(): Promise<void> {
    const id = this.#state.activeId;
    // 已读必须面板打开且页面可见有焦点，才能与「已送达」区分开。
    if (!id || this.#state.status !== 'READY' || !this.#state.open || (typeof document !== 'undefined' && (document.visibilityState === 'hidden' || (typeof document.hasFocus === 'function' && !document.hasFocus())))) {
      return;
    }
    const last = this.#state.messages.filter((message) => message.sequence > 0).at(-1);
    const boundary = last?.sequence ?? 0;
    if (boundary <= 0) return;
    try { await this.#api.markRead(id, boundary); } catch { return; }
    const acknowledged = Math.max(boundary, this.#readAcknowledged.get(id) ?? 0);
    this.#readAcknowledged.set(id, acknowledged);
    if (this.#state.activeId !== id) { void this.#resync(); return; }
    const newerUnread = this.#state.messages.filter(m => m.sequence > acknowledged && m.senderType !== 'VISITOR').length;
    this.#patch({
      unread: this.#state.conversations.filter(item => item.id !== id).reduce((total, item) => total + (item.visitorUnread ?? 0), newerUnread),
      readBoundary: this.#state.unread > 0 || this.#state.readBoundary === 0 ? boundary : this.#state.readBoundary,
      conversations: this.#state.conversations.map((item) => (item.id === id ? { ...item, visitorUnread: newerUnread } : item)),
    });
  }

  async #loadMessages(id: string): Promise<void> {
    try {
      const page = await this.#api.pageMessages(id, { limit: PAGE_SIZE });
      const messages = (page.items ?? []).map(toChatMessage);
      // The server's unread count is what the visitor has not seen, so the
      // boundary sits that many sequences below the tail.
      const boundary =
        (page.visitorUnread ?? 0) > 0 ? Math.max((page.lastSequence ?? 0) - (page.visitorUnread ?? 0), 0) : 0;
      this.#patch({
        messages: mergeMessages(messages, this.#state.messages),
        hasMore: page.hasOlder,
        readBoundary: boundary,
      });
      this.#markDelivered();
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
      this.#patch({ conversations: conversations.items ?? [],
        unread: (conversations.items ?? []).reduce((total, item) => total + (item.visitorUnread ?? 0), 0),
        agentsOnline: conversations.agentsOnline ?? this.#state.agentsOnline,
        aiEnabled: conversations.aiEnabled ?? this.#state.aiEnabled,
        automation: conversations.automation,
        welcomeMessage: conversations.welcomeMessage || this.#state.welcomeMessage,
        offlineMessage: conversations.offlineMessage || this.#state.offlineMessage,
      });
      const id = this.#state.activeId;
      if (!id) {
        return;
      }
      const last = this.#state.messages.filter((message) => message.sequence > 0).at(-1);
      const page = await this.#api.pageMessages(id, { after: last?.sequence ?? 0, limit: PAGE_SIZE });
      if (page.items?.length) {
        this.#patch({ messages: mergeMessages(this.#state.messages, page.items.map(toChatMessage)) });
        this.#markDelivered();
      }
      // 已读仍要求面板打开；送达已在上方独立上报，避免两态粘成一步。
      if (this.#state.open) void this.#markRead();
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
        if (message?.private) return;
        if (!message?.id || !message.conversationId) {
          return;
        }
        // A visitor's own message can arrive over the socket before the POST
        // that sent it has returned. Merging on the server id and on the
        // original local id keeps it from rendering twice.
        const freshEvent = !this.#receivedEvents.has(message.id);
        this.#receivedEvents.add(message.id);
        if(this.#receivedEvents.size > 500) this.#receivedEvents.delete(this.#receivedEvents.values().next().value!);
        if (message.clientMessageId) {
          this.#patch({
            messages: this.#state.messages.filter((item) => item.localId !== message.clientMessageId),
          });
        }
        if (message.conversationId === this.#state.activeId) {
          this.#patch({ messages: mergeMessages(this.#state.messages, [toChatMessage(message)]) });
          this.#markDelivered();
          if (this.#state.open) {
            void this.#markRead();
          }
        }
        if (freshEvent && message.senderType !== 'VISITOR' && (message.conversationId !== this.#state.activeId || !this.#state.open || (typeof document !== 'undefined' && (document.visibilityState === 'hidden' || (typeof document.hasFocus === 'function' && !document.hasFocus()))))) {
          this.#patch({ unread: this.#state.unread + 1 });
          this.#emit({ type: 'unread', data: { count: this.#state.unread } });
        }
        this.#emit({ type: 'message', data: message });
        const known = this.#state.conversations.find((item) => item.id === message.conversationId);
        if (!known) {
          void this.#resync();
        } else {
          // The preview follows the newest message only. A reply that arrives
          // out of order must not rewind the list.
          const isNewest = message.sequence >= known.lastSequence;
          this.#patch({
            conversations: this.#state.conversations.map((item) =>
              item.id === message.conversationId
                ? {
                    ...item,
                    visitorUnread: freshEvent && message.senderType !== 'VISITOR' ? (item.visitorUnread ?? 0) + 1 : item.visitorUnread,
                    lastSequence: Math.max(item.lastSequence, message.sequence),
                    lastMessagePreview: isNewest ? message.content.slice(0, 80) : item.lastMessagePreview,
                    lastMessageAt: isNewest ? message.createdAt : item.lastMessageAt,
                    // A private note never reaches a visitor socket; the check
                    // is defensive, because a note must not un-resolve a
                    // conversation the visitor sees as closed either.
                    status: item.status === 'RESOLVED' && !message.private ? 'OPEN' : item.status,
                  }
                : item,
            ),
          });
        }
        break;
      }
      case 'message.updated': {
        // An edit or a recall. The server sends the whole message back with the
        // content already stripped when it was recalled, so the client replaces
        // the row rather than trying to reconstruct what happened.
        const message = event.data as Message | undefined;
        if (message?.private) return;
        if (!message?.id || message.conversationId !== this.#state.activeId) {
          return;
        }
        this.#patch({ messages: mergeMessages(this.#state.messages, [toChatMessage(message)]) });
        this.#emit({ type: 'message-updated', data: message });
        break;
      }
      case 'message.reaction': {
        const data = event.data as
          | { messageId?: string; reactions?: ChatMessage['reactions'] }
          | undefined;
        if (!data?.messageId || event.conversationId !== this.#state.activeId) {
          return;
        }
        this.#patch({ messages: mergeReactions(this.#state.messages, data.messageId, data.reactions ?? []) });
        break;
      }
      case 'message.pinned': {
        const data = event.data as { messageId?: string; pinnedAt?: string | null } | undefined;
        if (!data?.messageId || event.conversationId !== this.#state.activeId) {
          return;
        }
        this.#patch({
          messages: this.#state.messages.map((item) =>
            item.id === data.messageId ? { ...item, pinnedAt: data.pinnedAt ?? undefined } : item,
          ),
        });
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
      case 'conversation.read':
      case 'conversation.delivered': {
        void this.#resync();
        break;
      }
      case 'agent.presence': {
        // 入口频道推送坐席状态；重拉会话列表即可刷新 agentsOnline 副标题。
        void this.#resync();
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
    this.emitHost(event);
  }

  /** Publishes an event to onEvent, native bridge, and iframe parent. */
  emitHost(event: { type: string; data?: unknown }): void {
    const envelope = { source: 'relaydesk', ...event };
    this.#options.onEvent?.(event as never);
    this.#options.bridge?.postMessage?.(JSON.stringify(envelope));
    if (typeof window !== 'undefined' && window.parent && window.parent !== window) {
      const target = this.#options.parentOrigin || '*';
      try {
        window.parent.postMessage(envelope, target);
      } catch {
        // Cross-origin parentOrigin misconfiguration must not break chat.
      }
    }
  }

  #patch(partial: Partial<Snapshot>): void {
    this.#state = { ...this.#state, ...partial };
    for (const listener of this.#listeners) {
      listener(this.#state);
    }
  }

  #storageKey(): string {
    const signed = this.#options.identityToken || this.#options.bridge?.getVisitor?.()?.identityToken;
    // 退出业务账号后匿名组件不能读取之前的登录聊天会话。
    return `${this.#options.storage}.${this.#options.inboxKey}.${signed ? 'signed' : this.#options.externalId || 'guest'}`;
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
