// Shadow-DOM renderer. Two rules keep it usable inside someone else's page:
// every style is scoped to the shadow root, and the composer is a persistent
// node that re-renders only patch the message list, so typing is never
// interrupted and the caret never jumps.

import type { ResolvedOptions } from './config.js';
import type { ChatStore, Snapshot } from './store.js';
import type { ChatMessage, SearchHit } from './types.js';

const ICONS = {
  chat: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 4h16a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H9l-5 4V5a1 1 0 0 1 1-1Z"/></svg>',
  close: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  send: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 11.5 20 4l-7 16-2.5-6.5L3 11.5Z"/></svg>',
  clip: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 7v9a4 4 0 0 0 8 0V6a3 3 0 0 0-6 0v10a1.5 1.5 0 0 0 3 0V7"/></svg>',
  back: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg>',
  retry: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5"/></svg>',
  star: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3.5l2.7 5.6 6.1.8-4.5 4.2 1.1 6-5.4-3-5.4 3 1.1-6L3.2 9.9l6.1-.8L12 3.5Z"/></svg>',
  search: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="6.5"/><path d="M16 16l4 4"/></svg>',
  quote: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6H5a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h2v3M19 6h-4a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h2v3"/></svg>',
  pin: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v7M8 10h8l1.5 4h-11L8 10ZM12 14v7"/></svg>',
  mic: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>',
  trash: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 7h14M9 7V4h6v3M7 7l1 13h8l1-13"/></svg>',
};

const REACTION_LABEL: Record<string, string> = {
  '👍': '赞',
  '👎': '踩',
  '😀': '开心',
  '🎉': '庆祝',
  '❤️': '喜欢',
  '🙏': '感谢',
  '😅': '尴尬',
  '😢': '难过',
  '🔥': '重要',
  '✅': '已确认',
};

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** Linkifies plain text without ever injecting markup from a message. */
function formatText(value: string): string {
  return escapeHtml(value)
    .replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>')
    .replace(/\n/g, '<br>');
}

/**
 * Renders a server-built excerpt. The server wraps each matched term in << >>,
 * having run the same tokenizer that indexed the message, so the highlight is
 * exactly what was matched rather than a client-side guess at Chinese word
 * boundaries. Markers are escaped first and replaced after, so a message that
 * literally contains "<<" cannot forge a highlight.
 */
function formatExcerpt(value: string): string {
  return escapeHtml(value)
    .replace(/&lt;&lt;/g, '<mark>')
    .replace(/&gt;&gt;/g, '</mark>')
    .replace(/\n/g, ' ');
}

function formatSize(bytes: number): string {
  if (bytes < 1024) {
    return bytes + ' B';
  }
  if (bytes < 1024 * 1024) {
    return (bytes / 1024).toFixed(1) + ' KB';
  }
  return (bytes / 1024 / 1024).toFixed(1) + ' MB';
}

function escapeAttr(value: string): string {
  return escapeHtml(value);
}

