import type { ChannelItem } from "./types.js";
// Shadow-DOM renderer. Two rules keep it usable inside someone else's page:
// every style is scoped to the shadow root, and the composer is a persistent
// node that re-renders only patch the message list, so typing is never
// interrupted and the caret never jumps.

import { requestMicrophone, collectRecordingChunks } from './recording.js';
import type { ResolvedOptions } from './config.js';
import type { ChatStore, Snapshot } from './store.js';
import type { ChatMessage, SearchHit } from './types.js';

const ICONS = {
  plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="12" cy="12" r="9"/><path d="M12 7v10M7 12h10"/></svg>',
  smile: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="12" cy="12" r="9"/><path d="M7.5 14a5 5 0 0 0 9 0"/><circle cx="8.5" cy="9" r=".7"/><circle cx="15.5" cy="9" r=".7"/></svg>',
  image: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="1.5"/><path d="m3 17 5-5 4 4 4-6 5 7"/></svg>',
  camera: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M3 7h4l2-3h6l2 3h4v13H3z"/><circle cx="12" cy="13" r="4"/></svg>',
  chat: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path></svg>',
  close: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>',
  minimize: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M5 12h14"/></svg>',
  headset: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 13v-2a8 8 0 0 1 16 0v2M4 12H3v7h4v-7H4Zm16 0h1v7h-4v-7h3ZM20 19c0 3-4 3-8 3"/></svg>',
  send: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"></line><polygon points="22 2 15 22 11 13 2 9 22 2"></polygon></svg>',
  clip: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"></path></svg>',
  back: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="19" y1="12" x2="5" y2="12"></line><polyline points="12 19 5 12 12 5"></polyline></svg>',
  retry: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"></polyline><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"></path></svg>',
  // 单勾=未读、双勾=已送达/已读，与坐席控制台三态一致。
  done: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>',
  doneAll: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><polyline points="7 13 10 16 18 7"></polyline><polyline points="2 13 5 16"></polyline><polyline points="13 7 15.5 9.5"></polyline></svg>',
  star: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"></polygon></svg>',
  search: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg>',
  quote: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 21c3 0 7-1 7-8V5c0-1.25-.756-2.017-2-2H4c-1.25 0-2 .75-2 1.972V11c0 1.25.75 2 2 2 1 0 1 0 1 1v1c0 1-1 2-2 2s-1 .008-1 1.031V20c0 1 0 1 1 1z"></path><path d="M15 21c3 0 7-1 7-8V5c0-1.25-.757-2.017-2-2h-4c-1.25 0-2 .75-2 1.972V11c0 1.25.75 2 2 2h.75c0 2.25.25 4-2.75 4v3c0 1 0 1 1 1z"></path></svg>',
  pin: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="17" x2="12" y2="22"></line><path d="M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1v4.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24Z"></path></svg>',
  mic: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"></path><path d="M19 10v2a7 7 0 0 1-14 0v-2"></path><line x1="12" y1="19" x2="12" y2="23"></line><line x1="8" y1="23" x2="16" y2="23"></line></svg>',
  trash: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path><line x1="10" y1="11" x2="10" y2="17"></line><line x1="14" y1="11" x2="14" y2="17"></line></svg>',
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
  /** Asks a human agent to take over an AI-generated reply. */
  onHandoff: (messageId: string) => void;
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
  #requestingMicrophone = false;
  #toolsNode?: HTMLDivElement;
  #emojiNode?: HTMLDivElement;
  #lightbox?: HTMLDivElement;
  #lightboxImage?: HTMLImageElement;
  #lightboxDownload?: HTMLAnchorElement;
  #msgMenu?: HTMLDivElement;
  #msgMenuTargetId?: string;
  #onLightboxKey?: (event: KeyboardEvent) => void;
  #longPressTimer?: ReturnType<typeof setTimeout>;

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
      const customCss = this.#options.customCss
        ? `<style>${this.#sanitizeCss(this.#options.customCss)}</style>`
        : '';
      this.#root.innerHTML = `<style>${this.#styles()}</style>${customCss}<div class="rd-launcher-slot"></div><div class="rd-panel-slot"></div>`;
      this.#buildLauncher();
      this.#buildPanel();
    }
    this.#syncLauncher(snapshot);
    this.#syncPanel(snapshot);
    if (first) this.#autoGrow();
  }

  /** Re-brands the widget from server-side white-label config delivered on bootstrap. */
  applyWhiteLabel(config: Partial<ResolvedOptions>): void {
    Object.assign(this.#options, config);
    const customCss = this.#options.customCss
      ? `<style class="rd-extra-style">${this.#sanitizeCss(this.#options.customCss)}</style>`
      : '';
    this.#root.innerHTML = `<style class="rd-main-style">${this.#styles()}</style>${customCss}<div class="rd-launcher-slot"></div><div class="rd-panel-slot"></div>`;
    this.#buildLauncher();
    this.#buildPanel();
    if (this.#lastSnapshot) {
      this.#syncLauncher(this.#lastSnapshot);
      this.#syncPanel(this.#lastSnapshot);
    }
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
      this.#autoGrow();
      this.#syncSendButton();
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
    button.setAttribute('aria-label', this.#options.title);
    button.innerHTML = `<span class="rd-launcher-icon">${this.#options.logoUrl ? `<img class="rd-launcher-logo" src="${escapeAttr(this.#options.logoUrl)}" alt="">` : ICONS.chat}</span><span class="rd-launcher-label">${escapeHtml(this.#options.title)}</span><span class="rd-launcher-badge" hidden>0</span>`;
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
    panel.className = `rd-panel${this.#options.embedded ? ' is-embedded' : ''}`;
    panel.setAttribute('role', this.#options.embedded ? 'region' : 'dialog');
    panel.setAttribute('aria-label', this.#options.title);
    panel.hidden = true;
    panel.innerHTML = `
      <header class="rd-header">
        <div class="rd-header-main">
          <span class="rd-avatar">${this.#brandImg(ICONS.chat, true)}</span>
          <div class="rd-heading">
            <strong>${escapeHtml(this.#options.embedded && this.#options.title === '语聊客服' ? '在线客服' : this.#options.title)}</strong>
            <span class="rd-service-subtitle">${escapeHtml(this.#options.subtitle)}</span>
            <span class="rd-subtitle"></span>
          </div>
        </div>
        <div class="rd-header-actions">
          <button type="button" class="rd-icon rd-search-toggle" title="搜索聊天记录">${ICONS.search}</button>
          <button type="button" class="rd-icon rd-back" title="返回会话列表" hidden>${ICONS.back}</button>
          ${this.#options.embedded ? `<button type="button" class="rd-icon rd-page-back" title="返回" aria-label="返回">${ICONS.back}</button>` : `<button type="button" class="rd-icon rd-minimize" title="最小化" aria-label="最小化">${ICONS.minimize}</button><button type="button" class="rd-icon rd-close" title="收起" aria-label="关闭">${ICONS.close}</button>`}
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
        <div class="rd-composer-toolbar" aria-label="消息工具">
          <button type="button" class="rd-icon rd-emoji-toggle" title="表情" aria-label="表情" aria-expanded="false">${ICONS.smile}</button>
          <button type="button" class="rd-icon rd-more-toggle" title="图片和文件" aria-label="图片和文件" aria-expanded="false">${ICONS.plus}</button>
          <button type="button" class="rd-icon rd-mic" title="录制语音" aria-label="录制语音" hidden>${ICONS.mic}</button>
        </div>
        <div class="rd-composer-row">
          <textarea class="rd-input" rows="1" placeholder="${escapeAttr(this.#options.placeholder)}" maxlength="4000"></textarea>
          <button type="submit" class="rd-send" title="发送" aria-label="发送消息" ${this.#options.theme === 'dark' ? 'hidden' : ''} disabled>发送</button>
        </div>
        <div class="rd-tools" hidden>
          <button type="button" class="rd-tool" data-picker="image"><span>${ICONS.image}</span>图片</button>
          <button type="button" class="rd-tool" data-picker="camera"><span>${ICONS.camera}</span>拍照</button>
          <button type="button" class="rd-tool" data-picker="file"><span>${ICONS.clip}</span>文件</button>
          <button type="button" class="rd-tool rd-history"><span>${ICONS.search}</span>聊天记录</button>
          <p class="rd-tools-hint">图片和文件选择后发送，请勿上传密码等敏感信息</p>
        </div>
        <div class="rd-emojis" aria-label="选择表情" hidden><div class="rd-emoji-tabs" role="tablist" aria-label="表情分类"><button type="button" role="tab" aria-selected="true" data-emoji-category="0">笑脸</button><button type="button" role="tab" aria-selected="false" data-emoji-category="1">心情</button><button type="button" role="tab" aria-selected="false" data-emoji-category="2">手势</button><button type="button" role="tab" aria-selected="false" data-emoji-category="3">日常</button></div><div class="rd-emoji-grid" data-emoji-group="0"><button type="button" class="rd-emoji" aria-label="😀">😀</button><button type="button" class="rd-emoji" aria-label="😃">😃</button><button type="button" class="rd-emoji" aria-label="😄">😄</button><button type="button" class="rd-emoji" aria-label="😁">😁</button><button type="button" class="rd-emoji" aria-label="😆">😆</button><button type="button" class="rd-emoji" aria-label="😅">😅</button><button type="button" class="rd-emoji" aria-label="😂">😂</button><button type="button" class="rd-emoji" aria-label="🤣">🤣</button><button type="button" class="rd-emoji" aria-label="😊">😊</button><button type="button" class="rd-emoji" aria-label="🙂">🙂</button><button type="button" class="rd-emoji" aria-label="🙃">🙃</button><button type="button" class="rd-emoji" aria-label="😉">😉</button><button type="button" class="rd-emoji" aria-label="😌">😌</button><button type="button" class="rd-emoji" aria-label="😍">😍</button><button type="button" class="rd-emoji" aria-label="🥰">🥰</button><button type="button" class="rd-emoji" aria-label="😘">😘</button><button type="button" class="rd-emoji" aria-label="😋">😋</button><button type="button" class="rd-emoji" aria-label="😛">😛</button><button type="button" class="rd-emoji" aria-label="😜">😜</button><button type="button" class="rd-emoji" aria-label="🤪">🤪</button><button type="button" class="rd-emoji" aria-label="🤔">🤔</button><button type="button" class="rd-emoji" aria-label="🤭">🤭</button><button type="button" class="rd-emoji" aria-label="🤫">🤫</button><button type="button" class="rd-emoji" aria-label="🫡">🫡</button></div><div class="rd-emoji-grid" data-emoji-group="1" hidden><button type="button" class="rd-emoji" aria-label="😎">😎</button><button type="button" class="rd-emoji" aria-label="🤩">🤩</button><button type="button" class="rd-emoji" aria-label="🥳">🥳</button><button type="button" class="rd-emoji" aria-label="😏">😏</button><button type="button" class="rd-emoji" aria-label="😒">😒</button><button type="button" class="rd-emoji" aria-label="😔">😔</button><button type="button" class="rd-emoji" aria-label="😢">😢</button><button type="button" class="rd-emoji" aria-label="😭">😭</button><button type="button" class="rd-emoji" aria-label="😤">😤</button><button type="button" class="rd-emoji" aria-label="😠">😠</button><button type="button" class="rd-emoji" aria-label="😡">😡</button><button type="button" class="rd-emoji" aria-label="🤯">🤯</button><button type="button" class="rd-emoji" aria-label="😳">😳</button><button type="button" class="rd-emoji" aria-label="🥺">🥺</button><button type="button" class="rd-emoji" aria-label="😱">😱</button><button type="button" class="rd-emoji" aria-label="😨">😨</button><button type="button" class="rd-emoji" aria-label="😰">😰</button><button type="button" class="rd-emoji" aria-label="😥">😥</button><button type="button" class="rd-emoji" aria-label="😓">😓</button><button type="button" class="rd-emoji" aria-label="🤗">🤗</button><button type="button" class="rd-emoji" aria-label="🥱">🥱</button><button type="button" class="rd-emoji" aria-label="😴">😴</button><button type="button" class="rd-emoji" aria-label="😷">😷</button><button type="button" class="rd-emoji" aria-label="🤒">🤒</button></div><div class="rd-emoji-grid" data-emoji-group="2" hidden><button type="button" class="rd-emoji" aria-label="👍">👍</button><button type="button" class="rd-emoji" aria-label="👎">👎</button><button type="button" class="rd-emoji" aria-label="👏">👏</button><button type="button" class="rd-emoji" aria-label="🙌">🙌</button><button type="button" class="rd-emoji" aria-label="👐">👐</button><button type="button" class="rd-emoji" aria-label="🤝">🤝</button><button type="button" class="rd-emoji" aria-label="🙏">🙏</button><button type="button" class="rd-emoji" aria-label="💪">💪</button><button type="button" class="rd-emoji" aria-label="👌">👌</button><button type="button" class="rd-emoji" aria-label="✌️">✌️</button><button type="button" class="rd-emoji" aria-label="🤞">🤞</button><button type="button" class="rd-emoji" aria-label="🤟">🤟</button><button type="button" class="rd-emoji" aria-label="🤘">🤘</button><button type="button" class="rd-emoji" aria-label="🤙">🤙</button><button type="button" class="rd-emoji" aria-label="👋">👋</button><button type="button" class="rd-emoji" aria-label="🤚">🤚</button><button type="button" class="rd-emoji" aria-label="✋">✋</button><button type="button" class="rd-emoji" aria-label="🖐️">🖐️</button><button type="button" class="rd-emoji" aria-label="👊">👊</button><button type="button" class="rd-emoji" aria-label="✊">✊</button><button type="button" class="rd-emoji" aria-label="🤛">🤛</button><button type="button" class="rd-emoji" aria-label="🤜">🤜</button><button type="button" class="rd-emoji" aria-label="🙋">🙋</button><button type="button" class="rd-emoji" aria-label="🫶">🫶</button></div><div class="rd-emoji-grid" data-emoji-group="3" hidden><button type="button" class="rd-emoji" aria-label="❤️">❤️</button><button type="button" class="rd-emoji" aria-label="🧡">🧡</button><button type="button" class="rd-emoji" aria-label="💛">💛</button><button type="button" class="rd-emoji" aria-label="💚">💚</button><button type="button" class="rd-emoji" aria-label="💙">💙</button><button type="button" class="rd-emoji" aria-label="💜">💜</button><button type="button" class="rd-emoji" aria-label="🖤">🖤</button><button type="button" class="rd-emoji" aria-label="🤍">🤍</button><button type="button" class="rd-emoji" aria-label="💕">💕</button><button type="button" class="rd-emoji" aria-label="💖">💖</button><button type="button" class="rd-emoji" aria-label="💯">💯</button><button type="button" class="rd-emoji" aria-label="✅">✅</button><button type="button" class="rd-emoji" aria-label="🎉">🎉</button><button type="button" class="rd-emoji" aria-label="🎊">🎊</button><button type="button" class="rd-emoji" aria-label="🎁">🎁</button><button type="button" class="rd-emoji" aria-label="🌹">🌹</button><button type="button" class="rd-emoji" aria-label="🌸">🌸</button><button type="button" class="rd-emoji" aria-label="☀️">☀️</button><button type="button" class="rd-emoji" aria-label="🌈">🌈</button><button type="button" class="rd-emoji" aria-label="⭐">⭐</button><button type="button" class="rd-emoji" aria-label="🔥">🔥</button><button type="button" class="rd-emoji" aria-label="☕">☕</button><button type="button" class="rd-emoji" aria-label="🍰">🍰</button><button type="button" class="rd-emoji" aria-label="🎈">🎈</button></div></div>
        <div class="rd-upload-status" role="status" hidden></div>
        <input type="file" class="rd-upload-input" data-kind="file" multiple hidden>
        <input type="file" class="rd-upload-input" data-kind="image" accept="image/*" multiple hidden>
        <input type="file" class="rd-upload-input" data-kind="camera" accept="image/*" capture="environment" hidden>
      </form>
      <div class="rd-footer"></div>
      <div class="rd-msg-menu" hidden role="menu" aria-label="消息操作">
        <button type="button" role="menuitem" data-msg-action="copy">复制</button>
        <button type="button" role="menuitem" data-msg-action="quote">引用</button>
      </div>
      <div class="rd-lightbox" hidden role="dialog" aria-modal="true" aria-label="查看图片">
        <div class="rd-lightbox-toolbar">
          <a class="rd-lightbox-download" href="#" download target="_blank" rel="noopener noreferrer">下载</a>
          <button type="button" class="rd-lightbox-close" title="关闭" aria-label="关闭">${ICONS.close}</button>
        </div>
        <img class="rd-lightbox-img" alt="">
      </div>`;

    this.#composer = panel.querySelector('.rd-composer') as HTMLFormElement;
    this.#lightbox = panel.querySelector('.rd-lightbox') as HTMLDivElement;
    this.#lightboxImage = panel.querySelector('.rd-lightbox-img') as HTMLImageElement;
    this.#lightboxDownload = panel.querySelector('.rd-lightbox-download') as HTMLAnchorElement;
    this.#msgMenu = panel.querySelector('.rd-msg-menu') as HTMLDivElement;
    this.#lightbox.querySelector('.rd-lightbox-close')?.addEventListener('click', (event) => {
      event.stopPropagation();
      this.#closeLightbox();
    });
    // 点遮罩关闭；点图片本身不关闭，方便看细节。
    this.#lightbox.addEventListener('click', (event) => {
      if (event.target === this.#lightbox) {
        this.#closeLightbox();
      }
    });
    this.#msgMenu.querySelectorAll<HTMLButtonElement>('[data-msg-action]').forEach((button) => {
      button.addEventListener('click', () => {
        const action = button.dataset.msgAction;
        const id = this.#msgMenuTargetId;
        this.#hideMsgMenu();
        if (!id || !action) {
          return;
        }
        if (action === 'quote') {
          this.#handlers.onQuote(id);
          return;
        }
        if (action === 'copy') {
          void this.#copyMessage(id);
        }
      });
    });
    panel.addEventListener('pointerdown', (event) => {
      const target = event.target as Node | null;
      if (this.#msgMenu && !this.#msgMenu.hidden && target && !this.#msgMenu.contains(target)) {
        this.#hideMsgMenu();
      }
    });
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

    this.#toolsNode = panel.querySelector('.rd-tools') as HTMLDivElement;
    this.#emojiNode = panel.querySelector('.rd-emojis') as HTMLDivElement;
    const more = panel.querySelector('.rd-more-toggle') as HTMLButtonElement;
    const emojiToggle = panel.querySelector('.rd-emoji-toggle') as HTMLButtonElement;
    const closePanels = () => {
      this.#toolsNode!.hidden = true;
      this.#emojiNode!.hidden = true;
      more.setAttribute('aria-expanded', 'false');
      emojiToggle.setAttribute('aria-expanded', 'false');
    };
    // 点消息区空白（或气泡外区域）收起「+」工具栏 / 表情面板，对齐常见 IM 交互。
    const thread = panel.querySelector('.rd-thread') as HTMLDivElement;
    thread.addEventListener('pointerdown', () => {
      if (this.#toolsNode!.hidden && this.#emojiNode!.hidden) return;
      closePanels();
    });
    // Keep touch taps from moving focus to the button and fighting the soft keyboard.
    [more, emojiToggle].forEach(button => button.addEventListener('pointerdown', event => event.preventDefault()));
    panel.querySelectorAll<HTMLButtonElement>('[data-emoji-category]').forEach(button => {
      button.addEventListener('pointerdown', event => event.preventDefault());
      button.addEventListener('click', () => {
        panel.querySelectorAll<HTMLButtonElement>('[data-emoji-category]').forEach(tab => tab.setAttribute('aria-selected', String(tab === button)));
        panel.querySelectorAll<HTMLElement>('[data-emoji-group]').forEach(group => { group.hidden = group.dataset.emojiGroup !== button.dataset.emojiCategory; });
      });
    });
    more.addEventListener('click', () => {
      const open = this.#toolsNode!.hidden;
      if (open) this.#input?.blur();
      closePanels();
      this.#toolsNode!.hidden = !open;
      more.setAttribute('aria-expanded', String(open));
    });
    emojiToggle.addEventListener('click', () => {
      const open = this.#emojiNode!.hidden;
      if (open) this.#input?.blur();
      closePanels();
      this.#emojiNode!.hidden = !open;
      emojiToggle.setAttribute('aria-expanded', String(open));
    });
    panel.querySelectorAll<HTMLButtonElement>('[data-picker]').forEach(button => button.addEventListener('click', () => {
      const picker = panel.querySelector<HTMLInputElement>(`input[data-kind="${button.dataset.picker}"]`);
      picker?.click();
    }));
    panel.querySelectorAll<HTMLInputElement>('.rd-upload-input').forEach(fileInput => fileInput.addEventListener('change', () => {
      if (fileInput.files?.length) {
        this.#handlers.onFiles(fileInput.files);
        closePanels();
      }
      fileInput.value = '';
    }));
    panel.querySelector('.rd-history')?.addEventListener('click', () => {
      closePanels();
      this.#searchOpen = true;
      this.#syncSearchBar();
      if (this.#lastSnapshot) this.#renderResults(this.#lastSnapshot);
      this.#searchInput?.focus();
    });
    panel.querySelectorAll<HTMLButtonElement>('.rd-emoji').forEach(button => button.addEventListener('click', () => {
      const input = this.#input!;
      // 在当前光标处插入，避免选表情时覆盖已经输入的咨询内容。
      const emoji = button.textContent ?? '';
      if (input.value.length - (input.selectionEnd - input.selectionStart) + emoji.length > input.maxLength) return;
      input.setRangeText(emoji, input.selectionStart, input.selectionEnd, 'end');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    }));
    this.#input.addEventListener('focus', closePanels);

    this.#composer.addEventListener('submit', (event) => {
      event.preventDefault();
      const text = this.#input?.value ?? '';
      if (!text.trim()) {
        return;
      }
      this.#handlers.onSend(text);
      closePanels();
      if (this.#input) {
        this.#input.value = '';
        this.#autoGrow();
        this.#syncSendButton();
      }
    });
    this.#input.addEventListener('input', () => {
      this.#autoGrow();
      this.#syncSendButton();
      this.#handlers.onTyping();
    });
    this.#input.addEventListener('keydown', (event) => {
      // 手机软键盘 Enter 多半是换行；桌面才用 Enter 发送（Shift+Enter 换行）。
      const coarse = typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches;
      if (event.key === 'Enter' && !event.shiftKey && !event.isComposing && !coarse) {
        event.preventDefault();
        this.#composer?.requestSubmit();
      }
      if (event.key === 'Escape') {
        if (!this.#lightbox?.hidden) {
          this.#closeLightbox();
          return;
        }
        if (!this.#msgMenu?.hidden) {
          this.#hideMsgMenu();
          return;
        }
        if (!this.#toolsNode?.hidden || !this.#emojiNode?.hidden) {
          closePanels();
          return;
        }
        if (!this.#replyBar?.hidden) {
          this.#handlers.onClearQuote();
        }
      }
    });
    // 剪贴板里的截图直接发出去，少走一遍「更多 → 图片」。
    this.#input.addEventListener('paste', (event) => {
      const files = event.clipboardData?.files;
      if (!files?.length) {
        return;
      }
      const images = Array.from(files).filter((file) => file.type.startsWith('image/'));
      if (!images.length) {
        return;
      }
      event.preventDefault();
      const transfer = new DataTransfer();
      images.forEach((file) => transfer.items.add(file));
      this.#handlers.onFiles(transfer.files);
    });
    (panel.querySelector('.rd-reply-close') as HTMLButtonElement).addEventListener('click', () =>
      this.#handlers.onClearQuote(),
    );

    // Voice notes. The button only appears where the browser can actually
    // record, because a microphone control that always fails is worse than no
    // control at all.
    const mic = panel.querySelector('.rd-mic') as HTMLButtonElement;
    mic.hidden = false;
    mic.addEventListener('click', () => {
      if (typeof MediaRecorder === 'undefined' || typeof navigator.mediaDevices?.getUserMedia !== 'function') {
        this.#flashRecordingError('此浏览器不支持录音，请使用Chrome或Edge，并通过HTTPS或localhost访问');
        return;
      }
      void this.#startRecording();
    });
    (panel.querySelector('.rd-rec-cancel') as HTMLButtonElement).addEventListener('click', () => this.#stopRecording(true));
    (panel.querySelector('.rd-rec-send') as HTMLButtonElement).addEventListener('click', () => this.#stopRecording(false));

    let searchTimer: ReturnType<typeof setTimeout> | undefined;
    (panel.querySelector('.rd-search-toggle') as HTMLButtonElement).addEventListener('click', () => {
      this.#searchOpen = true;
      this.#syncSearchBar();
      if (this.#lastSnapshot) this.#renderResults(this.#lastSnapshot);
      this.#searchInput?.focus();
    });
    (panel.querySelector('.rd-search-close') as HTMLButtonElement).addEventListener('click', () => {
      if (searchTimer) clearTimeout(searchTimer);
      this.#searchOpen = false;
      this.#handlers.onClearSearch();
      if (this.#searchInput) {
        this.#searchInput.value = '';
      }
      this.#syncSearchBar();
    });
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
      if (event.key === 'Enter') {
        event.preventDefault();
        if (searchTimer) clearTimeout(searchTimer);
        this.#handlers.onSearch(this.#searchInput?.value ?? '');
      }
      if (event.key === 'Escape') {
        (panel.querySelector('.rd-search-close') as HTMLButtonElement).click();
      }
    });

    panel.querySelector('.rd-close')?.addEventListener('click', () => this.#handlers.onClose());
    panel.querySelector('.rd-minimize')?.addEventListener('click', () => this.#handlers.onClose());
    panel.querySelector('.rd-page-back')?.addEventListener('click', () => {
      if (this.#lastSnapshot && this.#lastSnapshot.conversations.length > 1 && this.#lastSnapshot.activeId) {
        this.#handlers.onBack();
      } else if (window.parent === window && window.history.length > 1) {
        window.history.back();
      } else {
        this.#handlers.onClose();
      }
    });
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

  #syncSendButton(): void {
    const hasText = Boolean(this.#input?.value.trim());
    const send = this.#composer?.querySelector<HTMLButtonElement>('.rd-send');
    const more = this.#composer?.querySelector<HTMLButtonElement>('.rd-more-toggle');
    if (send) {
      send.hidden = this.#options.theme === 'dark' && !hasText;
      send.disabled = !hasText;
    }
    if (more) more.hidden = this.#options.theme === 'dark' && hasText;
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
    subtitle.textContent = snapshot.automation?.channelSubtitle ? `${snapshot.automation.channelSubtitle} · ${this.#subtitle(snapshot)}` : this.#subtitle(snapshot);
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
    const uploadStatus = composer.querySelector('.rd-upload-status') as HTMLElement;
    uploadStatus.hidden = snapshot.uploading === 0;
    uploadStatus.textContent = snapshot.uploading ? `正在发送 ${snapshot.uploading} 个附件…` : '';
  }

  #subtitle(snapshot: Snapshot): string {
    if (snapshot.status === 'BOOTSTRAPPING') {
      return '正在连接…';
    }
    if (snapshot.status === 'FAILED') {
      return snapshot.error ?? '连接失败';
    }
    if (snapshot.offline) {
      return snapshot.offlineMessage || this.#options.offlineMessage || '当前离线，留言稍后回复';
    }
    if (snapshot.agentTyping) {
      return '客服正在输入…';
    }
    if (snapshot.connection !== 'OPEN') {
      return '正在重连…';
    }
    if (snapshot.agentsOnline > 0) {
      return snapshot.aiEnabled ? `在线 ${snapshot.agentsOnline} · 可自动应答` : `在线 ${snapshot.agentsOnline}`;
    }
    return snapshot.offlineMessage || this.#options.offlineMessage || '离线 · 请留言';
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

  #channelItemHtml(i: ChannelItem): string {
    return i.action === 'LINK' && /^https?:\/\//i.test(i.value)
      ? `<a class="rd-channel-chip" href="${escapeAttr(i.value)}" target="_blank" rel="noopener noreferrer">${escapeHtml(i.title)} ↗</a>`
      : `<button type="button" class="rd-channel-chip" data-channel="${escapeAttr(i.id)}">${escapeHtml(i.title)}</button>`;
  }

  #bindChannelActions(node: HTMLElement, snapshot: Snapshot): void {
    const c=snapshot.automation;
    const items=[...(c?.menuItems??[]),...(c?.quickLinks??[]),...(c?.diversionLinks??[]),...(c?.cards??[])];
    node.querySelectorAll<HTMLButtonElement>('[data-question]').forEach(b=>b.onclick=()=>this.#handlers.onSend(b.dataset.question!));
    node.querySelectorAll<HTMLButtonElement>('[data-channel]').forEach(b=>b.onclick=()=>{
      const item=items.find(i=>i.id===b.dataset.channel);if(item)void this.#store.selectChannelItem(item);
    });
  }

  #welcomeSuggestions(snapshot: Snapshot): string {
    const c=snapshot.automation;if(!c)return '';
    return `<div class="rd-welcome-suggestions">${c.guideText || c.guideQuestions?.length ? `<div class="rd-guide-title">${escapeHtml(c.guideText || '你可能想了解')}</div>` : ''}
      <div class="rd-channel-row">${(c.guideQuestions??[]).map(q=>`<button type="button" class="rd-channel-chip" data-question="${escapeAttr(q)}">${escapeHtml(q)}</button>`).join('')}</div>
      ${(c.cards??[]).map(i=>`<div class="rd-channel-card">${i.imageUrl && /^https?:\/\//i.test(i.imageUrl)?`<img src="${escapeAttr(i.imageUrl)}" alt="" loading="lazy">`:''}<div><strong>${escapeHtml(i.title)}</strong><p>${escapeHtml(i.description||'')}</p>${this.#channelItemHtml(i)}</div></div>`).join('')}</div>`;
  }

  #welcomeHtml(snapshot: Snapshot): string {
    // 欢迎标题跟渠道名走，避免 H5 已改渠道标题却仍写死「语聊客服」。
    const brand =
      snapshot.automation?.channelTitle ||
      (this.#options.embedded && this.#options.title === '语聊客服' ? '在线客服' : this.#options.title);
    return `<div class="rd-empty">
      <span class="rd-avatar lg">${this.#brandImg(ICONS.headset, false)}</span>
      <div class="rd-welcome-body"><strong>您好，欢迎来到${escapeHtml(brand)}！</strong><p>${escapeHtml(snapshot.automation?.openReply || snapshot.welcomeMessage || '我们很高兴为您服务，请问有什么可以帮您？')}</p>${this.#welcomeSuggestions(snapshot)}</div>
    </div>`;
  }

  /** 有历史时不要再插欢迎语；加载中用占位，避免刷新闪默认客服话术。 */
  #shouldShowWelcome(snapshot: Snapshot): boolean {
    if (snapshot.messages.length > 0 || snapshot.loadingThread) {
      return false;
    }
    const active = snapshot.conversations.find((item) => item.id === snapshot.activeId);
    // 会话列表已知道有消息序号，历史还在路上：继续等，不画欢迎语。
    if (active && (active.lastSequence ?? 0) > 0) {
      return false;
    }
    return true;
  }

  #threadLoadingHtml(): string {
    return `<div class="rd-thread-loading" aria-live="polite">正在加载消息…</div>`;
  }

  #renderChannel(snapshot: Snapshot): void {
    let panel=this.#root.querySelector<HTMLDivElement>('.rd-channel');
    if(!panel){panel=document.createElement('div');panel.className='rd-channel';this.#messagesNode?.after(panel);}
    const c=snapshot.automation;if(!c){panel.hidden=true;return;}
    const title=this.#root.querySelector<HTMLElement>('.rd-heading strong');
    if(title)title.textContent=c.channelTitle || (this.#options.embedded && this.#options.title === '语聊客服' ? '在线客服' : this.#options.title);
    const items=[...(c.menuItems??[]),...(c.quickLinks??[]),...(c.diversionLinks??[])];
    panel.innerHTML=`<div class="rd-channel-row">${items.map(i=>this.#channelItemHtml(i)).join('')}</div>`;
    // 欢迎页已有引导问题/卡片时，底部再铺一层相同 chips 会重复；有消息后再显示渠道入口。
    panel.hidden =
      items.length === 0 ||
      (snapshot.conversations.length > 1 && !snapshot.activeId) ||
      this.#shouldShowWelcome(snapshot);
    this.#bindChannelActions(panel,snapshot);
  }

  #renderThread(snapshot: Snapshot): void {
    const node = this.#messagesNode;
    if (!node) {
      return;
    }
    const conversationChanged = this.#renderedConversation !== snapshot.activeId;
    this.#renderChannel(snapshot);
    this.#renderedConversation = snapshot.activeId;
    const previousCount = node.querySelectorAll('.rd-msg').length;
    const shouldStick = this.#atBottom || conversationChanged || snapshot.messages.length > previousCount;

    if (snapshot.messages.length === 0) {
      // 刷新后短暂无消息：有历史则显示加载，全新会话才显示欢迎语。
      node.innerHTML = this.#shouldShowWelcome(snapshot)
        ? this.#welcomeHtml(snapshot)
        : this.#threadLoadingHtml();
      this.#bindChannelActions(node,snapshot);
    } else {
      // 已有聊天记录时不再置顶欢迎语，避免老会话每次刷新都像新客服开场。
      const parts: string[] = [];
      if (snapshot.hasMore) {
        parts.push(`<button type="button" class="rd-more" data-more="1">加载更早的消息</button>`);
      }
      let lastDay = '';
      let lastTime = 0;
      for (const message of snapshot.messages) {
        const day = dayLabel(message.createdAt);
        if (day && day !== lastDay) {
          parts.push(`<div class="rd-day">${escapeHtml(day)}</div>`);
          lastDay = day;
        }
        const createdTime = new Date(message.createdAt).getTime();
        if (Number.isFinite(createdTime) && (!lastTime || createdTime - lastTime >= 300_000)) {
          parts.push(`<div class="rd-time-separator">${escapeHtml(timeLabel(message.createdAt))}</div>`);
        }
        lastTime = createdTime;
        // The divider sits on the boundary the server reported at load time:
        // everything above it was seen, everything below arrived after.
        if (snapshot.readBoundary > 0 && message.sequence === snapshot.readBoundary && message !== snapshot.messages.at(-1)) {
          parts.push(`<div class="rd-unread"><span>以下为新消息</span></div>`);
        }
        parts.push(this.#messageHtml(snapshot, message));
      }
      node.innerHTML = parts.join('');
      this.#bindChannelActions(node, snapshot);
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
      node.querySelectorAll<HTMLElement>('[data-handoff]').forEach((button) => {
        button.addEventListener('click', () => {
          const id = button.dataset.handoff;
          if (id) {
            this.#handlers.onHandoff(id);
          }
        });
      });
      node.querySelectorAll<HTMLElement>('[data-more]').forEach((button) => {
        button.addEventListener('click', () => this.#handlers.onLoadOlder());
      });
      this.#bindMessageImages(node);
      this.#bindMessageGestures(node);
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
          ? `<button type="button" class="rd-state is-failed" data-retry="${escapeAttr(message.localId)}" title="${escapeAttr(message.error || '发送失败')}">${ICONS.retry}${escapeHtml(message.error || '发送失败')}，重试</button>`
          : mine
            ? this.#receiptHtml(snapshot, message)
            : '';
    const edited = message.editedAt ? '<span class="rd-edited">已编辑</span>' : '';
    const pinned = message.pinnedAt ? `<span class="rd-pinned-mark" title="已置顶">${ICONS.pin}</span>` : '';
    const forward = message.forwardedFromId ? '<span class="rd-forwarded">转发的消息</span>' : '';
    const quote = message.replyTo ? this.#quoteHtml(message.replyTo) : '';
    const reactions = this.#reactionsHtml(message);
    // AI 自动回复对访客透明化：明确身份 + 免责声明 + 一键转人工，避免「在跟机器人聊」的迷惑感。
    const isAI = !mine && message.metadata?.ai === true && message.metadata?.handoff !== true;
    const aiBadge = isAI ? `<span class="rd-ai-badge" title="由 AI 自动生成的内容">AI</span>` : '';
    const aiFooter = isAI
      ? `<span class="rd-ai-note">由 AI 生成，仅供参考<button type="button" class="rd-handoff-btn" data-handoff="${escapeAttr(message.id)}">转人工</button></span>`
      : '';
    // data-copy 供长按菜单复制；无正文时用类型占位，避免剪贴板空串。
    const copyText =
      message.content?.trim() ||
      (message.messageType === 'IMAGE'
        ? '[图片]'
        : message.messageType === 'AUDIO'
          ? '[语音]'
          : message.attachments?.length
            ? '[文件]'
            : '');
    return `<div class="rd-row rd-msg ${mine ? 'is-mine' : 'is-theirs'}${isAI ? ' is-ai' : ''}" data-message="${escapeAttr(message.id)}" data-copy="${escapeAttr(copyText)}">
      ${mine ? '' : `<span class="rd-avatar sm">${this.#brandImg(ICONS.chat, false)}</span>`}
      <div class="rd-bubble-group">
        ${mine || !message.senderName ? '' : `<span class="rd-sender">${escapeHtml(message.senderName)}${aiBadge}</span>`}
        <div class="rd-bubble-wrap">
          <div class="rd-bubble">${quote}${forward}${this.#bodyHtml(message)}</div>
          <button type="button" class="rd-quote-btn" data-quote="${escapeAttr(message.id)}" title="引用回复">${ICONS.quote}</button>
        </div>
        ${reactions}
        <span class="rd-time">${escapeHtml(timeLabel(message.createdAt))}${edited}${pinned}${state}</span>
        ${aiFooter}
      </div>
    </div>`;
  }

  /**
   * 访客自己发出的消息回执：未读（单勾灰）→ 已送达（双勾灰）→ 已读（双勾主色）。
   * 坐席消息不展示回执；发送中 / 失败由调用方先处理。
   */
  #receiptHtml(snapshot: Snapshot, message: ChatMessage): string {
    const sequence = message.sequence;
    if (sequence <= 0) {
      return `<span class="rd-receipt">${ICONS.done}未读</span>`;
    }
    if (sequence <= snapshot.agentLastReadSequence) {
      return `<span class="rd-receipt is-read">${ICONS.doneAll}已读</span>`;
    }
    if (sequence <= snapshot.agentLastDeliveredSequence) {
      return `<span class="rd-receipt is-delivered">${ICONS.doneAll}已送达</span>`;
    }
    return `<span class="rd-receipt">${ICONS.done}未读</span>`;
  }

  /** The quoted excerpt shown above a reply inside its bubble. */
  #quoteHtml(quote: NonNullable<ChatMessage['replyTo']>): string {
    const label = quote.senderType === 'VISITOR' ? '我' : quote.senderName || '客服';
    const body = quote.deletedAt
      ? '该消息已被撤回'
      : quote.messageType === 'TEXT'
        ? quote.content
        : quote.messageType === 'IMAGE'
          ? '[图片]'
          : quote.messageType === 'AUDIO'
            ? '[语音]'
            : '[文件]';
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
      const media = attachments.map((attachment) => this.#attachmentHtml(attachment)).join('');
      const raw = message.content?.trim() ?? '';
      // 服务端常把图片 content 填成文件名；再当 caption 画一遍会显得像重复标签。
      const filenameOnly =
        Boolean(raw) &&
        attachments.some((attachment) => attachment.fileName === raw) &&
        (message.messageType === 'IMAGE' ||
          attachments.every((attachment) => attachment.contentType.startsWith('image/')));
      // 附件消息若带真正的说明文字，必须一起展示；只渲染附件会丢掉访客写的 caption。
      const caption = raw && !filenameOnly ? `<div class="rd-caption">${formatText(raw)}</div>` : '';
      return `${media}${caption}`;
    }
    return formatText(message.content);
  }

  /**
   * A voice note renders as a player plus the duration the sender's device
   * measured, because the audio element cannot report a duration for a stream
   * it has not buffered yet and a player that shows 0:00 until pressed reads as
   * broken.
   */
  /** 聊天图片组件内预览：遮罩 + 大图，Esc / 点遮罩 / 关闭按钮退出。 */
  #openLightbox(src: string, alt: string): void {
    if (!this.#lightbox || !this.#lightboxImage) {
      return;
    }
    this.#hideMsgMenu();
    this.#lightboxImage.src = src;
    this.#lightboxImage.alt = alt;
    if (this.#lightboxDownload) {
      // blob: 不能加 download 查询；远端文件带 download=1 方便直存。
      const href = src.startsWith('blob:') ? src : `${src}${src.includes('?') ? '&' : '?'}download=1`;
      this.#lightboxDownload.href = href;
      this.#lightboxDownload.download = alt && alt !== '图片' ? alt : 'image';
    }
    this.#lightbox.hidden = false;
    this.#root.host.classList.add('rd-lightbox-open');
    (this.#lightbox.querySelector('.rd-lightbox-close') as HTMLButtonElement | null)?.focus();
    this.#onLightboxKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        this.#closeLightbox();
      }
    };
    document.addEventListener('keydown', this.#onLightboxKey);
  }

  #closeLightbox(): void {
    if (!this.#lightbox || !this.#lightboxImage) {
      return;
    }
    this.#lightbox.hidden = true;
    this.#lightboxImage.removeAttribute('src');
    this.#root.host.classList.remove('rd-lightbox-open');
    if (this.#lightboxDownload) {
      this.#lightboxDownload.removeAttribute('href');
    }
    if (this.#onLightboxKey) {
      document.removeEventListener('keydown', this.#onLightboxKey);
      this.#onLightboxKey = undefined;
    }
  }

  /** 懒加载图片，失败时给出可点重试，避免灰块/裂图无反馈。 */
  #bindMessageImages(node: HTMLElement): void {
    node.querySelectorAll<HTMLImageElement>('img[data-src]').forEach((image) => {
      const src = image.dataset.src;
      if (src) {
        image.src = src;
        image.removeAttribute('data-src');
      }
      image.addEventListener('error', () => {
        const wrap = image.closest<HTMLElement>('.rd-image');
        if (!wrap) {
          return;
        }
        wrap.classList.add('is-broken');
        image.hidden = true;
        if (!wrap.querySelector('.rd-image-fallback')) {
          const fallback = document.createElement('span');
          fallback.className = 'rd-image-fallback';
          fallback.textContent = '加载失败，点击重试';
          wrap.appendChild(fallback);
        }
      });
      image.addEventListener('load', () => {
        const wrap = image.closest<HTMLElement>('.rd-image');
        wrap?.classList.remove('is-broken');
        image.hidden = false;
        wrap?.querySelector('.rd-image-fallback')?.remove();
      });
    });
    // 气泡内图片点开组件内灯箱，不依赖浏览器新标签（H5 / iframe 里经常被拦）。
    node.querySelectorAll<HTMLElement>('[data-lightbox]').forEach((thumb) => {
      thumb.addEventListener('click', (event) => {
        event.preventDefault();
        const src = thumb.dataset.lightbox;
        if (!src) {
          return;
        }
        // 裂图先重试加载，成功后再允许进灯箱。
        if (thumb.classList.contains('is-broken')) {
          const image = thumb.querySelector('img');
          if (image) {
            const bust = `${src}${src.includes('?') ? '&' : '?'}r=${Date.now()}`;
            image.hidden = false;
            image.src = bust;
            thumb.dataset.lightbox = src;
            thumb.querySelector('.rd-image-fallback')?.remove();
            thumb.classList.remove('is-broken');
          }
          return;
        }
        this.#openLightbox(src, thumb.getAttribute('aria-label') || '图片');
      });
    });
  }

  /**
   * 触屏没有 hover，引用按钮常年看不见；长按气泡弹出「复制 / 引用」。
   * 桌面仍可用悬停出现的引用按钮。
   */
  #bindMessageGestures(node: HTMLElement): void {
    node.querySelectorAll<HTMLElement>('.rd-msg[data-message]').forEach((row) => {
      const clearTimer = () => {
        if (this.#longPressTimer) {
          clearTimeout(this.#longPressTimer);
          this.#longPressTimer = undefined;
        }
      };
      row.addEventListener('pointerdown', (event) => {
        if (event.pointerType === 'mouse' && event.button !== 0) {
          return;
        }
        // 点引用按钮 / 链接触发时不要抢长按菜单。
        const target = event.target as HTMLElement | null;
        if (target?.closest('a, button, audio, video, .rd-image')) {
          return;
        }
        clearTimer();
        const id = row.dataset.message;
        if (!id) {
          return;
        }
        this.#longPressTimer = setTimeout(() => {
          this.#showMsgMenu(row, id);
        }, 480);
      });
      row.addEventListener('pointerup', clearTimer);
      row.addEventListener('pointercancel', clearTimer);
      row.addEventListener('pointerleave', clearTimer);
      row.addEventListener('contextmenu', (event) => {
        // 桌面右键也走同一菜单，避免只剩原生「复制图片」。
        const id = row.dataset.message;
        if (!id) {
          return;
        }
        event.preventDefault();
        this.#showMsgMenu(row, id, event.clientX, event.clientY);
      });
    });
  }

  #showMsgMenu(row: HTMLElement, messageId: string, clientX?: number, clientY?: number): void {
    const menu = this.#msgMenu;
    const panel = this.#root.querySelector('.rd-panel') as HTMLElement | null;
    if (!menu || !panel) {
      return;
    }
    this.#msgMenuTargetId = messageId;
    menu.hidden = false;
    const panelRect = panel.getBoundingClientRect();
    const rowRect = row.getBoundingClientRect();
    const x = (clientX ?? rowRect.left + rowRect.width / 2) - panelRect.left;
    const y = (clientY ?? rowRect.top) - panelRect.top - 8;
    menu.style.left = `${Math.max(8, Math.min(x - 40, panelRect.width - 120))}px`;
    menu.style.top = `${Math.max(8, y - 40)}px`;
    row.classList.add('is-actions-open');
    panel.querySelectorAll('.rd-msg.is-actions-open').forEach((item) => {
      if (item !== row) {
        item.classList.remove('is-actions-open');
      }
    });
  }

  #hideMsgMenu(): void {
    if (this.#msgMenu) {
      this.#msgMenu.hidden = true;
    }
    this.#msgMenuTargetId = undefined;
    this.#root.querySelectorAll('.rd-msg.is-actions-open').forEach((item) => {
      item.classList.remove('is-actions-open');
    });
  }

  async #copyMessage(messageId: string): Promise<void> {
    const row = this.#messagesNode?.querySelector<HTMLElement>(`.rd-msg[data-message="${CSS.escape(messageId)}"]`);
    const text = row?.dataset.copy?.trim();
    if (!text) {
      return;
    }
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // 部分 WebView 禁 clipboard，降级选中文本由用户手动复制。
      const range = document.createRange();
      const bubble = row?.querySelector('.rd-bubble');
      if (bubble) {
        range.selectNodeContents(bubble);
        const selection = window.getSelection();
        selection?.removeAllRanges();
        selection?.addRange(range);
      }
    }
  }

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
      return `<button type="button" class="rd-image" data-lightbox="${escapeAttr(url)}" aria-label="${escapeAttr(attachment.fileName || '查看图片')}" title="点击查看大图">
        <img data-src="${escapeAttr(url)}" alt="${escapeAttr(attachment.fileName)}" loading="lazy">
      </button>`;
    }
    if (attachment.contentType.startsWith('video/')) {
      return `<video class="rd-video" controls preload="metadata" src="${escapeAttr(url)}"></video>`;
    }
    if (attachment.contentType.startsWith('audio/')) {
      return `<audio class="rd-audio" controls preload="metadata" src="${escapeAttr(url)}"></audio>`;
    }
    const downloadUrl = url.startsWith('blob:') ? url : `${url}${url.includes('?') ? '&' : '?'}download=1`;
    return `<a class="rd-file" href="${escapeAttr(downloadUrl)}" download="${escapeAttr(attachment.fileName)}" rel="noopener noreferrer">
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
    const body = quote.deletedAt
      ? '该消息已被撤回'
      : quote.messageType === 'TEXT'
        ? quote.content
        : quote.messageType === 'IMAGE'
          ? '[图片]'
          : quote.messageType === 'AUDIO'
            ? '[语音]'
            : '[文件]';
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
    (panel.querySelector('.rd-avatar') as HTMLElement).hidden = this.#searchOpen;
  }

  #renderResults(snapshot: Snapshot): void {
    const node = this.#resultsNode;
    if (!node) {
      return;
    }
    const { search } = snapshot;
    if (this.#searchOpen && !search.query) {
      node.hidden = false;
      node.innerHTML = '<div class="rd-results-head">查找聊天记录</div><div class="rd-results-head">输入关键词搜索当前会话，按回车立即查找。</div>';
      return;
    }
    if (!this.#searchOpen) {
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
        node.hidden = true;
        this.#handlers.onClearSearch();
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
    if (this.#recording || this.#requestingMicrophone) {
      return;
    }
    this.#requestingMicrophone = true;
    const mic = this.#root.querySelector('.rd-mic') as HTMLButtonElement | null;
    if (mic) { mic.disabled = true; mic.setAttribute('aria-label', '等待麦克风权限'); }
    let stream: MediaStream;
    try {
      stream = await requestMicrophone(() => navigator.mediaDevices.getUserMedia({ audio: true }));
    } catch (error) {
      this.#flashRecordingError(error instanceof Error && error.message.includes('授权未完成') ? error.message : '无法访问麦克风，请检查浏览器权限');
      return;
    } finally {
      this.#requestingMicrophone = false;
      if (mic) { mic.disabled = false; mic.setAttribute('aria-label', '录制语音'); }
    }
    const mimeType = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4'].find((type) =>
      MediaRecorder.isTypeSupported(type),
    );
    const recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined);
    this.#recorder = recorder;
    this.#recordChunks = collectRecordingChunks(recorder);
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
    input.style.overflowY = 'hidden';
    // border-box 的 scrollHeight 不包含边框，少算边框会让单行内容也溢出。
    const style = getComputedStyle(input);
    const border = (parseFloat(style.borderTopWidth) || 0)
      + (parseFloat(style.borderBottomWidth) || 0);
    const height = input.scrollHeight + border;
    input.style.height = Math.min(height, 120) + 'px';
    input.style.overflowY = height > 120 ? 'auto' : 'hidden';
  }

  #sanitizeCss(css: string): string {
    // The widget lives in its own shadow root, so host CSS cannot leak out. We
    // still strip tags that could prematurely close the <style> element.
    return css.replace(/<\/(style|script)/gi, '').replace(/<script/gi, '');
  }

  /** Returns a brand image when one is configured, otherwise the fallback icon. */
  #brandImg(fallback: string, preferLogo = false): string {
    const src = preferLogo
      ? this.#options.logoUrl || this.#options.avatarUrl
      : this.#options.avatarUrl || this.#options.logoUrl;
    if (!src) {
      return fallback;
    }
    return `<img class="rd-brand-img" src="${escapeAttr(src)}" alt="">`;
  }

  #styles(): string {
    const light = this.#options.theme !== 'dark';
    const accent = this.#options.primaryColor;
    const radius = this.#options.bubbleRadius ?? 12;
    const fontStack = this.#options.fontFamily ||
      'system-ui, -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif';
    const side = this.#options.position === 'left' ? 'left' : 'right';
    return `
:host { all: initial; }
:host { --rd-accent: ${accent}; --rd-radius: ${radius}px; --rd-radius-sm: ${Math.max(0, radius - 8)}px; --rd-font: ${fontStack}; }
* { box-sizing: border-box; }
/* 隐藏属性必须压过组件布局，避免文件输入框或导航按钮泄漏到界面。 */
[hidden] { display: none !important; }
.rd-launcher-slot, .rd-panel-slot { position: fixed; z-index: ${this.#options.zIndex}; ${side}: 20px; }
.rd-launcher-slot { bottom: 20px; }
.rd-panel-slot { bottom: 20px; }
.rd-launcher {
  display: inline-flex; align-items: center; gap: 8px; border: 1px solid ${accent}; cursor: pointer;
  border-radius: var(--rd-radius, 12px); padding: 10px 14px; font: 600 14px/1.2 var(--rd-font);
  color: #fff; background: ${accent};
}
.rd-launcher:hover { filter: brightness(1.05); }
.rd-launcher:focus-visible { outline: 2px solid ${accent}; outline-offset: 2px; }
.rd-launcher-icon svg { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 1.8; display: block; }
.rd-launcher-badge {
  position: absolute; top: -6px; ${side === 'right' ? 'right: -4px' : 'left: -4px'};
  min-width: 20px; height: 20px; padding: 0 6px; border-radius: 999px; background: #ff4d4f; color: #fff;
  font: 600 12px/20px system-ui, sans-serif; text-align: center;
}
.rd-launcher.is-open .rd-launcher-label { display: none; }
.rd-panel {
  position: fixed; bottom: 20px; ${side}: 20px; width: 400px; max-width: calc(100vw - 32px);
  height: min(640px, calc(100vh - 40px)); display: flex; flex-direction: column; overflow: hidden;
  border-radius: 12px; background: ${light ? '#ffffff' : '#171b24'}; color: ${light ? '#1f2329' : '#eef2f1'};
  border: 1px solid ${light ? '#e5e6eb' : '#2a3431'}; box-shadow: 0 8px 40px rgba(31,35,41,.12);
  font: 14px/1.55 var(--rd-font);
}
.rd-panel[hidden] { display: none; }
${this.#options.embedded ? `
.rd-panel-slot, .rd-panel { top: 0; right: 0; bottom: 0; left: 0; width: 100%; max-width: none; height: 100%; max-height: none; border: 0; border-radius: 0; box-shadow: none; }
@media (max-width: 480px) { .rd-panel { height: 100dvh; } }
` : ''}
.rd-header {
  display: flex; align-items: center; justify-content: space-between; gap: 12px;
  padding: 14px 18px; background: ${light ? '#ffffff' : '#1e1f24'}; color: ${light ? '#111827' : '#ffffff'};
  border-bottom: 1px solid ${light ? '#f3f4f6' : '#2b2f37'};
}
.rd-header-main { display: flex; align-items: center; gap: 12px; min-width: 0; }
.rd-heading { display: flex; flex-direction: column; min-width: 0; gap: 2px; }
.rd-service-subtitle { display: none; }
.rd-heading strong { font-size: 16px; font-weight: 600; letter-spacing: -0.01em; }
.rd-subtitle { font-size: 13px; color: ${light ? '#6b7280' : '#9ca3af'}; display: flex; align-items: center; gap: 6px; }
.rd-subtitle.is-online::before { content: ''; width: 8px; height: 8px; border-radius: 50%; background: #10b981; }
.rd-header-actions { display: flex; gap: 8px; }
.rd-avatar {
  display: inline-flex; align-items: center; justify-content: center; width: 36px; height: 36px; flex: none;
  border-radius: 6px; background: ${accent}; color: #ffffff;
}
.rd-avatar svg { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 2; }
.rd-avatar.lg { width: 52px; height: 52px; background: ${accent}1a; color: ${accent}; }
.rd-avatar.lg svg { width: 26px; height: 26px; }
.rd-avatar.sm { width: 28px; height: 28px; background: ${accent}1a; color: ${accent}; align-self: flex-end; }
.rd-avatar.sm svg { width: 15px; height: 15px; }
.rd-brand-img { width: 100%; height: 100%; object-fit: cover; border-radius: inherit; display: block; }
.rd-launcher-logo { width: 24px; height: 24px; border-radius: 6px; object-fit: cover; display: block; }
.rd-icon {
  display: inline-flex; align-items: center; justify-content: center; width: 36px; height: 36px; padding: 0;
  border: 0; border-radius: 10px; background: transparent; color: inherit; cursor: pointer; transition: background-color 0.12s, color 0.12s, border-color 0.12s;
}
.rd-icon svg { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; }
.rd-icon:hover { background: ${light ? '#f3f4f6' : '#374151'}; color: ${accent}; }
.rd-panel .rd-attach:hover, .rd-panel .rd-mic:hover { background: ${light ? '#f3f4f6' : '#374151'}; color: ${accent}; }
.rd-searchbar { display: flex; align-items: center; gap: 8px; padding: 12px 16px; border-bottom: 1px solid ${light ? '#f3f4f6' : '#2b2f37'}; }
.rd-searchbar[hidden] { display: none; }
.rd-search-input {
  flex: 1; border: 1px solid ${light ? '#e5e7eb' : '#374151'}; border-radius: 12px; padding: 8px 14px;
  font: inherit; background: ${light ? '#f9fafb' : '#1f2937'}; color: inherit; outline: none; transition: background-color 0.12s, color 0.12s, border-color 0.12s;
}
.rd-search-input:focus { border-color: ${accent}; background: ${light ? '#ffffff' : '#111827'}; }
.rd-body { position: relative; flex: 1; min-height: 0; display: flex; background: ${light ? '#f9fafb' : '#111827'}; }
.rd-thread { position: relative; flex: 1; display: flex; flex-direction: column; min-height: 0; }
.rd-messages { background: ${light ? '#f7f8fa' : '#171b24'}; flex: 1; overflow-y: auto; padding: 20px 18px 12px; display: flex; flex-direction: column; gap: 16px; scrollbar-width: thin; }
.rd-messages::-webkit-scrollbar { width: 6px; }
.rd-messages::-webkit-scrollbar-thumb { background: ${light ? '#d1d5db' : '#4b5563'}; border-radius: 3px; }
.rd-channel {padding:10px 16px;border-top:1px solid #edf0f5;background:${light ? '#fff' : '#1f2937'};max-height:104px;overflow:auto;flex-shrink:0}.rd-channel[hidden]{display:none}.rd-channel-row{display:flex;gap:8px;flex-wrap:wrap}.rd-channel-chip{font:inherit;font-size:12px;color:#3370ff;background:#f0f5ff;border:0;border-radius:6px;padding:7px 10px;text-decoration:none;cursor:pointer}.rd-welcome-suggestions{margin:12px 0 20px 38px}.rd-guide-title{color:#6b7280;font-size:12px;margin-bottom:8px}.rd-channel-card{display:flex;gap:12px;border:1px solid #edf0f5;border-radius:8px;padding:12px;margin:8px 0}.rd-channel-card img{width:56px;height:56px;object-fit:cover;border-radius:6px}.rd-channel-card p{font-size:12px;color:#6b7280;margin:5px 0}.rd-empty { display: flex; align-items: flex-start; gap: 10px; color: inherit; padding: 12px 0; }
.rd-empty p { margin: 0; max-width: 280px; line-height: 1.8; padding: 12px 14px; border-radius: 3px 12px 12px; background: ${light ? '#ffffff' : '#1f2937'}; border: 1px solid ${light ? '#eef0f1' : '#374151'}; }
.rd-empty small { display: block; max-width: 280px; margin-top: 12px; font-size: 11px; line-height: 1.7; color: ${light ? '#858d97' : '#a8aebb'}; }
.rd-empty .rd-avatar { align-self: flex-start; }
.rd-more { align-self: center; border: 1px solid ${light ? '#e5e6eb' : '#2a3431'}; background: ${light ? '#ffffff' : '#1f2329'}; color: ${accent}; font: 500 13px system-ui; cursor: pointer; padding: 5px 12px; border-radius: 6px; }
.rd-more:hover { background: ${accent}0a; }
.rd-day { align-self: center; font-size: 12px; font-weight: 500; color: ${light ? '#6b7280' : '#9ca3af'}; margin: 8px 0; }
.rd-thread-loading { align-self: center; margin: 28px 0; font-size: 12px; color: ${light ? '#8c93a3' : '#8b91a0'}; }
.rd-unread { display: flex; align-items: center; gap: 12px; font-size: 12px; font-weight: 500; color: #ef4444; margin: 8px 0; }
.rd-unread::before, .rd-unread::after { content: ''; flex: 1; height: 1px; background: #ef444433; }
.rd-row { display: flex; gap: 10px; align-items: flex-end; }
.rd-row.is-mine { justify-content: flex-end; }
.rd-bubble-group { display: flex; flex-direction: column; gap: 6px; max-width: 80%; }
.rd-row.is-mine .rd-bubble-group { align-items: flex-end; }
.rd-sender { font-size: 13px; font-weight: 500; color: ${light ? '#6b7280' : '#9ca3af'}; margin-bottom: 2px; }
  .rd-ai-badge { display: inline-flex; align-items: center; justify-content: center; margin-left: 6px; padding: 0 6px; height: 16px; font-size: 10px; font-weight: 700; line-height: 1; color: #fff; background: ${accent}; border-radius: 4px; vertical-align: middle; letter-spacing: .5px; }
  .rd-ai-note { font-size: 11px; color: ${light ? '#9ca3af' : '#8b91a0'}; display: inline-flex; align-items: center; gap: 6px; margin-top: 2px; }
  .rd-handoff-btn { border: 1px solid ${accent}; color: ${accent}; background: transparent; border-radius: 999px; padding: 1px 10px; font-size: 11px; line-height: 1.6; cursor: pointer; transition: background .15s, color .15s; }
  .rd-handoff-btn:hover { background: ${accent}; color: #fff; }
.rd-bubble-wrap { position: relative; display: flex; align-items: center; gap: 6px; max-width: 100%; }
.rd-row.is-mine .rd-bubble-wrap { flex-direction: row-reverse; }
  .rd-bubble {
  padding: 8px 12px; border-radius: var(--rd-radius, 12px); background: ${light ? '#ffffff' : '#1f2937'};
  color: ${light ? '#111827' : '#f9fafb'}; word-break: break-word; white-space: normal;
  min-width: 0; border: 1px solid ${light ? '#e5e6eb' : '#374151'};
  user-select: text; -webkit-user-select: text;
}
.rd-row.is-mine .rd-bubble { background: ${light ? accent + "14" : accent + "38"}; color: ${light ? "#1f2329" : "#eef2f6"}; border-color: ${light ? accent + "20" : accent + "44"}; }
.rd-bubble a { color: inherit; text-decoration: underline; }
.rd-bubble img, .rd-bubble video { display: block; max-width: 100%; border-radius: 10px; }
.rd-bubble audio { width: 100%; }
.rd-bubble.is-recalled { font-size: 12px; opacity: .7; font-style: normal; }
.rd-caption { margin-top: 8px; line-height: 1.55; }
.rd-quote-btn {
  opacity: 0; border: 1px solid ${light ? '#e5e6eb' : '#2a3431'}; background: ${light ? '#ffffff' : '#1f2937'}; color: ${light ? '#6b7280' : '#9ca3af'}; cursor: pointer;
  width: 28px; height: 28px; border-radius: 6px; flex: none;
  display: flex; align-items: center; justify-content: center;
}
.rd-quote-btn svg { width: 14px; height: 14px; fill: none; stroke: currentColor; stroke-width: 2; }
.rd-row:hover .rd-quote-btn, .rd-row.is-actions-open .rd-quote-btn { opacity: 1; transform: scale(1); }
.rd-row .rd-quote-btn { transform: scale(0.8); }
.rd-quote-btn:hover { color: ${accent}; }
/* 触屏无 hover：引用按钮常显半透明，避免「功能像没做」。 */
@media (hover: none) {
  .rd-quote-btn { opacity: .55; transform: scale(1); }
}
.rd-quote { display: flex; flex-direction: column; gap: 4px; padding: 6px 10px; margin-bottom: 6px; border-left: 3px solid ${light ? '#d1d5db' : '#4b5563'}; border-radius: 6px; background: ${light ? 'rgba(0,0,0,0.03)' : 'rgba(255,255,255,0.05)'}; font-size: 12px; }
.rd-quote strong { font-weight: 600; opacity: .85; }
.rd-quote em { font-style: normal; opacity: .75; overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.rd-forwarded { display: block; font-size: 11px; opacity: .7; margin-bottom: 4px; }
.rd-image {
  display: block; margin: -4px; padding: 0; border: 0; background: transparent; cursor: zoom-in;
  max-width: 100%;
}
.rd-image img { max-width: min(100%, 240px); max-height: 260px; min-width: 96px; min-height: 72px; object-fit: cover; border-radius: 10px; display: block; background: ${light ? '#eef0f3' : '#2a3140'}; }
.rd-image.is-broken {
  margin: 0; min-width: 148px; min-height: 88px; border-radius: 10px;
  background: ${light ? '#f3f4f6' : '#2a3140'}; cursor: pointer;
  display: inline-flex; align-items: center; justify-content: center;
}
.rd-image-fallback { font-size: 12px; color: ${light ? '#6b7280' : '#9ca3af'}; padding: 12px; }
.rd-caption + .rd-image, .rd-image + .rd-caption { margin-top: 0; }
.rd-bubble:has(> .rd-image:first-child) { padding-top: 8px; }
.rd-msg-menu {
  position: absolute; z-index: 35; display: flex; gap: 0; border-radius: 10px; overflow: hidden;
  background: ${light ? '#ffffff' : '#1f2937'}; border: 1px solid ${light ? '#e5e6eb' : '#374151'};
  box-shadow: 0 8px 24px rgba(15,18,25,.16);
}
.rd-msg-menu[hidden] { display: none !important; }
.rd-msg-menu button {
  border: 0; background: transparent; color: inherit; font: 500 13px system-ui, sans-serif;
  padding: 10px 14px; cursor: pointer;
}
.rd-msg-menu button + button { border-left: 1px solid ${light ? '#eef0f3' : '#374151'}; }
.rd-msg-menu button:hover { background: ${light ? '#f3f4f6' : '#374151'}; color: ${accent}; }
.rd-lightbox {
  position: absolute; inset: 0; z-index: 40; display: flex; align-items: center; justify-content: center;
  background: rgba(15, 18, 25, 0.88); padding: 56px 16px 24px;
}
.rd-lightbox[hidden] { display: none !important; }
.rd-lightbox-toolbar {
  position: absolute; top: 12px; right: 12px; display: flex; align-items: center; gap: 8px;
}
.rd-lightbox-download {
  height: 36px; padding: 0 12px; border-radius: 18px; text-decoration: none;
  background: rgba(255,255,255,.14); color: #fff; display: inline-flex; align-items: center;
  font: 500 13px system-ui, sans-serif;
}
.rd-lightbox-download:hover { background: rgba(255,255,255,.24); }
.rd-lightbox-img { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 8px; box-shadow: 0 12px 40px rgba(0,0,0,.35); }
.rd-lightbox-close {
  width: 36px; height: 36px; border: 0; border-radius: 18px;
  background: rgba(255,255,255,.14); color: #fff; display: inline-flex; align-items: center; justify-content: center; cursor: pointer;
}
.rd-lightbox-close svg { width: 18px; height: 18px; }
.rd-lightbox-close:hover { background: rgba(255,255,255,.24); }
:host(.rd-lightbox-open) .rd-messages { overflow: hidden; }
.rd-file, .rd-bubble .rd-file {
  display: flex; align-items: center; gap: 12px; padding: 12px 14px; border-radius: 12px;
  background: ${light ? '#f3f4f6' : '#374151'}; color: inherit; text-decoration: none; border: 1px solid ${light ? '#e5e7eb' : '#4b5563'};
}
.rd-bubble .rd-file { color: ${light ? '#1f2329' : '#eef2f1'}; }
.rd-file-name { min-width: 0; flex: 1; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 190px; }
.rd-file-size { flex: none; white-space: nowrap; opacity: .7; font-size: 12px; }
.rd-voice { display: flex; flex-direction: column; gap: 2px; min-width: 190px; }
.rd-voice small { font-size: 11px; opacity: .75; }
.rd-reactions { display: flex; flex-wrap: wrap; gap: 4px; }
.rd-reaction {
  display: inline-flex; align-items: center; gap: 4px; padding: 2px 6px; border-radius: 4px;
  background: ${light ? '#f3f4f6' : '#374151'}; border: 1px solid ${light ? '#e5e7eb' : '#4b5563'}; font-size: 12px;
}
.rd-reaction b { font-weight: 600; font-size: 11px; opacity: .8; }
.rd-time { font-size: 11px; color: ${light ? '#939aab' : '#8b91a0'}; display: flex; align-items: center; gap: 6px; }
.rd-edited { opacity: .8; }
.rd-pinned-mark svg { width: 12px; height: 12px; fill: none; stroke: currentColor; stroke-width: 1.8; display: block; }
.rd-state { font-size: 11px; }
.rd-state.is-failed { display: inline-flex; align-items: center; gap: 3px; border: 0; background: transparent; color: #ff4d4f; cursor: pointer; padding: 0; font: inherit; font-size: 11px; }
.rd-state.is-failed svg { width: 12px; height: 12px; fill: none; stroke: currentColor; stroke-width: 2; }
.rd-receipt { display: inline-flex; align-items: center; gap: 3px; font-size: 11px; color: ${light ? '#939aab' : '#8b91a0'}; }
.rd-receipt svg { width: 13px; height: 13px; display: block; }
.rd-receipt.is-read { color: ${accent}; }
.rd-sys { align-self: center; font-size: 12px; color: ${light ? '#8c93a3' : '#8b91a0'}; background: ${light ? '#f5f6f8' : '#23262d'}; padding: 3px 8px; border-radius: 4px; }
.rd-row.is-flash .rd-bubble { outline: 2px solid ${accent}88; }
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
.rd-composer { display: flex; flex-direction: column; border-top: 1px solid ${light ? '#f3f4f6' : '#2b2f37'}; background: ${light ? '#ffffff' : '#1e1f24'}; }
.rd-composer[hidden] { display: none; }
.rd-composer-row { display: flex; align-items: flex-end; gap: 8px; padding: 12px 16px; }
.rd-composer-row { align-items: center; gap: 6px; padding: 10px 12px; background: ${light ? '#f5f6f7' : '#1e1f24'}; }
.rd-composer-row .rd-icon { flex: none; width: 34px; height: 40px; padding: 5px; background: transparent; color: ${light ? '#39433f' : '#d1d5db'}; }
.rd-composer-row .rd-icon svg { width: 25px; height: 25px; }
.rd-tools { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 20px 8px; padding: 22px 16px 16px; background: ${light ? '#f5f6f7' : '#1e1f24'}; border-top: 1px solid ${light ? '#e8ebed' : '#374151'}; }
.rd-tool { display: flex; flex-direction: column; align-items: center; gap: 9px; border: 0; background: transparent; color: inherit; cursor: pointer; font: inherit; font-size: 12px; }
.rd-tool span { display: grid; place-items: center; width: 54px; height: 54px; background: ${light ? '#ffffff' : '#2b3038'}; border-radius: 14px; border: 1px solid ${light ? '#eceeef' : '#374151'}; }
.rd-tool svg { width: 26px; height: 26px; }
.rd-tool:hover span { border-color: ${accent}; }
.rd-tools-hint { grid-column: 1 / -1; margin: 0; font-size: 11px; text-align: center; color: ${light ? '#858d97' : '#a8aebb'}; line-height: 1.6; }
.rd-upload-status { padding: 4px 16px 10px; font-size: 12px; color: ${accent}; }
.rd-emojis { flex-shrink: 0; height: 202px; box-sizing: border-box; contain: layout paint; padding: 8px 12px; background: ${light ? '#f5f6f7' : '#1e1f24'}; }
.rd-emoji-tabs { display:flex; gap:8px; margin-bottom:8px; }
.rd-emoji-tabs button { flex:1; border:0; padding:7px 0; border-radius:6px; background:transparent; color:inherit; cursor:pointer; font:inherit; font-size:12px; }
.rd-emoji-tabs button[aria-selected="true"] { background:#e5edff; color:#3370ff; }
.rd-emoji-grid { display:grid; grid-template-columns:repeat(8,minmax(0,1fr)); gap:6px; }
.rd-icon, .rd-emoji, .rd-emoji-tabs button, .rd-tool { touch-action:manipulation; -webkit-tap-highlight-color:transparent; }
.rd-composer { flex-shrink:0; }
.rd-tools { flex-shrink:0; contain:layout paint; }
.rd-emoji { border: 0; border-radius: 8px; background: transparent; padding: 6px 0; font-size: 24px; cursor: pointer; }
.rd-emoji:hover { background: ${light ? '#e7ebed' : '#374151'}; }
.rd-composer-row .rd-input { min-width: 0; border: 0; border-radius: 8px; background: ${light ? '#ffffff' : '#111827'}; padding: 10px; font-size: 15px; }
.rd-composer-row .rd-send { width: 52px; font: 500 13px system-ui; border-radius: 8px; }
.rd-composer { padding-bottom: env(safe-area-inset-bottom, 0px); }
.rd-reply { display: flex; align-items: center; gap: 8px; padding: 8px 16px 0; font-size: 12px; color: ${light ? '#6b7280' : '#9ca3af'}; }
.rd-reply[hidden] { display: none; }
.rd-reply-icon svg { width: 14px; height: 14px; fill: none; stroke: currentColor; stroke-width: 2; display: block; color: ${accent}; }
.rd-reply-body { display: flex; flex-direction: column; min-width: 0; flex: 1; }
.rd-reply-body strong { font-weight: 600; color: ${light ? '#374151' : '#d1d5db'}; }
.rd-reply-body small { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; opacity: .8; }
.rd-reply .rd-icon { width: 24px; height: 24px; color: inherit; }
.rd-reply .rd-icon svg { width: 14px; height: 14px; }
.rd-input {
  overflow-x: hidden; overflow-y: hidden;
  /* 保留长草稿滚动，隐藏右侧滚动条，避免被误认为第二个输入光标。 */
  scrollbar-width: none;
  flex: 1; resize: none; border: 1px solid ${light ? '#e5e7eb' : '#374151'}; border-radius: 14px; padding: 10px 14px;
  font: inherit; line-height: 1.5; max-height: 120px; background: ${light ? '#f9fafb' : '#111827'}; color: inherit; outline: none; transition: background-color 0.12s, color 0.12s, border-color 0.12s;
}
.rd-input::-webkit-scrollbar { width: 0; height: 0; display: none; }
.rd-input::-webkit-scrollbar-button { width: 0; height: 0; display: none; }
.rd-input:focus { border-color: ${accent}; background: ${light ? '#ffffff' : '#111827'}; }
.rd-send {
  display: inline-flex; align-items: center; justify-content: center; width: 40px; height: 40px; flex: none;
  border: 0; border-radius: 6px; background: ${accent}; color: #fff; cursor: pointer;
}
.rd-send:hover:not(:disabled) { filter: brightness(1.05); }
.rd-send svg { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 2; }
.rd-send:disabled { opacity: .4; cursor: not-allowed; }
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
}
${light ? `
.rd-panel { color: #1F2329; border-color: #E5E8EF; }
.rd-launcher { position: relative; ${this.#options.launcher === 'bubble' ? `width: 64px; height: 64px; padding: 0; border-radius: 50%; justify-content: center;` : ''} box-shadow: 0 4px 16px ${accent}33; }
${this.#options.launcher === 'bubble' ? '.rd-launcher-label { display: none; }' : ''}
.rd-launcher-icon svg { width: 30px; height: 30px; }
.rd-launcher-badge { background: #F53F3F; top: -2px; right: -2px; border: 2px solid #fff; height: 24px; min-width: 24px; line-height: 20px; }
.rd-panel:not(.is-embedded) { bottom: 96px; height: min(560px, calc(100dvh - 116px)); }
.rd-header { min-height: 64px; padding: 10px 18px; border-color: #E5E8EF; }
.rd-header-main > .rd-avatar { display: none; }
.rd-heading strong { font-size: 17px; }
.rd-subtitle { color: #646A73; font-size: 12px; }
.rd-subtitle.is-online::before { background: #00B42A; width: 7px; height: 7px; }
.rd-service-subtitle { display: none; color: #646A73; font-size: 12px; }
.rd-header-actions { gap: 2px; }
.rd-body, .rd-messages { background: #F5F7FA; }
.rd-messages { gap: 16px; padding: 16px 14px 12px; }
.rd-empty { padding: 12px; border: 1px solid #E5E8EF; border-radius: 12px; background: #fff; box-shadow: 0 2px 6px rgba(31,35,41,.04); gap: 12px; }
.rd-empty .rd-avatar.lg { width: 44px; height: 44px; border-radius: 12px; background: ${accent}; color: #fff; }
.rd-welcome-body { flex: 1; min-width: 0; }
.rd-welcome-body > strong { font-size: 14px; font-weight: 600; }
.rd-empty p { padding: 0; border: 0; background: transparent; border-radius: 0; max-width: none; color: #646A73; font-size: 13px; line-height: 1.6; margin-top: 3px; }
.rd-welcome-suggestions { margin: 8px 0 0; }
.rd-thread-loading { align-self: center; margin: 28px 0; font-size: 12px; color: #8F959E; }
.rd-guide-title { color: #8F959E; margin-bottom: 6px; }
.rd-channel { border-color: #E5E8EF; padding: 8px 14px; }
.rd-channel-row { gap: 6px; }
.rd-channel-chip { color: ${accent}; background: #fff; border: 1px solid ${accent}40; border-radius: 999px; padding: 4px 10px; font-size: 12px; }
.rd-channel-chip:hover { background: ${accent}0d; }
.rd-channel-card { border-color: #E5E8EF; border-radius: 10px; }
.rd-row { align-items: flex-start; gap: 8px; }
.rd-avatar.sm { width: 32px; height: 32px; border-radius: 50%; align-self: flex-start; background: ${accent}15; color: ${accent}; }
.rd-avatar.sm svg { width: 20px; height: 20px; }
.rd-bubble-group { max-width: calc(100% - 44px); gap: 4px; }
.rd-row.is-mine .rd-bubble-group { max-width: 85%; }
.rd-sender { font-size: 12px; color: #646A73; }
  .rd-ai-badge { display: inline-flex; align-items: center; justify-content: center; margin-left: 6px; padding: 0 6px; height: 15px; font-size: 10px; font-weight: 700; line-height: 1; color: #fff; background: ${accent}; border-radius: 4px; vertical-align: middle; letter-spacing: .5px; }
  .rd-ai-note { font-size: 11px; color: #8F959E; display: inline-flex; align-items: center; gap: 6px; margin-top: 2px; }
  .rd-handoff-btn { border: 1px solid ${accent}; color: ${accent}; background: transparent; border-radius: 999px; padding: 1px 10px; font-size: 11px; line-height: 1.6; cursor: pointer; }
  .rd-handoff-btn:hover { background: ${accent}; color: #fff; }
.rd-bubble { padding: 9px 12px; border-color: #E5E8EF; border-radius: 4px 12px 12px; color: #1F2329; box-shadow: 0 1px 3px rgba(31,35,41,.02); }
.rd-row.is-mine .rd-bubble { background: ${accent}; color: #fff; border-color: ${accent}; border-radius: var(--rd-radius, 12px) var(--rd-radius-sm, 4px) var(--rd-radius, 12px) var(--rd-radius, 12px); }
.rd-bubble:has(.rd-image) { padding: 6px; border-radius: 12px; }
.rd-image { margin: 0; }
.rd-image img { border-radius: 8px; min-width: 120px; min-height: 90px; }
.rd-time { color: #8F959E; font-size: 11px; }
.rd-day, .rd-time-separator { align-self: center; color: #8F959E; font-size: 12px; margin: 2px 0; }
.rd-composer { border-color: #E5E8EF; }
.rd-composer-row { padding: 10px 12px; gap: 6px; background: #fff; }
.rd-composer-row .rd-icon { width: 30px; height: 36px; color: #646A73; }
.rd-composer-row .rd-icon svg { width: 24px; height: 24px; }
.rd-composer-row .rd-input { border: 1px solid #E5E8EF; border-radius: 20px; padding: 8px 12px; font-size: 14px; line-height: 20px; background: #fff; }
.rd-input::placeholder { color: #8F959E; }
.rd-composer-row .rd-input:focus { border-color: ${accent}; }
.rd-composer-row .rd-send { width: 60px; height: 36px; border-radius: 18px; font: 500 14px "Microsoft YaHei", sans-serif; }
.is-embedded .rd-header { position: relative; min-height: 56px; padding: 6px 12px; }
.is-embedded .rd-header-main { margin: 0 auto; max-width: calc(100% - 88px); text-align: center; }
.is-embedded .rd-heading { align-items: center; }
.is-embedded .rd-heading strong { font-size: 18px; }
.is-embedded .rd-service-subtitle { display: block; }
.is-embedded .rd-subtitle { font-size: 11px; }
.is-embedded .rd-header-actions { position: absolute; right: 8px; top: 10px; }
.is-embedded .rd-page-back { position: fixed; left: 8px; top: 10px; }
.is-embedded .rd-back { display: none; }
.is-embedded .rd-body, .is-embedded .rd-messages { background: #F2F3F5; }
@media (max-width: 480px) {
  .rd-panel:not(.is-embedded) { bottom: 0; height: 100dvh; }
  .rd-panel:not(.is-embedded) .rd-header { min-height: 56px; }
  .rd-messages { padding: 12px; gap: 14px; }
  .rd-composer-row { padding: 8px 10px; }
}
` : ''}
/* 与坐席工作台统一的外观；企业主色、嵌入模式和全部功能继续由配置驱动。 */
.rd-panel { border-radius: 17px; border-color: ${light ? '#e9edf3' : '#303848'}; }
.rd-panel:not(.is-embedded) { width: 360px; }
.rd-header { background: ${accent}; color: #fff; padding: 22px 20px; border-bottom: 0; }
.rd-heading strong { color: #fff; font-size: 18px; }
.rd-subtitle, .rd-service-subtitle { color: #ffffffcc; font-size: 11px; }
.rd-header-actions .rd-icon { color: #fff; background: transparent; }
.rd-header .rd-page-back { color: #fff; }
.rd-body, .rd-messages { background: ${light ? '#fafbfd' : '#171b24'}; }
.rd-messages { padding: 20px 16px; gap: 20px; }
.rd-empty { border-color: ${light ? '#e9edf3' : '#303848'}; box-shadow: none; padding: 16px; }
.rd-bubble { background: ${light ? '#ffffff' : '#2a2f38'}; padding: 12px 15px; border-color: ${light ? '#e9edf3' : '#303848'}; box-shadow: none; border-radius: 2px 10px 10px 10px; }
.rd-row.is-mine .rd-bubble { background: ${light ? accent + '12' : accent}; color: ${light ? '#202b3d' : '#fff'}; border-color: ${light ? accent + '20' : accent}; border-radius: 10px 2px 10px 10px; }
.rd-avatar.sm { border-radius: 10px; }
.rd-composer { border-color: ${light ? '#e9edf3' : '#303848'}; }
.rd-composer-row .rd-input { border-radius: 8px; border-color: ${light ? '#e9edf3' : '#303848'}; background: ${light ? '#fff' : '#222733'}; }
.rd-composer-row .rd-send { border-radius: 7px; font-size: 12px; }
.is-embedded.rd-panel { border-radius: 0; }
.rd-composer-toolbar { display:flex; align-items:center; gap:8px; padding:6px 12px 0; }
.rd-composer-toolbar .rd-icon { width:32px; height:32px; padding:6px; color:${light ? '#646A73' : '#d1d5db'}; background:transparent; border-radius:6px; }
.rd-composer-toolbar .rd-icon svg { width:20px; height:20px; }
.rd-composer-toolbar .rd-icon:hover { background:${light ? '#f0f3f8' : '#303848'}; }
.rd-composer-row { align-items:flex-end; gap:10px; padding:6px 12px 12px; min-width:0; }
.rd-composer-row .rd-input { flex:1 1 0%; width:0; min-width:0; min-height:42px; padding:10px 12px; line-height:20px; border-radius:8px; }
.rd-composer-row .rd-send { flex:0 0 60px; width:60px; height:42px; border-radius:8px; font-size:14px; }
@media (max-width: 480px) { .rd-panel:not(.is-embedded) { width: 100vw; border-radius: 0; } .rd-header { padding: 14px 16px; } }
`;
  }
}