function timeLabel(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) {
    return '';
  }
  const today = new Date();
  const sameDay = date.toDateString() === today.toDateString();
  const time = `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
  return sameDay ? time : `${date.getMonth() + 1}/${date.getDate()} ${time}`;
}

function durationLabel(ms: number): string {
  const total = Math.max(Math.round(ms / 1000), 0);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

function dayLabel(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) {
    return '';
  }
  const today = new Date();
  const yesterday = new Date(today.getTime() - 86_400_000);
  if (date.toDateString() === today.toDateString()) {
    return '今天';
  }
  if (date.toDateString() === yesterday.toDateString()) {
    return '昨天';
  }
  return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
}

export interface UiHandlers {
  onToggle: () => void;
  onClose: () => void;
  onSend: (text: string) => void;
  onFiles: (files: FileList) => void;
  onRetry: (localId: string) => void;
  onSelectConversation: (id: string) => void;
  onBack: () => void;
  onRate: (score: number) => void;
  onTyping: () => void;
  /** Quotes a message, so the next send is a reply to it. */
  onQuote: (messageId: string) => void;
  onClearQuote: () => void;
  onSearch: (query: string) => void;
  onClearSearch: () => void;
  onVoice: (blob: Blob, durationMs: number) => void;
  onLoadOlder: () => void;
}

export class WidgetView {
  readonly #root: ShadowRoot;
  readonly #options: ResolvedOptions;
  readonly #store: ChatStore;
  readonly #handlers: UiHandlers;
  #launcher?: HTMLButtonElement;
  #composer?: HTMLFormElement;
  #input?: HTMLTextAreaElement;
  #messagesNode?: HTMLDivElement;
  #typingNode?: HTMLDivElement;
  #listNode?: HTMLDivElement;
  #replyBar?: HTMLDivElement;
  #searchBar?: HTMLDivElement;
  #searchInput?: HTMLInputElement;
  #resultsNode?: HTMLDivElement;
  #pinnedBar?: HTMLDivElement;
  #recordBar?: HTMLDivElement;
  #lastSnapshot?: Snapshot;
  #renderedConversation?: string;
  #atBottom = true;
  #searchOpen = false;
  #recorder?: MediaRecorder;
  #recordChunks: Blob[] = [];
  #recordStartedAt = 0;
  #recordTimer?: ReturnType<typeof setInterval>;
  #recording = false;

  constructor(root: ShadowRoot, options: ResolvedOptions, store: ChatStore, handlers: UiHandlers) {
    this.#root = root;
    this.#options = options;
    this.#store = store;
    this.#handlers = handlers;
  }

  render(snapshot: Snapshot): void {
    const first = !this.#lastSnapshot;
    this.#lastSnapshot = snapshot;
    if (first) {
      this.#root.innerHTML = `<style>${this.#styles()}</style><div class="rd-launcher-slot"></div><div class="rd-panel-slot"></div>`;
      this.#buildLauncher();
      this.#buildPanel();
    }
    this.#syncLauncher(snapshot);
    this.#syncPanel(snapshot);
  }

  /** Scrolls the thread to the newest message after a render. */
  scrollToBottom(behavior: ScrollBehavior = 'smooth'): void {
    if (!this.#messagesNode) {
      return;
    }
    this.#messagesNode.scrollTo({ top: this.#messagesNode.scrollHeight, behavior });
  }

  focusInput(): void {
    this.#input?.focus();
  }

  setInputValue(value: string): void {
    if (this.#input) {
      this.#input.value = value;
    }
  }

  /** True while the microphone is capturing, so the host can warn on unload. */
  get recording(): boolean {
    return this.#recording;
  }

  #buildLauncher(): void {
    const slot = this.#root.querySelector('.rd-launcher-slot');
    if (!slot || this.#options.embedded || this.#options.launcher === 'none') {
      return;
    }
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'rd-launcher';
    button.innerHTML = `<span class="rd-launcher-icon">${ICONS.chat}</span><span class="rd-launcher-label">${escapeHtml(this.#options.title)}</span><span class="rd-launcher-badge" hidden>0</span>`;
    button.addEventListener('click', () => this.#handlers.onToggle());
    slot.appendChild(button);
    this.#launcher = button;
  }

  #buildPanel(): void {
    const slot = this.#root.querySelector('.rd-panel-slot');
    if (!slot) {
      return;
    }
    const panel = document.createElement('section');
    panel.className = 'rd-panel';
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-label', this.#options.title);
    panel.hidden = true;
    panel.innerHTML = `
      <header class="rd-header">
        <div class="rd-header-main">
          <span class="rd-avatar">${ICONS.chat}</span>
          <div class="rd-heading">
            <strong>${escapeHtml(this.#options.title)}</strong>
            <span class="rd-subtitle"></span>
          </div>
        </div>
        <div class="rd-header-actions">
          <button type="button" class="rd-icon rd-search-toggle" title="搜索聊天记录">${ICONS.search}</button>
          <button type="button" class="rd-icon rd-back" title="返回会话列表" hidden>${ICONS.back}</button>
          <button type="button" class="rd-icon rd-close" title="收起">${ICONS.close}</button>
        </div>
      </header>
      <div class="rd-searchbar" hidden>
        <input type="search" class="rd-search-input" placeholder="搜索本会话的聊天记录" maxlength="64">
        <button type="button" class="rd-icon rd-search-close" title="关闭搜索">${ICONS.close}</button>
      </div>
      <div class="rd-body">
        <div class="rd-list" hidden></div>
        <div class="rd-thread">
          <div class="rd-pinned" hidden></div>
          <div class="rd-messages" role="log" aria-live="polite"></div>
          <div class="rd-results" hidden></div>
          <div class="rd-typing" hidden><span></span><span></span><span></span></div>
        </div>
      </div>
      <div class="rd-recording" hidden>
        <span class="rd-rec-dot"></span>
        <span class="rd-rec-time">0:00</span>
        <span class="rd-rec-hint">正在录音，点击右侧发送</span>
        <button type="button" class="rd-icon rd-rec-cancel" title="取消录音">${ICONS.trash}</button>
        <button type="button" class="rd-send rd-rec-send" title="发送语音">${ICONS.send}</button>
      </div>
      <form class="rd-composer">
        <div class="rd-reply" hidden>
          <span class="rd-reply-icon">${ICONS.quote}</span>
          <span class="rd-reply-body"><strong></strong><small></small></span>
          <button type="button" class="rd-icon rd-reply-close" title="取消引用">${ICONS.close}</button>
        </div>
        <div class="rd-composer-row">
          <button type="button" class="rd-icon rd-attach" title="发送图片或文件">${ICONS.clip}</button>
          <textarea class="rd-input" rows="1" placeholder="${escapeAttr(this.#options.placeholder)}" maxlength="4000"></textarea>
          <button type="button" class="rd-icon rd-mic" title="按住说话" hidden>${ICONS.mic}</button>
          <button type="submit" class="rd-send" title="发送">${ICONS.send}</button>
        </div>
        <input type="file" class="rd-file" multiple hidden>
      </form>
      <div class="rd-footer"></div>`;

    this.#composer = panel.querySelector('.rd-composer') as HTMLFormElement;
    this.#input = panel.querySelector('.rd-input') as HTMLTextAreaElement;
    this.#messagesNode = panel.querySelector('.rd-messages') as HTMLDivElement;
    this.#typingNode = panel.querySelector('.rd-typing') as HTMLDivElement;
    this.#listNode = panel.querySelector('.rd-list') as HTMLDivElement;
    this.#replyBar = panel.querySelector('.rd-reply') as HTMLDivElement;
    this.#searchBar = panel.querySelector('.rd-searchbar') as HTMLDivElement;
    this.#searchInput = panel.querySelector('.rd-search-input') as HTMLInputElement;
    this.#resultsNode = panel.querySelector('.rd-results') as HTMLDivElement;
    this.#pinnedBar = panel.querySelector('.rd-pinned') as HTMLDivElement;
    this.#recordBar = panel.querySelector('.rd-recording') as HTMLDivElement;

    const fileInput = panel.querySelector('.rd-file') as HTMLInputElement;
    const attach = panel.querySelector('.rd-attach') as HTMLButtonElement;
    attach.addEventListener('click', () => fileInput.click());
    fileInput.addEventListener('change', () => {
      if (fileInput.files?.length) {
        this.#handlers.onFiles(fileInput.files);
      }
      fileInput.value = '';
    });

    this.#composer.addEventListener('submit', (event) => {
      event.preventDefault();
      const text = this.#input?.value ?? '';
      if (!text.trim()) {
        return;
      }
      this.#handlers.onSend(text);
      if (this.#input) {
        this.#input.value = '';
        this.#autoGrow();
      }
    });
    this.#input.addEventListener('input', () => {
      this.#autoGrow();
      this.#handlers.onTyping();
    });
    this.#input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        this.#composer?.requestSubmit();
      }
      if (event.key === 'Escape' && !this.#replyBar?.hidden) {
        this.#handlers.onClearQuote();
      }
    });
    (panel.querySelector('.rd-reply-close') as HTMLButtonElement).addEventListener('click', () =>
      this.#handlers.onClearQuote(),
    );

    // Voice notes. The button only appears where the browser can actually
    // record, because a microphone control that always fails is worse than no
    // control at all.
    const mic = panel.querySelector('.rd-mic') as HTMLButtonElement;
    if (typeof MediaRecorder !== 'undefined' && typeof navigator.mediaDevices?.getUserMedia === 'function') {
      mic.hidden = false;
      mic.addEventListener('click', () => void this.#startRecording());
    }
    (panel.querySelector('.rd-rec-cancel') as HTMLButtonElement).addEventListener('click', () => this.#stopRecording(true));
    (panel.querySelector('.rd-rec-send') as HTMLButtonElement).addEventListener('click', () => this.#stopRecording(false));

    (panel.querySelector('.rd-search-toggle') as HTMLButtonElement).addEventListener('click', () => {
      this.#searchOpen = true;
      this.#syncSearchBar();
      this.#searchInput?.focus();
    });
    (panel.querySelector('.rd-search-close') as HTMLButtonElement).addEventListener('click', () => {
      this.#searchOpen = false;
      this.#handlers.onClearSearch();
      if (this.#searchInput) {
        this.#searchInput.value = '';
      }
      this.#syncSearchBar();
    });
    let searchTimer: ReturnType<typeof setTimeout> | undefined;
    this.#searchInput.addEventListener('input', () => {
      const query = this.#searchInput?.value ?? '';
      if (searchTimer) {
        clearTimeout(searchTimer);
      }
      // Debounced: a Chinese query is typed character by character and each
      // keystroke would otherwise be a full-text query against the transcript.
      searchTimer = setTimeout(() => this.#handlers.onSearch(query), 250);
    });
    this.#searchInput.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        (panel.querySelector('.rd-search-close') as HTMLButtonElement).click();
      }
    });

    (panel.querySelector('.rd-close') as HTMLButtonElement).addEventListener('click', () => this.#handlers.onClose());
    (panel.querySelector('.rd-back') as HTMLButtonElement).addEventListener('click', () => this.#handlers.onBack());
    this.#messagesNode.addEventListener('scroll', () => {
      const node = this.#messagesNode;
      if (!node) {
        return;
      }
      this.#atBottom = node.scrollHeight - node.scrollTop - node.clientHeight < 60;
      if (node.scrollTop < 40 && this.#lastSnapshot?.hasMore) {
        this.#handlers.onLoadOlder();
      }
    });
    // Dropping a file anywhere on the thread is the gesture phone and desktop
    // users try first, so it is wired explicitly.
    this.#messagesNode.addEventListener('dragover', (event) => {
      event.preventDefault();
    });
    this.#messagesNode.addEventListener('drop', (event) => {
      event.preventDefault();
      if (event.dataTransfer?.files.length) {
        this.#handlers.onFiles(event.dataTransfer.files);
      }
    });

    slot.appendChild(panel);
  }

  #syncLauncher(snapshot: Snapshot): void {
    if (!this.#launcher) {
      return;
    }
    const badge = this.#launcher.querySelector('.rd-launcher-badge') as HTMLElement;
    badge.hidden = snapshot.unread === 0;
    badge.textContent = snapshot.unread > 99 ? '99+' : String(snapshot.unread);
    this.#launcher.classList.toggle('is-open', snapshot.open);
    this.#launcher.setAttribute('aria-expanded', String(snapshot.open));
  }

  #syncPanel(snapshot: Snapshot): void {
    const panel = this.#root.querySelector('.rd-panel') as HTMLElement | null;
    if (!panel) {
      return;
    }
    panel.hidden = !snapshot.open;
    if (!snapshot.open) {
      return;
    }
    const subtitle = panel.querySelector('.rd-subtitle') as HTMLElement;
    subtitle.textContent = this.#subtitle(snapshot);
    subtitle.classList.toggle('is-online', snapshot.agentsOnline > 0);

    const back = panel.querySelector('.rd-back') as HTMLElement;
    const showList = snapshot.conversations.length > 1;
    back.hidden = !showList;
    // With more than one conversation the picker is the landing view; picking
    // one swaps the thread in without a second panel.
    this.#listNode!.hidden = !showList || Boolean(snapshot.activeId);

    if (showList && !snapshot.activeId) {
      this.#renderConversationList(snapshot);
    }
    this.#renderThread(snapshot);
    this.#syncReplyBar(snapshot);
    this.#syncSearchBar();
    this.#renderResults(snapshot);
    this.#renderPinned(snapshot);
    this.#syncFooter(snapshot);
    const composer = this.#composer as HTMLFormElement;
    composer.hidden = showList && !snapshot.activeId;
  }

  #subtitle(snapshot: Snapshot): string {
    if (snapshot.status === 'BOOTSTRAPPING') {
      return '正在连接…';
    }
    if (snapshot.status === 'FAILED') {
      return snapshot.error ?? '连接失败';
    }
    if (snapshot.offline) {
      return '当前离线，留言稍后回复';
    }
    if (snapshot.agentTyping) {
      return '客服正在输入…';
    }
    if (snapshot.connection !== 'OPEN') {
      return '正在重连…';
    }
    if (snapshot.agentsOnline > 0) {
      return snapshot.aiEnabled ? `人工客服在线 · AI 助手可即时回答` : '人工客服在线';
    }
    return this.#options.offlineMessage || '客服暂时不在线，请留言';
  }

  #renderConversationList(snapshot: Snapshot): void {
    const node = this.#listNode;
    if (!node) {
      return;
    }
    node.innerHTML =
      `<div class="rd-list-head">${escapeHtml('选择会话')}</div>` +
      snapshot.conversations
        .map((conversation) => {
          const title = conversation.subject?.trim() || conversation.lastMessagePreview?.trim() || '新会话';
          const active = conversation.id === snapshot.activeId ? ' is-active' : '';
          const unread = conversation.visitorUnread > 0 ? `<span class="rd-dot">${conversation.visitorUnread}</span>` : '';
          return `<button type="button" class="rd-item${active}" data-conversation="${escapeAttr(conversation.id)}">
            <span class="rd-item-main">
              <strong>${escapeHtml(title)}</strong>
              <small>${escapeHtml(conversation.lastMessagePreview ?? '')}</small>
            </span>
            <span class="rd-item-meta">${unread}<time>${escapeHtml(conversation.lastMessageAt ? timeLabel(conversation.lastMessageAt) : '')}</time></span>
          </button>`;
        })
        .join('');
    node.querySelectorAll<HTMLElement>('[data-conversation]').forEach((item) => {
      item.addEventListener('click', () => {
        const id = item.dataset.conversation;
        if (id) {
          this.#handlers.onSelectConversation(id);
        }
      });
    });
  }

  #renderThread(snapshot: Snapshot): void {
    const node = this.#messagesNode;
    if (!node) {
      return;
    }
    const conversationChanged = this.#renderedConversation !== snapshot.activeId;
    this.#renderedConversation = snapshot.activeId;
    const previousCount = node.querySelectorAll('.rd-msg').length;
    const shouldStick = this.#atBottom || conversationChanged || snapshot.messages.length > previousCount;

    if (snapshot.messages.length === 0) {
      node.innerHTML = `<div class="rd-empty">
        <span class="rd-avatar lg">${ICONS.chat}</span>
        <p>${escapeHtml(snapshot.welcomeMessage || '你好！有问题随时问我，我们会尽快回复。')}</p>
      </div>`;
    } else {
      const parts: string[] = [];
      if (snapshot.hasMore) {
        parts.push(`<button type="button" class="rd-more" data-more="1">加载更早的消息</button>`);
      }
      let lastDay = '';
      for (const message of snapshot.messages) {
        const day = dayLabel(message.createdAt);
        if (day && day !== lastDay) {
          parts.push(`<div class="rd-day">${escapeHtml(day)}</div>`);
          lastDay = day;
        }
        // The divider sits on the boundary the server reported at load time:
        // everything above it was seen, everything below arrived after.
        if (snapshot.readBoundary > 0 && message.sequence === snapshot.readBoundary && message !== snapshot.messages.at(-1)) {
          parts.push(`<div class="rd-unread"><span>以下为新消息</span></div>`);
        }
        parts.push(this.#messageHtml(snapshot, message));
      }
      node.innerHTML = parts.join('');
      node.querySelectorAll<HTMLElement>('[data-retry]').forEach((button) => {
        button.addEventListener('click', () => {
          const id = button.dataset.retry;
          if (id) {
            this.#handlers.onRetry(id);
          }
        });
      });
      node.querySelectorAll<HTMLElement>('[data-quote]').forEach((button) => {
        button.addEventListener('click', () => {
          const id = button.dataset.quote;
          if (id) {
            this.#handlers.onQuote(id);
          }
        });
      });
      node.querySelectorAll<HTMLElement>('[data-more]').forEach((button) => {
        button.addEventListener('click', () => this.#handlers.onLoadOlder());
      });
      node.querySelectorAll<HTMLImageElement>('img[data-src]').forEach((image) => {
        const src = image.dataset.src;
        if (src) {
          image.src = src;
          image.removeAttribute('data-src');
        }
      });
    }
    this.#typingNode!.hidden = !snapshot.agentTyping;
    if (shouldStick) {
      requestAnimationFrame(() => this.scrollToBottom(conversationChanged ? 'auto' : 'smooth'));
    }
  }

  #messageHtml(snapshot: Snapshot, message: ChatMessage): string {
    const mine = message.senderType === 'VISITOR';
    const system = message.senderType === 'SYSTEM';
    if (system) {
      return `<div class="rd-sys">${formatText(message.content)}</div>`;
    }
    if (message.deletedAt) {
      return `<div class="rd-row rd-msg ${mine ? 'is-mine' : 'is-theirs'}">
        <div class="rd-bubble-group"><div class="rd-bubble is-recalled">该消息已被撤回</div></div>
      </div>`;
    }
    const state =
      message.delivery === 'SENDING'
        ? '<span class="rd-state">发送中…</span>'
        : message.delivery === 'FAILED'
          ? `<button type="button" class="rd-state is-failed" data-retry="${escapeAttr(message.localId)}">${ICONS.retry}发送失败，重试</button>`
          : '';
    const edited = message.editedAt ? '<span class="rd-edited">已编辑</span>' : '';
    const pinned = message.pinnedAt ? `<span class="rd-pinned-mark" title="已置顶">${ICONS.pin}</span>` : '';
    const forward = message.forwardedFromId ? '<span class="rd-forwarded">转发的消息</span>' : '';
    const quote = message.replyTo ? this.#quoteHtml(message.replyTo) : '';
    const reactions = this.#reactionsHtml(message);
    return `<div class="rd-row rd-msg ${mine ? 'is-mine' : 'is-theirs'}" data-message="${escapeAttr(message.id)}">
      ${mine ? '' : `<span class="rd-avatar sm">${ICONS.chat}</span>`}
      <div class="rd-bubble-group">
        ${mine || !message.senderName ? '' : `<span class="rd-sender">${escapeHtml(message.senderName)}</span>`}
        <div class="rd-bubble-wrap">
          <div class="rd-bubble">${quote}${forward}${this.#bodyHtml(message)}</div>
          <button type="button" class="rd-quote-btn" data-quote="${escapeAttr(message.id)}" title="引用回复">${ICONS.quote}</button>
        </div>
        ${reactions}
        <span class="rd-time">${escapeHtml(timeLabel(message.createdAt))}${edited}${pinned}${state}</span>
      </div>
    </div>`;
  }

  /** The quoted excerpt shown above a reply inside its bubble. */
  #quoteHtml(quote: NonNullable<ChatMessage['replyTo']>): string {
    const label = quote.senderType === 'VISITOR' ? '我' : quote.senderName || '客服';
    const body = quote.deletedAt ? '该消息已被撤回' : quote.messageType === 'TEXT' ? quote.content : '[图片/文件]';
    return `<span class="rd-quote">
      <strong>${escapeHtml(label)}</strong>
      <em>${escapeHtml(body.slice(0, 120))}</em>
    </span>`;
  }

  #reactionsHtml(message: ChatMessage): string {
    const reactions = message.reactions ?? [];
    if (!reactions.length) {
      return '';
    }
    return `<span class="rd-reactions">${reactions
      .map(
        (reaction) =>
          `<span class="rd-reaction" title="${escapeAttr((REACTION_LABEL[reaction.emoji] ?? '') + ' ' + reaction.actors.join('、'))}">${escapeHtml(reaction.emoji)}<b>${reaction.count}</b></span>`,
      )
      .join('')}</span>`;
  }

  #bodyHtml(message: ChatMessage): string {
    const attachments = message.attachments ?? [];
    if (attachments.length) {
      if (message.messageType === 'AUDIO') {
        return this.#voiceHtml(message, attachments);
      }
      return attachments.map((attachment) => this.#attachmentHtml(attachment)).join('');
    }
    return formatText(message.content);
  }

  /**
   * A voice note renders as a player plus the duration the sender's device
   * measured, because the audio element cannot report a duration for a stream
   * it has not buffered yet and a player that shows 0:00 until pressed reads as
   * broken.
   */
  #voiceHtml(message: ChatMessage, attachments: ChatMessage['attachments']): string {
    const attachment = attachments[0];
    if (!attachment) {
      return formatText(message.content);
    }
    const url = attachment.url.startsWith('blob:') ? attachment.url : this.#store.fileUrl(attachment.url);
    const recorded = message.metadata?.durationMs;
    const seconds =
      typeof recorded === 'number' && recorded > 0
        ? Math.max(Math.round(recorded / 1000), 1)
        : 0;
    return `<span class="rd-voice">
      <audio controls preload="metadata" src="${escapeAttr(url)}"></audio>
      <small>${escapeHtml(seconds ? durationLabel(seconds * 1000) : '语音')}</small>
    </span>`;
  }

  #attachmentHtml(attachment: ChatMessage['attachments'][number]): string {
    const url = attachment.url.startsWith('blob:') ? attachment.url : this.#store.fileUrl(attachment.url);
    if (attachment.contentType.startsWith('image/')) {
      return `<a class="rd-image" href="${escapeAttr(url)}" target="_blank" rel="noopener noreferrer">
        <img data-src="${escapeAttr(url)}" alt="${escapeAttr(attachment.fileName)}" loading="lazy">
      </a>`;
    }
    if (attachment.contentType.startsWith('video/')) {
      return `<video class="rd-video" controls preload="metadata" src="${escapeAttr(url)}"></video>`;
    }
    if (attachment.contentType.startsWith('audio/')) {
      return `<audio class="rd-audio" controls preload="metadata" src="${escapeAttr(url)}"></audio>`;
    }
    return `<a class="rd-file" href="${escapeAttr(url)}" target="_blank" rel="noopener noreferrer">
      <span class="rd-file-name">${escapeHtml(attachment.fileName)}</span>
      <span class="rd-file-size">${escapeHtml(formatSize(attachment.sizeBytes))}</span>
    </a>`;
  }

  #syncReplyBar(snapshot: Snapshot): void {
    const bar = this.#replyBar;
    if (!bar) {
      return;
    }
    const quote = snapshot.replyTo;
    bar.hidden = !quote;
    if (!quote) {
      return;
    }
    const label = quote.senderType === 'VISITOR' ? '我' : quote.senderName || '客服';
    const body = quote.deletedAt ? '该消息已被撤回' : quote.messageType === 'TEXT' ? quote.content : '[图片/文件]';
    (bar.querySelector('strong') as HTMLElement).textContent = `引用 ${label}`;
    (bar.querySelector('small') as HTMLElement).textContent = body.slice(0, 120);
    this.#input?.focus();
  }

  #syncSearchBar(): void {
    const bar = this.#searchBar;
    const panel = this.#root.querySelector('.rd-panel') as HTMLElement | null;
    if (!bar || !panel) {
      return;
    }
    bar.hidden = !this.#searchOpen;
    if (this.#searchOpen) {
      (panel.querySelector('.rd-avatar') as HTMLElement).hidden = true;
    }
  }

  #renderResults(snapshot: Snapshot): void {
    const node = this.#resultsNode;
    if (!node) {
      return;
    }
    const { search } = snapshot;
    if (!this.#searchOpen || !search.query) {
      node.hidden = true;
      node.innerHTML = '';
      return;
    }
    node.hidden = false;
    if (search.running && !search.hits.length) {
      node.innerHTML = `<div class="rd-results-head">搜索中…</div>`;
      return;
    }
    if (search.error) {
      node.innerHTML = `<div class="rd-results-head">${escapeHtml(search.error)}</div>`;
      return;
    }
    if (!search.hits.length) {
      node.innerHTML = `<div class="rd-results-head">没有找到包含“${escapeHtml(search.query)}”的消息</div>`;
      return;
    }
    node.innerHTML =
      `<div class="rd-results-head">找到 ${search.hits.length} 条消息</div>` +
      search.hits.map((hit) => this.#resultHtml(hit)).join('');
    node.querySelectorAll<HTMLElement>('[data-jump]').forEach((item) => {
      item.addEventListener('click', () => {
        const id = item.dataset.jump;
        const target = this.#messagesNode?.querySelector<HTMLElement>(`[data-message="${id}"]`);
        if (!target) {
          return;
        }
        this.#searchOpen = false;
        this.#syncSearchBar();
        target.scrollIntoView({ block: 'center', behavior: 'smooth' });
        target.classList.add('is-flash');
        setTimeout(() => target.classList.remove('is-flash'), 1_600);
      });
    });
  }

  #resultHtml(hit: SearchHit): string {
    const mine = hit.senderType === 'VISITOR';
    return `<button type="button" class="rd-result" data-jump="${escapeAttr(hit.messageId)}">
      <span class="rd-result-main">
        <strong>${escapeHtml(mine ? '我' : hit.senderName || '客服')}</strong>
        <span class="rd-result-excerpt">${formatExcerpt(hit.excerpt)}</span>
      </span>
      <time>${escapeHtml(timeLabel(hit.createdAt))}</time>
    </button>`;
  }

  #renderPinned(snapshot: Snapshot): void {
    const bar = this.#pinnedBar;
    if (!bar) {
      return;
    }
    const pinned = snapshot.messages.filter((message) => message.pinnedAt && !message.deletedAt);
    const latest = pinned.at(-1);
    if (!latest) {
      bar.hidden = true;
      bar.innerHTML = '';
      return;
    }
    bar.hidden = false;
    bar.innerHTML = `<span class="rd-pinned-icon">${ICONS.pin}</span>
      <span class="rd-pinned-body">${escapeHtml(latest.content.slice(0, 90) || '[图片/文件]')}</span>
      ${pinned.length > 1 ? `<span class="rd-pinned-count">${pinned.length} 条置顶</span>` : ''}
      <button type="button" class="rd-icon rd-pinned-jump" title="查看置顶消息">${ICONS.back}</button>`;
    (bar.querySelector('.rd-pinned-jump') as HTMLButtonElement).addEventListener('click', () => {
      const target = this.#messagesNode?.querySelector<HTMLElement>(`[data-message="${latest.id}"]`);
      target?.scrollIntoView({ block: 'center', behavior: 'smooth' });
      target?.classList.add('is-flash');
      setTimeout(() => target?.classList.remove('is-flash'), 1_600);
    });
  }

  #syncFooter(snapshot: Snapshot): void {
    const footer = this.#root.querySelector('.rd-footer') as HTMLElement | null;
    if (!footer) {
      return;
    }
    const active = snapshot.conversations.find((item) => item.id === snapshot.activeId);
    if (!active || active.status !== 'RESOLVED' || snapshot.rated) {
      footer.hidden = true;
      footer.innerHTML = '';
      return;
    }
    footer.hidden = false;
    footer.innerHTML = `<span>本次服务是否解决了您的问题？</span><span class="rd-stars">${[1, 2, 3, 4, 5]
      .map((score) => `<button type="button" class="rd-star" data-score="${score}" title="${score} 分">${ICONS.star}</button>`)
      .join('')}</span>`;
    footer.querySelectorAll<HTMLElement>('[data-score]').forEach((star) => {
      star.addEventListener('click', () => {
        const score = Number(star.dataset.score);
        if (score >= 1 && score <= 5) {
          this.#handlers.onRate(score);
        }
      });
    });
  }

  async #startRecording(): Promise<void> {
    if (this.#recording) {
      return;
    }
    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      this.#flashRecordingError('无法访问麦克风，请检查浏览器权限');
      return;
    }
    const mimeType = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4'].find((type) =>
      MediaRecorder.isTypeSupported(type),
    );
    const recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined);
    this.#recorder = recorder;
    this.#recordChunks = [];
    recorder.addEventListener('dataavailable', (event) => {
      if (event.data.size > 0) {
        this.#recordChunks.push(event.data);
      }
    });
    recorder.addEventListener('stop', () => {
      stream.getTracks().forEach((track) => track.stop());
    });
    recorder.start();
    this.#recording = true;
    this.#recordStartedAt = Date.now();
    this.#recordBar!.hidden = false;
    (this.#composer as HTMLFormElement).hidden = true;
    const label = this.#recordBar!.querySelector('.rd-rec-time') as HTMLElement;
    this.#recordTimer = setInterval(() => {
      label.textContent = durationLabel(Date.now() - this.#recordStartedAt);
    }, 500);
    label.textContent = '0:00';
  }

  #stopRecording(cancel: boolean): void {
    const recorder = this.#recorder;
    if (!recorder || !this.#recording) {
      return;
    }
    const elapsed = Date.now() - this.#recordStartedAt;
    this.#recording = false;
    if (this.#recordTimer) {
      clearInterval(this.#recordTimer);
      this.#recordTimer = undefined;
    }
    this.#recordBar!.hidden = true;
    (this.#composer as HTMLFormElement).hidden = false;
    this.#recorder = undefined;
    const chunks = this.#recordChunks;
    this.#recordChunks = [];
    recorder.addEventListener('stop', () => {
      if (cancel) {
        return;
      }
      // A tap rather than a hold: anything under half a second is almost
      // always an accidental press, and the server would store a silent file.
      if (elapsed < 500 || chunks.length === 0) {
        this.#flashRecordingError('录音时间太短');
        return;
      }
      this.#handlers.onVoice(new Blob(chunks, { type: recorder.mimeType || 'audio/webm' }), elapsed);
    });
    recorder.stop();
  }

  #flashRecordingError(message: string): void {
    const bar = this.#recordBar;
    if (!bar) {
      return;
    }
    bar.hidden = false;
    bar.classList.add('is-error');
    const label = bar.querySelector('.rd-rec-time') as HTMLElement;
    const hint = bar.querySelector('.rd-rec-hint') as HTMLElement;
    hint.textContent = message;
    label.textContent = '';
    setTimeout(() => {
      bar.classList.remove('is-error');
      bar.hidden = true;
      hint.textContent = '正在录音，点击右侧发送';
      (this.#composer as HTMLFormElement).hidden = false;
    }, 2_000);
  }

  #autoGrow(): void {
    const input = this.#input;
    if (!input) {
      return;
    }
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 120) + 'px';
  }

  #styles(): string {
    const light = this.#options.theme !== 'dark';
    const accent = this.#options.primaryColor;
    const side = this.#options.position === 'left' ? 'left' : 'right';
    return `
:host { all: initial; }
* { box-sizing: border-box; }
.rd-launcher-slot, .rd-panel-slot { position: fixed; z-index: ${this.#options.zIndex}; ${side}: 20px; }
.rd-launcher-slot { bottom: 20px; }
.rd-panel-slot { bottom: 20px; }
.rd-launcher {
  display: inline-flex; align-items: center; gap: 8px; border: 0; cursor: pointer;
  border-radius: 999px; padding: 12px 18px; font: 600 15px/1.2 system-ui, -apple-system, "Segoe UI", Roboto, "PingFang SC", "Microsoft YaHei", sans-serif;
  color: #fff; background: ${accent}; box-shadow: 0 12px 32px rgb(15 30 70 / 28%);
  transition: transform .18s ease, box-shadow .18s ease;
}
.rd-launcher:hover { transform: translateY(-2px); box-shadow: 0 16px 38px rgb(15 30 70 / 34%); }
.rd-launcher:focus-visible { outline: 3px solid ${accent}55; outline-offset: 3px; }
.rd-launcher-icon svg { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 1.8; display: block; }
.rd-launcher-badge {
  position: absolute; top: -6px; ${side === 'right' ? 'right: -4px' : 'left: -4px'};
  min-width: 20px; height: 20px; padding: 0 6px; border-radius: 999px; background: #ff4d4f; color: #fff;
  font: 600 12px/20px system-ui, sans-serif; text-align: center;
}
.rd-launcher.is-open .rd-launcher-label { display: none; }
.rd-panel {
  position: fixed; bottom: 20px; ${side}: 20px; width: 380px; max-width: calc(100vw - 32px);
  height: min(640px, calc(100vh - 40px)); display: flex; flex-direction: column; overflow: hidden;
  border-radius: 18px; background: ${light ? '#fff' : '#1b1d22'}; color: ${light ? '#16181d' : '#eef0f4'};
  box-shadow: 0 24px 60px rgb(10 20 50 / 24%); border: 1px solid ${light ? '#e8ebf2' : '#2b2f37'};
  font: 14px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, "PingFang SC", "Microsoft YaHei", sans-serif;
}
.rd-panel[hidden] { display: none; }
.rd-header {
  display: flex; align-items: center; justify-content: space-between; gap: 12px;
  padding: 14px 14px 14px 16px; background: ${accent}; color: #fff;
}
.rd-header-main { display: flex; align-items: center; gap: 10px; min-width: 0; }
.rd-heading { display: flex; flex-direction: column; min-width: 0; }
.rd-heading strong { font-size: 15px; font-weight: 600; }
.rd-subtitle { font-size: 12px; opacity: .85; display: flex; align-items: center; gap: 6px; }
.rd-subtitle.is-online::before { content: ''; width: 7px; height: 7px; border-radius: 50%; background: #4ade80; box-shadow: 0 0 0 3px rgb(74 222 128 / 25%); }
.rd-header-actions { display: flex; gap: 4px; }
.rd-avatar {
  display: inline-flex; align-items: center; justify-content: center; width: 34px; height: 34px; flex: none;
  border-radius: 50%; background: rgb(255 255 255 / 20%); color: #fff;
}
.rd-avatar svg { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 1.8; }
.rd-avatar.lg { width: 52px; height: 52px; background: ${accent}1a; color: ${accent}; }
.rd-avatar.lg svg { width: 26px; height: 26px; }
.rd-avatar.sm { width: 28px; height: 28px; background: ${accent}1a; color: ${accent}; align-self: flex-end; }
.rd-avatar.sm svg { width: 15px; height: 15px; }
.rd-icon {
  display: inline-flex; align-items: center; justify-content: center; width: 32px; height: 32px; padding: 0;
  border: 0; border-radius: 9px; background: transparent; color: inherit; cursor: pointer;
}
.rd-icon svg { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 1.9; stroke-linecap: round; }
.rd-icon:hover { background: rgb(255 255 255 / 16%); }
.rd-panel .rd-attach:hover, .rd-panel .rd-mic:hover { background: ${light ? '#f1f3f8' : '#262a32'}; }
.rd-searchbar { display: flex; align-items: center; gap: 6px; padding: 8px 10px; border-bottom: 1px solid ${light ? '#eef0f5' : '#2b2f37'}; }
.rd-searchbar[hidden] { display: none; }
.rd-search-input {
  flex: 1; border: 1px solid ${light ? '#e2e6ef' : '#333842'}; border-radius: 10px; padding: 7px 10px;
  font: inherit; background: ${light ? '#fbfcfe' : '#20242b'}; color: inherit; outline: none;
}
.rd-search-input:focus { border-color: ${accent}; box-shadow: 0 0 0 3px ${accent}22; }
.rd-body { position: relative; flex: 1; min-height: 0; display: flex; }
.rd-thread { position: relative; flex: 1; display: flex; flex-direction: column; min-height: 0; }
.rd-messages { flex: 1; overflow-y: auto; padding: 12px 14px 6px; display: flex; flex-direction: column; gap: 10px; scrollbar-width: thin; }
.rd-messages::-webkit-scrollbar { width: 6px; }
.rd-messages::-webkit-scrollbar-thumb { background: ${light ? '#d6dae4' : '#3a3f49'}; border-radius: 3px; }
.rd-empty { margin: auto; display: flex; flex-direction: column; align-items: center; gap: 12px; text-align: center; color: ${light ? '#5b6172' : '#a8aebb'}; padding: 24px; }
.rd-empty p { margin: 0; max-width: 260px; }
.rd-more { align-self: center; border: 0; background: transparent; color: ${accent}; font: inherit; font-size: 12px; cursor: pointer; padding: 4px 10px; border-radius: 999px; }
.rd-more:hover { background: ${accent}14; }
.rd-day { align-self: center; font-size: 11px; color: ${light ? '#939aab' : '#8b91a0'}; }
.rd-unread { display: flex; align-items: center; gap: 8px; font-size: 11px; color: #ff4d4f; }
.rd-unread::before, .rd-unread::after { content: ''; flex: 1; height: 1px; background: #ff4d4f55; }
.rd-row { display: flex; gap: 8px; align-items: flex-end; }
.rd-row.is-mine { justify-content: flex-end; }
.rd-bubble-group { display: flex; flex-direction: column; gap: 4px; max-width: 78%; }
.rd-row.is-mine .rd-bubble-group { align-items: flex-end; }
.rd-sender { font-size: 12px; color: ${light ? '#7a8091' : '#9aa0ad'}; }
.rd-bubble-wrap { position: relative; display: flex; align-items: center; gap: 4px; max-width: 100%; }
.rd-row.is-mine .rd-bubble-wrap { flex-direction: row-reverse; }
.rd-bubble {
  padding: 9px 12px; border-radius: 14px; background: ${light ? '#f2f4f8' : '#262a32'};
  color: ${light ? '#16181d' : '#eef0f4'}; word-break: break-word; white-space: normal;
  border-top-left-radius: 4px; min-width: 0;
}
.rd-row.is-mine .rd-bubble { background: ${accent}; color: #fff; border-top-left-radius: 14px; border-top-right-radius: 4px; }
.rd-bubble a { color: inherit; text-decoration: underline; }
.rd-bubble img, .rd-bubble video { display: block; max-width: 100%; border-radius: 10px; }
.rd-bubble audio { width: 100%; }
.rd-bubble.is-recalled { font-size: 12px; opacity: .7; font-style: normal; }
.rd-quote-btn {
  opacity: 0; border: 0; background: transparent; color: ${light ? '#8b91a0' : '#9aa0ad'}; cursor: pointer;
  width: 24px; height: 24px; border-radius: 50%; flex: none; transition: opacity .15s ease;
}
.rd-quote-btn svg { width: 15px; height: 15px; fill: none; stroke: currentColor; stroke-width: 1.7; }
.rd-row:hover .rd-quote-btn { opacity: 1; }
.rd-quote-btn:hover { background: ${light ? '#eef1f7' : '#2f3540'}; color: ${accent}; }
.rd-quote { display: flex; flex-direction: column; gap: 2px; padding: 5px 8px; margin-bottom: 5px; border-left: 3px solid ${light ? '#c6cddd' : '#4b5262'}; border-radius: 6px; background: rgb(0 0 0 / 6%); font-size: 12px; }
.rd-quote strong { font-weight: 600; opacity: .85; }
.rd-quote em { font-style: normal; opacity: .75; overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.rd-forwarded { display: block; font-size: 11px; opacity: .7; margin-bottom: 4px; }
.rd-image { display: block; margin: -4px; }
.rd-image img { max-width: 100%; max-height: 260px; object-fit: cover; cursor: zoom-in; }
.rd-file, .rd-bubble .rd-file {
  display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 12px;
  background: ${light ? '#e9edf6' : '#2f3540'}; color: inherit; text-decoration: none;
}
.rd-file-name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 190px; }
.rd-file-size { opacity: .7; font-size: 12px; }
.rd-voice { display: flex; flex-direction: column; gap: 2px; min-width: 190px; }
.rd-voice small { font-size: 11px; opacity: .75; }
.rd-reactions { display: flex; flex-wrap: wrap; gap: 4px; }
.rd-reaction {
  display: inline-flex; align-items: center; gap: 3px; padding: 1px 7px; border-radius: 999px;
  background: ${light ? '#eef1f7' : '#2b303a'}; border: 1px solid ${light ? '#dfe4ee' : '#39404c'}; font-size: 12px;
}
.rd-reaction b { font-weight: 600; font-size: 11px; opacity: .8; }
.rd-time { font-size: 11px; color: ${light ? '#939aab' : '#8b91a0'}; display: flex; align-items: center; gap: 6px; }
.rd-edited { opacity: .8; }
.rd-pinned-mark svg { width: 12px; height: 12px; fill: none; stroke: currentColor; stroke-width: 1.8; display: block; }
.rd-state { font-size: 11px; }
.rd-state.is-failed { display: inline-flex; align-items: center; gap: 3px; border: 0; background: transparent; color: #ff4d4f; cursor: pointer; padding: 0; font: inherit; font-size: 11px; }
.rd-state.is-failed svg { width: 12px; height: 12px; fill: none; stroke: currentColor; stroke-width: 2; }
.rd-sys { align-self: center; font-size: 12px; color: ${light ? '#8c93a3' : '#8b91a0'}; background: ${light ? '#f5f7fb' : '#23262d'}; padding: 4px 10px; border-radius: 999px; }
.rd-row.is-flash .rd-bubble { box-shadow: 0 0 0 3px ${accent}55; }
.rd-pinned { display: flex; align-items: center; gap: 8px; margin: 8px 12px 0; padding: 6px 10px; border-radius: 10px; background: ${light ? '#f5f7fb' : '#23262d'}; font-size: 12px; color: ${light ? '#5b6172' : '#a8aebb'}; }
.rd-pinned[hidden] { display: none; }
.rd-pinned-icon svg { width: 14px; height: 14px; fill: none; stroke: currentColor; stroke-width: 1.7; display: block; }
.rd-pinned-body { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rd-pinned-count { flex: none; opacity: .8; }
.rd-pinned .rd-icon { width: 24px; height: 24px; color: inherit; }
.rd-pinned .rd-icon svg { transform: rotate(-90deg); width: 14px; height: 14px; }
.rd-results { position: absolute; inset: 0; overflow-y: auto; background: ${light ? '#fff' : '#1b1d22'}; z-index: 3; padding: 6px; }
.rd-results[hidden] { display: none; }
.rd-results-head { padding: 8px 10px; font-size: 12px; color: ${light ? '#7a8091' : '#9aa0ad'}; }
.rd-result {
  display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; width: 100%; text-align: left;
  border: 0; background: transparent; padding: 9px 10px; border-radius: 10px; cursor: pointer; font: inherit; color: inherit;
}
.rd-result:hover { background: ${light ? '#f2f5fb' : '#262a32'}; }
.rd-result-main { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.rd-result-main strong { font-size: 12px; font-weight: 600; color: ${light ? '#7a8091' : '#9aa0ad'}; }
.rd-result-excerpt { font-size: 13px; overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.rd-result mark { background: ${accent}33; color: inherit; border-radius: 3px; padding: 0 2px; }
.rd-result time { font-size: 11px; color: ${light ? '#939aab' : '#8b91a0'}; flex: none; }
.rd-typing { display: flex; gap: 4px; padding: 0 18px 8px; }
.rd-typing[hidden] { display: none; }
.rd-typing span { width: 6px; height: 6px; border-radius: 50%; background: ${light ? '#b8bdca' : '#5b6172'}; animation: rd-bounce 1.2s infinite; }
.rd-typing span:nth-child(2) { animation-delay: .15s; }
.rd-typing span:nth-child(3) { animation-delay: .3s; }
@keyframes rd-bounce { 0%, 60%, 100% { transform: translateY(0); opacity: .5; } 30% { transform: translateY(-4px); opacity: 1; } }
.rd-list { position: absolute; inset: 0; overflow-y: auto; background: ${light ? '#fff' : '#1b1d22'}; z-index: 2; padding: 8px; }
.rd-list[hidden] { display: none; }
.rd-list-head { padding: 8px 10px; font-size: 12px; color: ${light ? '#7a8091' : '#9aa0ad'}; }
.rd-item {
  display: flex; align-items: center; justify-content: space-between; gap: 10px; width: 100%; text-align: left;
  border: 0; background: transparent; padding: 10px 12px; border-radius: 12px; cursor: pointer; font: inherit; color: inherit;
}
.rd-item:hover, .rd-item.is-active { background: ${light ? '#f2f5fb' : '#262a32'}; }
.rd-item-main { display: flex; flex-direction: column; min-width: 0; gap: 2px; }
.rd-item-main strong { font-size: 14px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rd-item-main small { color: ${light ? '#7a8091' : '#9aa0ad'}; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 210px; }
.rd-item-meta { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; font-size: 11px; color: ${light ? '#939aab' : '#8b91a0'}; }
.rd-dot { min-width: 18px; height: 18px; border-radius: 999px; background: #ff4d4f; color: #fff; font: 600 11px/18px system-ui; text-align: center; padding: 0 5px; }
.rd-composer { display: flex; flex-direction: column; border-top: 1px solid ${light ? '#eef0f5' : '#2b2f37'}; background: inherit; }
.rd-composer[hidden] { display: none; }
.rd-composer-row { display: flex; align-items: flex-end; gap: 6px; padding: 10px 12px; }
.rd-reply { display: flex; align-items: center; gap: 8px; padding: 8px 12px 0; font-size: 12px; color: ${light ? '#5b6172' : '#a8aebb'}; }
.rd-reply[hidden] { display: none; }
.rd-reply-icon svg { width: 14px; height: 14px; fill: none; stroke: currentColor; stroke-width: 1.7; display: block; color: ${accent}; }
.rd-reply-body { display: flex; flex-direction: column; min-width: 0; flex: 1; }
.rd-reply-body strong { font-weight: 600; }
.rd-reply-body small { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; opacity: .8; }
.rd-reply .rd-icon { width: 24px; height: 24px; color: inherit; }
.rd-reply .rd-icon svg { width: 14px; height: 14px; }
.rd-input {
  flex: 1; resize: none; border: 1px solid ${light ? '#e2e6ef' : '#333842'}; border-radius: 12px; padding: 9px 12px;
  font: inherit; line-height: 1.5; max-height: 120px; background: ${light ? '#fbfcfe' : '#20242b'}; color: inherit; outline: none;
}
.rd-input:focus { border-color: ${accent}; box-shadow: 0 0 0 3px ${accent}22; }
.rd-send {
  display: inline-flex; align-items: center; justify-content: center; width: 38px; height: 38px; flex: none;
  border: 0; border-radius: 11px; background: ${accent}; color: #fff; cursor: pointer;
}
.rd-send svg { width: 18px; height: 18px; fill: currentColor; stroke: none; }
.rd-send:disabled { opacity: .45; cursor: not-allowed; }
.rd-recording { display: flex; align-items: center; gap: 10px; padding: 12px 14px; border-top: 1px solid ${light ? '#eef0f5' : '#2b2f37'}; font-size: 13px; }
.rd-recording[hidden] { display: none; }
.rd-recording.is-error { color: #ff4d4f; }
.rd-rec-dot { width: 9px; height: 9px; border-radius: 50%; background: #ff4d4f; animation: rd-pulse 1s infinite; }
.rd-recording.is-error .rd-rec-dot { display: none; }
@keyframes rd-pulse { 0%, 100% { opacity: 1; } 50% { opacity: .3; } }
.rd-rec-time { font-variant-numeric: tabular-nums; font-weight: 600; }
.rd-rec-hint { flex: 1; opacity: .75; font-size: 12px; }
.rd-recording .rd-icon { color: inherit; }
.rd-footer { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 14px 12px; font-size: 12px; color: ${light ? '#5b6172' : '#a8aebb'}; }
.rd-footer[hidden] { display: none; }
.rd-stars { display: inline-flex; gap: 2px; }
.rd-star { border: 0; background: transparent; padding: 0; cursor: pointer; color: ${light ? '#c9cede' : '#4c525d'}; }
.rd-star svg { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 1.6; }
.rd-star:hover svg, .rd-star:hover ~ .rd-star svg { fill: #fbbf24; stroke: #fbbf24; }
@media (max-width: 480px) {
  .rd-panel { ${side}: 0; bottom: 0; width: 100vw; height: 100vh; height: 100dvh; max-width: none; border-radius: 0; border: 0; }
  .rd-launcher-slot { ${side}: 16px; bottom: 16px; }
}`;
  }
}
