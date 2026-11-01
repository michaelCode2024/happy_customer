import type { ChannelItem } from "./types.js";
// Shadow-DOM renderer. Two rules keep it usable inside someone else's page:
// every style is scoped to the shadow root, and the composer is a persistent
// node that re-renders only patch the message list, so typing is never
// interrupted and the caret never jumps.

import { requestMicrophone, collectRecordingChunks } from './recording.js';
import { windowTitle, type ResolvedOptions } from './config.js';
import { shouldForkAfterGrace, type ChatStore, type Snapshot } from './store.js';
import type { ChatMessage, SearchHit } from './types.js';

type WelcomeSnapshot = Pick<Snapshot, 'messages' | 'loadingThread' | 'conversations' | 'activeId'>;

/** 欢迎页只在确实没有历史时出现；加载中不能闪默认话术。 */
export function welcomeVisible(snapshot: WelcomeSnapshot): boolean {
  if (snapshot.messages.length > 0 || snapshot.loadingThread) {
    return false;
  }
  const active = snapshot.conversations.find((item) => item.id === snapshot.activeId);
  // 会话列表已知道有消息序号，历史还在路上：继续等，不画欢迎语。
  return !(active && (active.lastSequence ?? 0) > 0);
}

/**
 * 底部渠道条（智能菜单 / 快捷方式 / 智能引流）的可见性。
 * 欢迎页已经渲染引导问题或图文卡片时不再重复铺一层 chips；否则必须显示——
 * 只配菜单、不配引导问题的入口，首屏会一个入口都没有。
 */
export function channelBarVisible(
  snapshot: WelcomeSnapshot & Pick<Snapshot, 'automation'>,
  itemCount: number,
): boolean {
  if (itemCount === 0) return false;
  if (snapshot.conversations.length > 1 && !snapshot.activeId) return false;
  const c = snapshot.automation;
  const welcomeHasActions = Boolean(c && ((c.guideQuestions?.length ?? 0) > 0 || (c.cards?.length ?? 0) > 0));
  return !(welcomeVisible(snapshot) && welcomeHasActions);
}

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
  keyboard: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="6" width="20" height="12" rx="2"></rect><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"></path></svg>',
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

/** 自动回复：首段作结论，其余作分点，避免整段灰字像系统公告。 */
function formatAutomationBody(value: string): string {
  const parts = value
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean);
  if (parts.length === 0) return '';
  const lead = parts[0] ?? '';
  if (parts.length === 1) return `<p class="rd-auto-lead">${formatText(lead)}</p>`;
  const steps = parts.slice(1);
  return `<p class="rd-auto-lead"><strong>${escapeHtml(lead)}</strong></p><ul class="rd-auto-steps">${steps
    .map((step) => `<li>${escapeHtml(step)}</li>`)
    .join('')}</ul>`;
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

/** 解析 #RGB / #RRGGBB，失败返回 null。 */
function parseHexColor(value: string): [number, number, number] | null {
  const raw = value.trim().replace(/^#/, '');
  if (!/^[0-9a-fA-F]{3}$|^[0-9a-fA-F]{6}$/.test(raw)) return null;
  const hex = raw.length === 3
    ? raw.split('').map((c) => c + c).join('')
    : raw;
  return [
    Number.parseInt(hex.slice(0, 2), 16),
    Number.parseInt(hex.slice(2, 4), 16),
    Number.parseInt(hex.slice(4, 6), 16),
  ];
}

/** 相对亮度（sRGB），用于判断浅色主色不能当白底字色。 */
function relativeLuminance(rgb: [number, number, number]): number {
  const linear = rgb.map((channel) => {
    const s = channel / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * linear[0]! + 0.7152 * linear[1]! + 0.0722 * linear[2]!;
}

/**
 * 铺在主色底上的字色：浅黄/奶油用深墨，通语蓝等深色用白。
 * 渠道 customCss 可再覆盖 --rd-accent-ink。
 */
function onAccentInk(accent: string, lightTheme: boolean): string {
  const rgb = parseHexColor(accent);
  if (!rgb) return lightTheme ? '#ffffff' : '#eef2f1';
  return relativeLuminance(rgb) > 0.55 ? '#171717' : '#ffffff';
}

/**
 * 白底/淡染芯片字色：浅主色用深墨（彩站黄），深主色仍用主色本身（通语蓝）。
 * 与 onAccentInk 分开，避免蓝主题芯片变成「白字浅底」。
 */
function chipInk(accent: string, lightTheme: boolean): string {
  const rgb = parseHexColor(accent);
  if (!rgb) return lightTheme ? '#1F2329' : '#eef2f1';
  return relativeLuminance(rgb) > 0.55 ? '#171717' : accent;
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
  #endedNode?: HTMLDivElement;
  #listNode?: HTMLDivElement;
  #replyBar?: HTMLDivElement;
  #searchBar?: HTMLDivElement;
  #searchInput?: HTMLInputElement;
  #resultsNode?: HTMLDivElement;
  #pinnedBar?: HTMLDivElement;
  #holdButton?: HTMLButtonElement;
  #voiceMask?: HTMLDivElement;
  #voiceToast?: HTMLDivElement;
  #voiceToastTimer?: ReturnType<typeof setTimeout>;
  #voiceMode = false;
  #fingerDown = false;
  #holdCancel = false;
  #holdStartY = 0;
  #holdGen = 0;
  #holdPointerId?: number;
  #holdWatch?: (event: PointerEvent) => void;
  #holdTouchWatch?: (event: TouchEvent) => void;
  #audioContext?: AudioContext;
  #monitorStream?: MediaStream;
  #levelTimer?: ReturnType<typeof setInterval>;
  #canMeter = false;
  #heardSound = false;
  #holdInterrupted = false;
  #reportHoldEnd = false;
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
  /** 全屏嵌入只绑一次，白标重建面板后仍用同一套监听。 */
  #keyboardPinBound = false;

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
    this.#abandonRecording();
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

  /** True while the microphone is capturing or the permission prompt is open. */
  get recording(): boolean {
    return this.#recording || this.#requestingMicrophone;
  }

  /**
   * iOS 键盘弹起时布局视口高度不变，系统会把聚焦的输入框滚到可视区顶部，
   * 输入栏和键盘之间就空出一大块。全屏嵌入改为跟 visualViewport，底边贴住键盘。
   */
  #bindKeyboardPin(): void {
    if (this.#keyboardPinBound || !this.#options.embedded || !window.visualViewport) {
      return;
    }
    this.#keyboardPinBound = true;
    const pin = () => this.#pinComposerToKeyboard();
    window.visualViewport.addEventListener('resize', pin);
    window.visualViewport.addEventListener('scroll', pin);
    window.addEventListener('scroll', pin);
    // 键盘动画晚于 focus，补两次才能贴住。
    window.addEventListener('focusin', () => {
      pin();
      window.setTimeout(pin, 80);
      window.setTimeout(pin, 320);
    });
    window.addEventListener('focusout', () => window.setTimeout(pin, 80));
    pin();
  }

  #pinComposerToKeyboard(): void {
    const vv = window.visualViewport;
    const panel = this.#root.querySelector('.rd-panel') as HTMLElement | null;
    if (!vv || !panel || panel.hidden) {
      return;
    }
    const top = Math.max(0, Math.round(vv.offsetTop));
    const height = Math.round(vv.height);
    if (height < 1) {
      return;
    }
    panel.style.top = '0px';
    panel.style.bottom = 'auto';
    panel.style.height = `${height}px`;
    panel.style.transform = top > 0 ? `translateY(${top}px)` : '';
    // 键盘盖住底边时不再留 Home 条，否则输入栏会悬在键盘上方一截。
    const keyboard = window.innerHeight - height - top > 80;
    panel.classList.toggle('is-keyboard', keyboard);
    if (window.scrollY !== 0) {
      window.scrollTo(0, 0);
    }
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
            <strong>${escapeHtml(this.#windowTitle())}</strong>
            <span class="rd-service-subtitle">${escapeHtml(this.#options.subtitle)}</span>
            <span class="rd-subtitle"></span>
          </div>
        </div>
        <div class="rd-header-actions">
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
          <div class="rd-voice-mask" hidden>
            <div class="rd-voice-card">
              <div class="rd-voice-waves" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i></div>
              <span class="rd-voice-cancel" hidden>${ICONS.close}</span>
              <b class="rd-voice-count" hidden>10</b>
            </div>
            <p class="rd-voice-tip">手指上滑，取消发送</p>
          </div>
        </div>
      </div>
      <div class="rd-typing" hidden><span></span><span></span><span></span><em>对方正在输入…</em></div>
      <div class="rd-ended" hidden></div>
      <form class="rd-composer">
        <div class="rd-reply" hidden>
          <span class="rd-reply-icon">${ICONS.quote}</span>
          <span class="rd-reply-body"><strong></strong><small></small></span>
          <button type="button" class="rd-icon rd-reply-close" title="取消引用">${ICONS.close}</button>
        </div>
        <div class="rd-composer-row">
          <button type="button" class="rd-icon rd-mic" title="语音" aria-label="语音" aria-pressed="false" hidden>${ICONS.mic}</button>
          <textarea class="rd-input" rows="1" placeholder="${escapeAttr(this.#options.placeholder)}" maxlength="4000"></textarea>
          <button type="button" class="rd-hold" hidden aria-live="polite" aria-label="按住说话">按住 说话</button>
          <button type="submit" class="rd-send" title="发送" aria-label="发送消息" hidden disabled>发送</button>
          <button type="button" class="rd-icon rd-more-toggle" title="图片和文件" aria-label="图片和文件" aria-expanded="false">${ICONS.plus}</button>
        </div>
        <div class="rd-tools" hidden>
          <button type="button" class="rd-tool rd-emoji-toggle"><span>${ICONS.smile}</span>表情</button>
          <button type="button" class="rd-tool" data-picker="image"><span>${ICONS.image}</span>图片</button>
          <button type="button" class="rd-tool" data-picker="camera"><span>${ICONS.camera}</span>拍照</button>
          <button type="button" class="rd-tool" data-picker="file"><span>${ICONS.clip}</span>文件</button>
          <button type="button" class="rd-tool rd-history"><span>${ICONS.search}</span>聊天记录</button>
        </div>
        <div class="rd-emojis" aria-label="选择表情" hidden><div class="rd-emoji-tabs" role="tablist" aria-label="表情分类"><button type="button" role="tab" aria-selected="true" data-emoji-category="0">笑脸</button><button type="button" role="tab" aria-selected="false" data-emoji-category="1">心情</button><button type="button" role="tab" aria-selected="false" data-emoji-category="2">手势</button><button type="button" role="tab" aria-selected="false" data-emoji-category="3">日常</button></div><div class="rd-emoji-grid" data-emoji-group="0"><button type="button" class="rd-emoji" aria-label="😀">😀</button><button type="button" class="rd-emoji" aria-label="😃">😃</button><button type="button" class="rd-emoji" aria-label="😄">😄</button><button type="button" class="rd-emoji" aria-label="😁">😁</button><button type="button" class="rd-emoji" aria-label="😆">😆</button><button type="button" class="rd-emoji" aria-label="😅">😅</button><button type="button" class="rd-emoji" aria-label="😂">😂</button><button type="button" class="rd-emoji" aria-label="🤣">🤣</button><button type="button" class="rd-emoji" aria-label="😊">😊</button><button type="button" class="rd-emoji" aria-label="🙂">🙂</button><button type="button" class="rd-emoji" aria-label="🙃">🙃</button><button type="button" class="rd-emoji" aria-label="😉">😉</button><button type="button" class="rd-emoji" aria-label="😌">😌</button><button type="button" class="rd-emoji" aria-label="😍">😍</button><button type="button" class="rd-emoji" aria-label="🥰">🥰</button><button type="button" class="rd-emoji" aria-label="😘">😘</button><button type="button" class="rd-emoji" aria-label="😋">😋</button><button type="button" class="rd-emoji" aria-label="😛">😛</button><button type="button" class="rd-emoji" aria-label="😜">😜</button><button type="button" class="rd-emoji" aria-label="🤪">🤪</button><button type="button" class="rd-emoji" aria-label="🤔">🤔</button><button type="button" class="rd-emoji" aria-label="🤭">🤭</button><button type="button" class="rd-emoji" aria-label="🤫">🤫</button><button type="button" class="rd-emoji" aria-label="🫡">🫡</button></div><div class="rd-emoji-grid" data-emoji-group="1" hidden><button type="button" class="rd-emoji" aria-label="😎">😎</button><button type="button" class="rd-emoji" aria-label="🤩">🤩</button><button type="button" class="rd-emoji" aria-label="🥳">🥳</button><button type="button" class="rd-emoji" aria-label="😏">😏</button><button type="button" class="rd-emoji" aria-label="😒">😒</button><button type="button" class="rd-emoji" aria-label="😔">😔</button><button type="button" class="rd-emoji" aria-label="😢">😢</button><button type="button" class="rd-emoji" aria-label="😭">😭</button><button type="button" class="rd-emoji" aria-label="😤">😤</button><button type="button" class="rd-emoji" aria-label="😠">😠</button><button type="button" class="rd-emoji" aria-label="😡">😡</button><button type="button" class="rd-emoji" aria-label="🤯">🤯</button><button type="button" class="rd-emoji" aria-label="😳">😳</button><button type="button" class="rd-emoji" aria-label="🥺">🥺</button><button type="button" class="rd-emoji" aria-label="😱">😱</button><button type="button" class="rd-emoji" aria-label="😨">😨</button><button type="button" class="rd-emoji" aria-label="😰">😰</button><button type="button" class="rd-emoji" aria-label="😥">😥</button><button type="button" class="rd-emoji" aria-label="😓">😓</button><button type="button" class="rd-emoji" aria-label="🤗">🤗</button><button type="button" class="rd-emoji" aria-label="🥱">🥱</button><button type="button" class="rd-emoji" aria-label="😴">😴</button><button type="button" class="rd-emoji" aria-label="😷">😷</button><button type="button" class="rd-emoji" aria-label="🤒">🤒</button></div><div class="rd-emoji-grid" data-emoji-group="2" hidden><button type="button" class="rd-emoji" aria-label="👍">👍</button><button type="button" class="rd-emoji" aria-label="👎">👎</button><button type="button" class="rd-emoji" aria-label="👏">👏</button><button type="button" class="rd-emoji" aria-label="🙌">🙌</button><button type="button" class="rd-emoji" aria-label="👐">👐</button><button type="button" class="rd-emoji" aria-label="🤝">🤝</button><button type="button" class="rd-emoji" aria-label="🙏">🙏</button><button type="button" class="rd-emoji" aria-label="💪">💪</button><button type="button" class="rd-emoji" aria-label="👌">👌</button><button type="button" class="rd-emoji" aria-label="✌️">✌️</button><button type="button" class="rd-emoji" aria-label="🤞">🤞</button><button type="button" class="rd-emoji" aria-label="🤟">🤟</button><button type="button" class="rd-emoji" aria-label="🤘">🤘</button><button type="button" class="rd-emoji" aria-label="🤙">🤙</button><button type="button" class="rd-emoji" aria-label="👋">👋</button><button type="button" class="rd-emoji" aria-label="🤚">🤚</button><button type="button" class="rd-emoji" aria-label="✋">✋</button><button type="button" class="rd-emoji" aria-label="🖐️">🖐️</button><button type="button" class="rd-emoji" aria-label="👊">👊</button><button type="button" class="rd-emoji" aria-label="✊">✊</button><button type="button" class="rd-emoji" aria-label="🤛">🤛</button><button type="button" class="rd-emoji" aria-label="🤜">🤜</button><button type="button" class="rd-emoji" aria-label="🙋">🙋</button><button type="button" class="rd-emoji" aria-label="🫶">🫶</button></div><div class="rd-emoji-grid" data-emoji-group="3" hidden><button type="button" class="rd-emoji" aria-label="❤️">❤️</button><button type="button" class="rd-emoji" aria-label="🧡">🧡</button><button type="button" class="rd-emoji" aria-label="💛">💛</button><button type="button" class="rd-emoji" aria-label="💚">💚</button><button type="button" class="rd-emoji" aria-label="💙">💙</button><button type="button" class="rd-emoji" aria-label="💜">💜</button><button type="button" class="rd-emoji" aria-label="🖤">🖤</button><button type="button" class="rd-emoji" aria-label="🤍">🤍</button><button type="button" class="rd-emoji" aria-label="💕">💕</button><button type="button" class="rd-emoji" aria-label="💖">💖</button><button type="button" class="rd-emoji" aria-label="💯">💯</button><button type="button" class="rd-emoji" aria-label="✅">✅</button><button type="button" class="rd-emoji" aria-label="🎉">🎉</button><button type="button" class="rd-emoji" aria-label="🎊">🎊</button><button type="button" class="rd-emoji" aria-label="🎁">🎁</button><button type="button" class="rd-emoji" aria-label="🌹">🌹</button><button type="button" class="rd-emoji" aria-label="🌸">🌸</button><button type="button" class="rd-emoji" aria-label="☀️">☀️</button><button type="button" class="rd-emoji" aria-label="🌈">🌈</button><button type="button" class="rd-emoji" aria-label="⭐">⭐</button><button type="button" class="rd-emoji" aria-label="🔥">🔥</button><button type="button" class="rd-emoji" aria-label="☕">☕</button><button type="button" class="rd-emoji" aria-label="🍰">🍰</button><button type="button" class="rd-emoji" aria-label="🎈">🎈</button></div></div>
        <div class="rd-upload-status" role="status" hidden></div>
        <input type="file" class="rd-upload-input" data-kind="file" multiple hidden>
        <input type="file" class="rd-upload-input" data-kind="image" accept="image/*" multiple hidden>
        <input type="file" class="rd-upload-input" data-kind="camera" accept="image/*" capture="environment" hidden>
      </form>
      <div class="rd-voice-toast" hidden role="status"><b>!</b><span></span></div>
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
    this.#endedNode = panel.querySelector('.rd-ended') as HTMLDivElement;
    this.#listNode = panel.querySelector('.rd-list') as HTMLDivElement;
    this.#replyBar = panel.querySelector('.rd-reply') as HTMLDivElement;
    this.#searchBar = panel.querySelector('.rd-searchbar') as HTMLDivElement;
    this.#searchInput = panel.querySelector('.rd-search-input') as HTMLInputElement;
    this.#resultsNode = panel.querySelector('.rd-results') as HTMLDivElement;
    this.#pinnedBar = panel.querySelector('.rd-pinned') as HTMLDivElement;
    this.#holdButton = panel.querySelector('.rd-hold') as HTMLButtonElement;
    this.#voiceMask = panel.querySelector('.rd-voice-mask') as HTMLDivElement;
    this.#voiceToast = panel.querySelector('.rd-voice-toast') as HTMLDivElement;

    this.#toolsNode = panel.querySelector('.rd-tools') as HTMLDivElement;
    this.#emojiNode = panel.querySelector('.rd-emojis') as HTMLDivElement;
    const more = panel.querySelector('.rd-more-toggle') as HTMLButtonElement;
    const emojiToggle = panel.querySelector('.rd-emoji-toggle') as HTMLButtonElement;
    const closePanels = () => {
      this.#toolsNode!.hidden = true;
      this.#emojiNode!.hidden = true;
      more.setAttribute('aria-expanded', 'false');
    };
    // 点消息区空白（或气泡外区域）收起「+」工具栏 / 表情面板，对齐常见 IM 交互。
    const thread = panel.querySelector('.rd-thread') as HTMLDivElement;
    thread.addEventListener('pointerdown', () => {
      if (this.#toolsNode!.hidden && this.#emojiNode!.hidden) return;
      closePanels();
    });
    // Keep touch taps from moving focus to the button and fighting the soft keyboard.
    [more, emojiToggle, panel.querySelector('.rd-mic') as HTMLButtonElement].forEach(button => button.addEventListener('pointerdown', event => event.preventDefault()));
    panel.querySelectorAll<HTMLButtonElement>('[data-emoji-category]').forEach(button => {
      button.addEventListener('pointerdown', event => event.preventDefault());
      button.addEventListener('click', () => {
        panel.querySelectorAll<HTMLButtonElement>('[data-emoji-category]').forEach(tab => tab.setAttribute('aria-selected', String(tab === button)));
        panel.querySelectorAll<HTMLElement>('[data-emoji-group]').forEach(group => { group.hidden = group.dataset.emojiGroup !== button.dataset.emojiCategory; });
      });
    });
    more.addEventListener('click', () => {
      if (this.#voiceMode) this.#setVoiceMode(false);
      const open = this.#toolsNode!.hidden;
      if (open) this.#input?.blur();
      closePanels();
      this.#toolsNode!.hidden = !open;
      more.setAttribute('aria-expanded', String(open));
    });
    // 表情入口在「+」面板里（对齐微信）；点开表情时收起工具格。
    emojiToggle.addEventListener('click', () => {
      if (this.#voiceMode) this.#setVoiceMode(false);
      if (this.#input) this.#input.blur();
      closePanels();
      this.#toolsNode!.hidden = true;
      this.#emojiNode!.hidden = false;
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
    this.#bindKeyboardPin();

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

    // 点麦克风切到「按住 说话」；按住录音，松开发送，上滑取消。
    const mic = panel.querySelector('.rd-mic') as HTMLButtonElement;
    const hold = this.#holdButton as HTMLButtonElement;
    mic.hidden = false;
    mic.addEventListener('click', () => {
      if (this.#recording || this.#requestingMicrophone || this.#fingerDown) return;
      if (!this.#voiceMode && !this.#canRecord()) {
        this.#flashRecordingError('此浏览器不支持录音，请使用Chrome或Edge，并通过HTTPS或localhost访问');
        return;
      }
      const next = !this.#voiceMode;
      if (next) {
        closePanels();
        this.#input?.blur();
      }
      this.#setVoiceMode(next);
      if (!next) this.#input?.focus();
    });
    // 安卓 WebView 里只在 pointerdown 上 preventDefault，系统仍把按住当成滑动并立刻 pointercancel，
    // 按钮来不及变色。触摸必须在 touchstart 上取消默认行为；鼠标继续走指针。
    hold.addEventListener('pointerdown', (event) => {
      if (event.pointerType === 'touch') return;
      if (event.button !== 0) return;
      event.preventDefault();
      closePanels();
      this.#beginHold(event.pointerId, event.clientY, 'mouse');
    });
    hold.addEventListener('contextmenu', (event) => event.preventDefault());
    hold.addEventListener('pointermove', (event) => {
      if (event.pointerType === 'touch') return;
      this.#moveHold(event);
    });
    hold.addEventListener('pointerup', (event) => {
      if (event.pointerType === 'touch') return;
      this.#finishHold(event.pointerId, false);
    });
    hold.addEventListener('pointercancel', (event) => {
      if (event.pointerType === 'touch') return;
      this.#finishHold(event.pointerId, true);
    });
    hold.addEventListener('touchstart', (event) => {
      if (event.touches.length !== 1) return;
      event.preventDefault();
      const touch = event.changedTouches[0];
      if (!touch) return;
      closePanels();
      this.#beginHold(touch.identifier, touch.clientY, 'touch');
    }, { passive: false });

    let searchTimer: ReturnType<typeof setTimeout> | undefined;
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
    // 微信逻辑：有文字时「+」换成「发送」；语音模式下「+」常驻。
    if (send) {
      send.hidden = this.#voiceMode || !hasText;
      send.disabled = !hasText;
    }
    if (more) more.hidden = hasText && !this.#voiceMode;
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
    const serviceSubtitle = panel.querySelector('.rd-service-subtitle') as HTMLElement;
    serviceSubtitle.textContent = snapshot.automation?.channelSubtitle || this.#options.subtitle;
    subtitle.classList.toggle('is-online', snapshot.agentsOnline > 0 && snapshot.conversations.find((item) => item.id === snapshot.activeId)?.status !== 'RESOLVED');

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
    this.#syncEndedNotice(snapshot);
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
    if (snapshot.connection !== 'OPEN') {
      return '正在重连…';
    }
    // 会话结束时先说状态，在线/离线只是客服侧信息，不能盖住「已结束」。
    if (snapshot.conversations.find((item) => item.id === snapshot.activeId)?.status === 'RESOLVED') {
      return '已结束';
    }
    if (snapshot.agentsOnline > 0) {
      return '在线';
    }
    return '离线';
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
          const status = conversation.status === 'RESOLVED' ? '<span class="rd-tag">已结束</span>' : '';
          return `<button type="button" class="rd-item${active}" data-conversation="${escapeAttr(conversation.id)}">
            <span class="rd-item-main">
              <strong>${escapeHtml(title)}</strong>
              <small>${escapeHtml(conversation.lastMessagePreview ?? '')}</small>
            </span>
            <span class="rd-item-meta">${unread}${status}<time>${escapeHtml(conversation.lastMessageAt ? timeLabel(conversation.lastMessageAt) : '')}</time></span>
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
    const brand = this.#windowTitle(snapshot.automation?.channelTitle);
    return `<div class="rd-empty">
      <span class="rd-avatar lg">${this.#brandImg(ICONS.headset, false)}</span>
      <div class="rd-welcome-body"><strong>您好，欢迎来到${escapeHtml(brand)}！</strong><p>${escapeHtml(snapshot.automation?.openReply || snapshot.welcomeMessage || '我们很高兴为您服务，请问有什么可以帮您？')}</p>${this.#welcomeSuggestions(snapshot)}</div>
    </div>`;
  }

  /** 有历史时不要再插欢迎语；加载中用占位，避免刷新闪默认客服话术。 */
  #shouldShowWelcome(snapshot: Snapshot): boolean {
    return welcomeVisible(snapshot);
  }

  #threadLoadingHtml(): string {
    return `<div class="rd-thread-loading" aria-live="polite">正在加载消息…</div>`;
  }

  #renderChannel(snapshot: Snapshot): void {
    let panel=this.#root.querySelector<HTMLDivElement>('.rd-channel');
    if(!panel){panel=document.createElement('div');panel.className='rd-channel';this.#messagesNode?.after(panel);}
    const c=snapshot.automation;if(!c){panel.hidden=true;return;}
    const title=this.#root.querySelector<HTMLElement>('.rd-heading strong');
    const heading = this.#windowTitle(c.channelTitle);
    if(title)title.textContent=heading;
    this.#root.querySelector('.rd-panel')?.setAttribute('aria-label', heading);
    const items=[...(c.menuItems??[]),...(c.quickLinks??[]),...(c.diversionLinks??[])];
    panel.innerHTML=`<div class="rd-channel-row">${items.map(i=>this.#channelItemHtml(i)).join('')}</div>`;
    // 欢迎页已有引导问题/卡片时，底部再铺一层相同 chips 会重复；没有这些入口时必须显示，
    // 否则菜单类配置在首屏等于不存在。
    panel.hidden = !channelBarVisible(snapshot, items.length);
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
    const automation = system && message.metadata?.automation === true;
    // 自动回复按友商（美洽等）做法：与客服消息同一行布局——客服头像 + 气泡，
    // 仅加「自动回复」角标；系统灰字只留给分配/转接等状态事件。
    if (automation) {
      const name = this.#automationSenderName(snapshot, message);
      return `<div class="rd-row rd-msg is-theirs is-auto">
        ${this.#peerAvatarHtml()}
        <div class="rd-bubble-group">
          <span class="rd-sender">${escapeHtml(name)}<span class="rd-auto-badge">自动回复</span></span>
          <div class="rd-bubble-wrap">
            <div class="rd-bubble is-auto">${formatAutomationBody(message.content)}</div>
          </div>
          <span class="rd-time">${escapeHtml(timeLabel(message.createdAt))}</span>
        </div>
      </div>`;
    }
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
    const peerName = mine ? '' : this.#peerSenderName(snapshot, message);
    return `<div class="rd-row rd-msg ${mine ? 'is-mine' : 'is-theirs'}${isAI ? ' is-ai' : ''}" data-message="${escapeAttr(message.id)}" data-copy="${escapeAttr(copyText)}">
      ${mine ? '' : this.#peerAvatarHtml()}
      <div class="rd-bubble-group">
        ${mine || !peerName ? '' : `<span class="rd-sender">${escapeHtml(peerName)}${aiBadge}</span>`}
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
    const card = message.metadata?.card as Record<string, unknown> | undefined;
    if (message.messageType === 'CARD' && card && ['PRODUCT', 'ORDER'].includes(String(card.kind))) {
      const amount = Number(card.amountMinor);
      const price = Number.isSafeInteger(amount) && amount >= 0 ? `${Math.floor(amount / 100)}.${String(amount % 100).padStart(2, '0')}` : '';
      const safe = (value: unknown) => typeof value === 'string' && /^https?:\/\//i.test(value) ? value : '';
      const image = safe(card.imageUrl), link = safe(card.url);
      return `<div class="rd-commerce-card">${image ? `<img src="${escapeAttr(image)}" alt="商品图片" style="width:100%;max-height:160px;object-fit:contain" loading="lazy">` : ''}<strong>${escapeHtml(String(card.title || ''))}</strong>${card.kind === 'ORDER' ? `<div>订单号：${escapeHtml(String(card.orderNumber || ''))}</div><div>${escapeHtml(String(card.status || ''))}</div>` : ''}<div>${escapeHtml(String(card.currency || ''))} ${price}</div>${link ? `<a href="${escapeAttr(link)}" target="_blank" rel="noopener noreferrer">查看${card.kind === 'ORDER' ? '订单' : '商品'}</a>` : ''}</div>`;
    }
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

  /** 已结束会话要在输入框上方说清楚「再发言会去哪」，访客才不会以为没人接待。 */
  #syncEndedNotice(snapshot: Snapshot): void {
    const node = this.#endedNode;
    if (!node) {
      return;
    }
    const active = snapshot.conversations.find((item) => item.id === snapshot.activeId);
    if (!active || active.status !== 'RESOLVED') {
      node.hidden = true;
      node.textContent = '';
      return;
    }
    node.hidden = false;
    node.textContent = shouldForkAfterGrace(active, snapshot.reopenGraceMinutes)
      ? '本次咨询已结束，继续发言会开启新咨询，进入公共队列由在线客服接待。'
      : '本次咨询已结束，继续发言将重新由原客服接待。';
  }

  #canRecord(): boolean {
    return typeof MediaRecorder !== 'undefined' && typeof navigator.mediaDevices?.getUserMedia === 'function';
  }

  #setVoiceMode(on: boolean): void {
    if (!on && (this.#fingerDown || this.#recording || this.#requestingMicrophone)) {
      this.#fingerDown = false;
      this.#holdCancel = false;
      this.#holdGen += 1;
      this.#unwatchHoldPointer();
      if (this.#recording) this.#stopRecording(true);
      else this.#releaseLevelMeter();
    }
    if (on === this.#voiceMode) return;
    this.#voiceMode = on;
    this.#syncVoiceChrome();
  }

  /** 换肤会拆掉面板，先停掉还在进行的录音，避免麦克风停不下来。 */
  #abandonRecording(): void {
    this.#fingerDown = false;
    this.#holdCancel = false;
    this.#holdGen += 1;
    this.#unwatchHoldPointer();
    if (this.#voiceToastTimer) {
      clearTimeout(this.#voiceToastTimer);
      this.#voiceToastTimer = undefined;
    }
    if (this.#recording) this.#stopRecording(true);
    else this.#releaseLevelMeter();
    this.#voiceMode = false;
  }

  #syncVoiceChrome(): void {
    const mic = this.#root.querySelector('.rd-mic') as HTMLButtonElement | null;
    if (mic) {
      mic.innerHTML = this.#voiceMode ? ICONS.keyboard : ICONS.mic;
      const label = this.#voiceMode ? '键盘' : '语音';
      mic.title = label;
      mic.setAttribute('aria-label', label);
      mic.setAttribute('aria-pressed', this.#voiceMode ? 'true' : 'false');
    }
    if (this.#input) this.#input.hidden = this.#voiceMode;
    if (this.#holdButton) this.#holdButton.hidden = !this.#voiceMode;
    this.#syncSendButton();
    this.#paintVoice();
  }

  #beginHold(pointerId: number, clientY: number, source: 'mouse' | 'touch'): void {
    if (this.#fingerDown || this.#recording) return;
    if (!this.#canRecord()) {
      this.#flashRecordingError('此浏览器不支持录音，请使用Chrome或Edge，并通过HTTPS或localhost访问');
      return;
    }
    this.#fingerDown = true;
    this.#holdCancel = false;
    this.#holdInterrupted = false;
    this.#reportHoldEnd = false;
    this.#heardSound = false;
    this.#canMeter = false;
    this.#holdStartY = clientY;
    this.#holdGen += 1;
    const gen = this.#holdGen;
    if (source === 'mouse') {
      const hold = this.#holdButton;
      if (hold) {
        try {
          hold.setPointerCapture(pointerId);
        } catch {
          // 指针可能在按下的同一瞬间已经结束。
        }
      }
      this.#watchHoldPointer(pointerId);
    } else {
      this.#watchHoldTouch(pointerId);
    }
    this.#armLevelMeter();
    this.#paintVoice();
    if (this.#requestingMicrophone) {
      void this.#startRecordingWhenIdle(gen);
      return;
    }
    void this.#startRecording(gen);
  }

  /** 上一次开麦还没返回时又按住了，等那次结束再开始这一次。 */
  async #startRecordingWhenIdle(gen: number): Promise<void> {
    while (this.#requestingMicrophone && gen === this.#holdGen) {
      await new Promise((resolve) => setTimeout(resolve, 40));
    }
    if (gen !== this.#holdGen || this.#recording) return;
    if (!this.#fingerDown) {
      if (this.#reportHoldEnd) {
        this.#reportHoldEnd = false;
        this.#paintVoice();
        this.#flashHoldEnd();
      }
      return;
    }
    await this.#startRecording(gen);
  }

  #watchHoldPointer(pointerId: number): void {
    this.#unwatchHoldPointer();
    this.#holdPointerId = pointerId;
    this.#holdWatch = (watchEvent: PointerEvent) => {
      if (watchEvent.pointerId !== pointerId) return;
      if (watchEvent.type === 'pointermove') {
        this.#moveHold(watchEvent);
        return;
      }
      this.#finishHold(watchEvent.pointerId, watchEvent.type === 'pointercancel');
    };
    window.addEventListener('pointermove', this.#holdWatch, true);
    window.addEventListener('pointerup', this.#holdWatch, true);
    window.addEventListener('pointercancel', this.#holdWatch, true);
  }

  #watchHoldTouch(pointerId: number): void {
    this.#unwatchHoldPointer();
    this.#holdPointerId = pointerId;
    this.#holdTouchWatch = (event: TouchEvent) => {
      const ended = event.type === 'touchend' || event.type === 'touchcancel';
      const list = ended ? event.changedTouches : event.touches;
      const mine = Array.from(list).find((item) => item.identifier === pointerId);
      if (!mine) return;
      if (event.type === 'touchmove') {
        event.preventDefault();
        this.#moveHoldY(mine.clientY);
        return;
      }
      this.#finishHold(pointerId, event.type === 'touchcancel');
    };
    window.addEventListener('touchmove', this.#holdTouchWatch, { capture: true, passive: false });
    window.addEventListener('touchend', this.#holdTouchWatch, { capture: true, passive: false });
    window.addEventListener('touchcancel', this.#holdTouchWatch, { capture: true, passive: false });
  }

  #unwatchHoldPointer(): void {
    if (this.#holdWatch) {
      window.removeEventListener('pointermove', this.#holdWatch, true);
      window.removeEventListener('pointerup', this.#holdWatch, true);
      window.removeEventListener('pointercancel', this.#holdWatch, true);
      this.#holdWatch = undefined;
    }
    if (this.#holdTouchWatch) {
      window.removeEventListener('touchmove', this.#holdTouchWatch, true);
      window.removeEventListener('touchend', this.#holdTouchWatch, true);
      window.removeEventListener('touchcancel', this.#holdTouchWatch, true);
      this.#holdTouchWatch = undefined;
    }
    this.#holdPointerId = undefined;
  }

  #moveHold(event: PointerEvent): void {
    if (this.#holdPointerId != null && event.pointerId !== this.#holdPointerId) return;
    this.#moveHoldY(event.clientY);
  }

  #moveHoldY(clientY: number): void {
    if (!this.#fingerDown) return;
    const cancel = this.#holdStartY - clientY > 80;
    if (cancel === this.#holdCancel) return;
    this.#holdCancel = cancel;
    this.#paintVoice(this.#recording ? Date.now() - this.#recordStartedAt : undefined);
  }

  #finishHold(pointerId: number, interrupted: boolean): void {
    if (this.#holdPointerId != null && pointerId !== this.#holdPointerId) return;
    if (!this.#fingerDown && !this.#recording) return;
    this.#unwatchHoldPointer();
    const recording = this.#recording;
    this.#fingerDown = false;
    if (interrupted) this.#holdInterrupted = true;
    if (recording) {
      this.#stopRecording(this.#holdCancel);
      return;
    }
    this.#paintVoice();
    // 麦克风还在打开时，等请求结束再提示，避免和失败文案叠在一起。
    if (this.#requestingMicrophone) {
      this.#reportHoldEnd = true;
      return;
    }
    this.#flashHoldEnd();
  }

  #flashHoldEnd(): void {
    if (this.#holdCancel) {
      this.#flashRecordingError('已取消');
      return;
    }
    if (this.#holdInterrupted) {
      this.#flashRecordingError('录音没开始，请重新按住说话');
      return;
    }
    this.#flashRecordingError('请按住，直到显示正在录音');
  }

  #paintVoice(elapsedMs?: number): void {
    const holding = this.#fingerDown || this.#recording;
    const cancel = holding && this.#holdCancel;
    const silent = this.#recording && this.#canMeter && !this.#heardSound;
    this.#composer?.classList.toggle('is-holding', holding && !cancel && !silent);
    this.#composer?.classList.toggle('is-silent', holding && !cancel && silent);
    this.#composer?.classList.toggle('is-cancel', cancel);
    const hold = this.#holdButton;
    if (hold) {
      const label = cancel
        ? '松开 取消'
        : !holding
          ? '按住 说话'
          : !this.#recording
            ? '正在打开麦克风'
            : silent
              ? '未检测到声音'
              : '正在录音';
      hold.textContent = label;
      hold.setAttribute('aria-label', label.replace(/\s/g, ''));
      hold.setAttribute('aria-pressed', holding ? 'true' : 'false');
    }
    const mask = this.#voiceMask;
    if (!mask) return;
    mask.hidden = !holding;
    mask.classList.toggle('is-cancel', cancel);
    mask.classList.toggle('is-silent', silent);
    mask.classList.toggle('is-live', this.#recording && this.#canMeter && this.#heardSound && !cancel);
    const tip = mask.querySelector('.rd-voice-tip');
    if (tip) {
      tip.textContent = cancel
        ? '松开手指，取消发送'
        : !this.#recording
          ? '正在打开麦克风，请继续按住'
          : silent
            ? '未检测到声音，请靠近麦克风说话'
            : '正在录音，松手即可发送';
    }
    const waves = mask.querySelector('.rd-voice-waves') as HTMLElement | null;
    const cancelIcon = mask.querySelector('.rd-voice-cancel') as HTMLElement | null;
    const count = mask.querySelector('.rd-voice-count') as HTMLElement | null;
    const left = elapsedMs == null ? Number.POSITIVE_INFINITY : Math.max(0, 60_000 - elapsedMs);
    const showCount = this.#recording && !cancel && left <= 10_000;
    if (cancelIcon) cancelIcon.hidden = !cancel;
    if (count) {
      count.hidden = !showCount;
      if (showCount) count.textContent = String(Math.max(1, Math.ceil(left / 1000)));
    }
    if (waves) waves.hidden = cancel || showCount;
  }

  #armLevelMeter(): void {
    if (this.#audioContext) {
      void this.#audioContext.resume();
      return;
    }
    const Ctor = window.AudioContext
      ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctor) return;
    try {
      this.#audioContext = new Ctor();
      void this.#audioContext.resume();
    } catch {
      this.#audioContext = undefined;
    }
  }

  #attachLevelMeter(stream: MediaStream): void {
    const ctx = this.#audioContext;
    if (!ctx) return;
    // 音量只看复制出来的音轨，避免和录音抢同一路麦克风。
    const monitor = stream.clone();
    this.#monitorStream = monitor;
    const gen = this.#holdGen;
    void ctx.resume().then(() => {
      if (gen !== this.#holdGen || !this.#recording || this.#monitorStream !== monitor || ctx.state !== 'running') {
        monitor.getTracks().forEach((track) => track.stop());
        if (this.#monitorStream === monitor) this.#monitorStream = undefined;
        return;
      }
      try {
        const source = ctx.createMediaStreamSource(monitor);
        const analyser = ctx.createAnalyser();
        analyser.fftSize = 256;
        source.connect(analyser);
        const bins = new Uint8Array(analyser.fftSize);
        const bars = this.#voiceMask?.querySelectorAll<HTMLElement>('.rd-voice-waves i');
        this.#canMeter = true;
        this.#levelTimer = setInterval(() => {
          if (!this.#recording) return;
          analyser.getByteTimeDomainData(bins);
          let sum = 0;
          for (let index = 0; index < bins.length; index += 1) {
            const sample = ((bins[index] ?? 128) - 128) / 128;
            sum += sample * sample;
          }
          const rms = Math.sqrt(sum / bins.length);
          if (rms > 0.015 && !this.#heardSound) {
            this.#heardSound = true;
            this.#paintVoice(Date.now() - this.#recordStartedAt);
          }
          const heard = this.#heardSound;
          bars?.forEach((bar, index) => {
            if (!heard) {
              bar.style.transform = '';
              return;
            }
            const value = bins[Math.min(bins.length - 1, Math.floor((index + 0.5) * bins.length / bars.length))] ?? 128;
            const amp = Math.min(1, Math.abs(value - 128) / 32);
            bar.style.transform = `scaleY(${(0.35 + amp * 2.2).toFixed(2)})`;
          });
        }, 80);
        this.#paintVoice(Date.now() - this.#recordStartedAt);
      } catch {
        this.#canMeter = false;
        monitor.getTracks().forEach((track) => track.stop());
        if (this.#monitorStream === monitor) this.#monitorStream = undefined;
      }
    }).catch(() => {
      this.#canMeter = false;
      monitor.getTracks().forEach((track) => track.stop());
      if (this.#monitorStream === monitor) this.#monitorStream = undefined;
    });
  }

  #releaseLevelMeter(): void {
    if (this.#levelTimer) {
      clearInterval(this.#levelTimer);
      this.#levelTimer = undefined;
    }
    this.#canMeter = false;
    this.#heardSound = false;
    this.#monitorStream?.getTracks().forEach((track) => track.stop());
    this.#monitorStream = undefined;
    this.#voiceMask?.classList.remove('is-live');
    this.#voiceMask?.querySelectorAll<HTMLElement>('.rd-voice-waves i').forEach((bar) => {
      bar.style.transform = '';
    });
    const ctx = this.#audioContext;
    this.#audioContext = undefined;
    if (ctx && ctx.state !== 'closed') void ctx.close();
  }

  async #startRecording(gen: number): Promise<void> {
    if (this.#recording || this.#requestingMicrophone) return;
    this.#requestingMicrophone = true;
    let stream: MediaStream;
    try {
      stream = await requestMicrophone(() => navigator.mediaDevices.getUserMedia({ audio: true }));
    } catch (error) {
      const message = error instanceof Error && error.message.includes('授权未完成')
        ? error.message
        : '无法访问麦克风，请检查浏览器权限';
      const newerHold = gen !== this.#holdGen && this.#fingerDown;
      if (!newerHold) {
        if (gen === this.#holdGen) {
          this.#fingerDown = false;
          this.#unwatchHoldPointer();
        }
        this.#reportHoldEnd = false;
        this.#releaseLevelMeter();
        this.#paintVoice();
        this.#flashRecordingError(message);
      }
      return;
    } finally {
      this.#requestingMicrophone = false;
    }
    if (gen !== this.#holdGen || !this.#fingerDown) {
      stream.getTracks().forEach((track) => track.stop());
      const newerHold = gen !== this.#holdGen && this.#fingerDown;
      if (!newerHold) this.#releaseLevelMeter();
      const endedThisGesture = gen === this.#holdGen && !this.#fingerDown;
      if (endedThisGesture || (this.#reportHoldEnd && !this.#fingerDown && !this.#recording)) {
        this.#reportHoldEnd = false;
        this.#paintVoice();
        this.#flashHoldEnd();
      }
      return;
    }
    let recorder: MediaRecorder;
    try {
      const mimeType = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4'].find((type) =>
        MediaRecorder.isTypeSupported(type),
      );
      recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined);
    } catch {
      stream.getTracks().forEach((track) => track.stop());
      this.#fingerDown = false;
      this.#unwatchHoldPointer();
      this.#releaseLevelMeter();
      this.#paintVoice();
      this.#flashRecordingError('无法开始录音');
      return;
    }
    this.#recorder = recorder;
    this.#recordChunks = collectRecordingChunks(recorder);
    recorder.addEventListener('stop', () => {
      stream.getTracks().forEach((track) => track.stop());
    });
    try {
      recorder.start(200);
    } catch {
      if (recorder.state === 'inactive') {
        try {
          recorder.start();
        } catch {
          // 分片启动失败时再试一次；仍失败则按未开始处理。
        }
      }
    }
    const started = recorder.state === 'recording';
    if (!started) {
      stream.getTracks().forEach((track) => track.stop());
      this.#fingerDown = false;
      this.#unwatchHoldPointer();
      this.#releaseLevelMeter();
      this.#recorder = undefined;
      this.#recordChunks = [];
      this.#paintVoice();
      this.#flashRecordingError('无法开始录音');
      return;
    }
    this.#recording = true;
    this.#recordStartedAt = Date.now();
    this.#attachLevelMeter(stream);
    this.#paintVoice(0);
    this.#recordTimer = setInterval(() => {
      const elapsed = Date.now() - this.#recordStartedAt;
      if (elapsed >= 60_000) {
        this.#fingerDown = false;
        this.#holdCancel = false;
        this.#unwatchHoldPointer();
        this.#stopRecording(false);
        return;
      }
      this.#paintVoice(elapsed);
    }, 200);
    if (!this.#fingerDown) this.#stopRecording(this.#holdCancel);
  }

  #stopRecording(cancel: boolean): void {
    const recorder = this.#recorder;
    if (!recorder || !this.#recording) return;
    const elapsed = Date.now() - this.#recordStartedAt;
    const silent = this.#canMeter && !this.#heardSound;
    this.#recording = false;
    this.#holdCancel = false;
    if (this.#recordTimer) {
      clearInterval(this.#recordTimer);
      this.#recordTimer = undefined;
    }
    this.#releaseLevelMeter();
    this.#paintVoice();
    this.#recorder = undefined;
    const chunks = this.#recordChunks;
    this.#recordChunks = [];
    const deliver = !cancel && elapsed >= 1_000 && !silent;
    const tooShort = elapsed < 1_000;
    recorder.addEventListener('stop', () => {
      if (cancel) return;
      if (!deliver || chunks.length === 0) {
        this.#flashRecordingError(tooShort ? '说话时间太短' : '没有录到声音，请检查麦克风');
        return;
      }
      this.#handlers.onVoice(new Blob(chunks, { type: recorder.mimeType || 'audio/webm' }), elapsed);
    });
    try {
      recorder.stop();
    } catch {
      if (!cancel) this.#flashRecordingError(tooShort ? '说话时间太短' : '没有录到声音，请检查麦克风');
    }
  }

  #flashRecordingError(message: string): void {
    const toast = this.#voiceToast;
    if (!toast) return;
    const text = toast.querySelector('span');
    if (text) text.textContent = message;
    toast.hidden = false;
    if (this.#voiceToastTimer) clearTimeout(this.#voiceToastTimer);
    this.#voiceToastTimer = setTimeout(() => {
      toast.hidden = true;
    }, message.length > 12 ? 2_200 : 1_400);
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

  /** 客服侧头像：自动回复与人工消息共用，优先入口 avatarUrl / logoUrl。 */
  #peerAvatarHtml(): string {
    return `<span class="rd-avatar sm">${this.#brandImg(ICONS.headset, false)}</span>`;
  }

  /** 产品内部称呼，不能出现在访客侧回复人名。 */
  #isProductSenderName(name: string): boolean {
    const n = name.trim();
    if (!n) return true;
    return (
      n === '通语助手' ||
      n === '语聊助手' ||
      n === '通语客服' ||
      n === '语聊客服' ||
      n === 'AI 助手' ||
      n === 'AI助手' ||
      n === '客服助手'
    );
  }

  /** 嵌入页顶部名称。宿主 title 优先于入口聊天窗口名称。 */
  #windowTitle(channelTitle?: string): string {
    return windowTitle(this.#options.title, channelTitle, this.#options.embedded);
  }

  /** 嵌入方对外名称：窗口名 →「在线客服」。 */
  #embedSenderName(snapshot: Snapshot): string {
    const name = this.#windowTitle(snapshot.automation?.channelTitle);
    if (name && !this.#isProductSenderName(name)) {
      return name;
    }
    return '在线客服';
  }

  /** 自动回复展示名：嵌入给谁就显示谁，不用产品品牌名。 */
  #automationSenderName(snapshot: Snapshot, message: ChatMessage): string {
    const meta =
      typeof message.metadata?.senderName === 'string' ? message.metadata.senderName.trim() : '';
    if (meta && !this.#isProductSenderName(meta)) {
      return meta;
    }
    return this.#embedSenderName(snapshot);
  }

  /** 人工 / AI 消息：真人姓名保留；产品内部名换成嵌入方名称。 */
  #peerSenderName(snapshot: Snapshot, message: ChatMessage): string {
    const raw = message.senderName?.trim() || '';
    if (raw && !this.#isProductSenderName(raw)) {
      return raw;
    }
    return this.#embedSenderName(snapshot);
  }

  #styles(): string {
    const light = this.#options.theme !== 'dark';
    const accent = this.#options.primaryColor;
    // 浅色品牌主色（彩站黄/奶油顶栏）不能直接当字色，否则常见问题芯片白底上看不见。
    const accentInk = onAccentInk(accent, light);
    const questionInk = chipInk(accent, light);
    const radius = this.#options.bubbleRadius ?? 12;
    const fontStack = this.#options.fontFamily ||
      'system-ui, -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif';
    const side = this.#options.position === 'left' ? 'left' : 'right';
    return `
:host { all: initial; }
:host { --rd-accent: ${accent}; --rd-accent-ink: ${accentInk}; --rd-chip-ink: ${questionInk}; --rd-radius: ${radius}px; --rd-radius-sm: ${Math.max(0, radius - 8)}px; --rd-font: ${fontStack}; }
* { box-sizing: border-box; }
/* 隐藏属性必须压过组件布局，避免文件输入框或导航按钮泄漏到界面。 */
[hidden] { display: none !important; }
.rd-launcher-slot, .rd-panel-slot { position: fixed; z-index: ${this.#options.zIndex}; ${side}: 20px; }
.rd-launcher-slot { bottom: 20px; }
.rd-panel-slot { bottom: 20px; }
.rd-launcher {
  display: inline-flex; align-items: center; gap: 8px; border: 1px solid var(--rd-accent, ${accent}); cursor: pointer;
  border-radius: var(--rd-radius, 12px); padding: 10px 14px; font: 600 14px/1.2 var(--rd-font);
  color: var(--rd-accent-ink, ${accentInk}); background: var(--rd-accent, ${accent});
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
/* 嵌入 iframe 时必须跟宿主盒子走 100%，不能用 vw/vh/dvh：
   宿主（尤其 Flutter Web）常把 iframe 裁成安全区高度，dvh 仍按整屏算会导致
   内部布局比看得见的区域更高，常见问题按钮和输入框都点空。 */
.rd-panel-slot, .rd-panel { top: 0; right: 0; bottom: 0; left: 0; width: 100%; max-width: none; height: 100%; max-height: none; border: 0; border-radius: 0; box-shadow: none; }
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
.rd-avatar.sm { width: 28px; height: 28px; background: color-mix(in srgb, var(--rd-accent, ${accent}) 10%, transparent); color: var(--rd-accent, ${accent}); align-self: flex-end; }
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
.rd-body { position: relative; flex: 1; min-height: 0; display: flex; overflow: hidden; background: ${light ? '#f9fafb' : '#111827'}; }
.rd-thread { position: relative; flex: 1; display: flex; flex-direction: column; min-height: 0; }
.rd-messages { background: ${light ? '#f7f8fa' : '#171b24'}; flex: 1; overflow-y: auto; padding: 20px 18px 12px; display: flex; flex-direction: column; gap: 16px; scrollbar-width: thin; }
.rd-messages::-webkit-scrollbar { width: 6px; }
.rd-messages::-webkit-scrollbar-thumb { background: ${light ? '#d1d5db' : '#4b5563'}; border-radius: 3px; }
.rd-channel{padding:10px 16px;border-top:1px solid #edf0f5;background:${light ? '#fff' : '#1f2937'};max-height:104px;overflow:auto;flex-shrink:0}.rd-channel[hidden]{display:none}.rd-channel-row{display:flex;gap:8px;flex-wrap:wrap}.rd-channel-chip{font:inherit;font-size:12px;color:var(--rd-chip-ink,${questionInk});background:color-mix(in srgb,var(--rd-accent,${accent}) 16%,${light ? '#ffffff' : '#171b24'});border:1px solid color-mix(in srgb,var(--rd-accent,${accent}) 40%,transparent);border-radius:6px;padding:7px 10px;text-decoration:none;cursor:pointer;touch-action:manipulation;-webkit-tap-highlight-color:transparent}.rd-welcome-suggestions{margin:12px 0 20px 38px}.rd-guide-title{color:#6b7280;font-size:12px;margin-bottom:8px}.rd-channel-card{display:flex;gap:12px;border:1px solid #edf0f5;border-radius:8px;padding:12px;margin:8px 0}.rd-channel-card img{width:56px;height:56px;object-fit:cover;border-radius:6px}.rd-channel-card p{font-size:12px;color:#6b7280;margin:5px 0}.rd-empty { display: flex; align-items: flex-start; gap: 10px; color: inherit; padding: 12px 0; }
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
.rd-receipt.is-read { color: var(--rd-chip-ink, ${questionInk}); }
.rd-sys { align-self: center; font-size: 12px; color: ${light ? '#8c93a3' : '#8b91a0'}; background: ${light ? '#f5f6f8' : '#23262d'}; padding: 3px 8px; border-radius: 4px; }
/* 自动回复角标/气泡跟入口主色走（含白标 --rd-accent），不用写死通语蓝。 */
.rd-auto-badge { display: inline-flex; align-items: center; margin-left: 6px; font-size: 10.5px; font-weight: 600; color: var(--rd-accent-ink, var(--rd-accent, ${accent})); background: color-mix(in srgb, var(--rd-accent, ${accent}) 22%, ${light ? '#ffffff' : '#171b24'}); border-radius: 999px; padding: 1px 7px; vertical-align: middle; }
.rd-bubble.is-auto { background: color-mix(in srgb, var(--rd-accent, ${accent}) 18%, ${light ? '#ffffff' : '#171b24'}); border: 1px solid color-mix(in srgb, var(--rd-accent, ${accent}) 28%, transparent); color: var(--rd-accent-ink, ${light ? '#0c1d40' : '#e8eefc'}); }
.rd-auto-lead { margin: 0 0 8px; font-size: 13.5px; line-height: 1.55; }
.rd-auto-lead:last-child { margin-bottom: 0; }
.rd-auto-steps { list-style: none; margin: 0; padding: 0; }
.rd-auto-steps li { position: relative; padding: 6px 0 6px 16px; font-size: 12.5px; line-height: 1.5; border-top: 1px solid color-mix(in srgb, var(--rd-accent, ${accent}) 14%, transparent); color: var(--rd-accent-ink, ${light ? '#3d4b62' : '#c5d0e8'}); opacity: .92; }
.rd-auto-steps li:first-child { border-top: 0; padding-top: 0; }
.rd-auto-steps li::before { content: ""; position: absolute; left: 0; top: 12px; width: 7px; height: 7px; border-radius: 50%; background: var(--rd-accent, ${accent}); opacity: .55; }
.rd-auto-steps li:first-child::before { top: 6px; }
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
.rd-typing { display: flex; align-items: center; gap: 6px; flex-shrink: 0; position: relative; z-index: 5; padding: 6px 16px; background: ${light ? '#ffffff' : '#1e1f24'}; color: ${light ? '#171717' : '#e8eaef'}; font-size: 12px; line-height: 1.4; border-top: 1px solid ${light ? '#E5E8EF' : '#2b2f37'}; }
.rd-typing[hidden] { display: none; }
.rd-typing em { font-style: normal; }
.rd-typing span { width: 6px; height: 6px; border-radius: 50%; background: ${light ? '#646A73' : '#c5cad3'}; animation: rd-bounce 1.2s infinite; }
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
.rd-tag { align-self: flex-end; padding: 1px 7px; border-radius: 999px; font: 500 11px/16px var(--rd-font); color: ${light ? '#8a909e' : '#9aa0ad'}; background: ${light ? '#eef1f6' : '#2b303a'}; }
.rd-ended { flex-shrink: 0; padding: 7px 16px; font-size: 12px; line-height: 1.4; color: ${light ? '#8a5a12' : '#f0c98a'}; background: ${light ? '#fff7e8' : '#2a2418'}; }
.rd-ended[hidden] { display: none; }
/* 单行输入栏格局对齐微信：左语音、中输入框、右「+」；有文字时「+」换成「发送」。配色仍走企业主色与主题。 */
.rd-composer { display: flex; flex-direction: column; border-top: 1px solid ${light ? '#e9edf3' : '#303848'}; background: ${light ? '#ffffff' : '#1e1f24'}; }
.rd-composer[hidden] { display: none; }
.rd-composer-row { display: flex; align-items: flex-end; gap: 8px; padding: 8px; background: ${light ? '#ffffff' : '#1e1f24'}; }
.rd-composer-row .rd-icon { flex: none; width: 44px; height: 44px; padding: 0; border-radius: 8px; background: transparent; color: ${light ? '#646A73' : '#d1d5db'}; }
.rd-composer-row .rd-icon svg { width: 24px; height: 24px; }
.rd-composer-row .rd-icon:hover { background: ${light ? '#f0f3f8' : '#303848'}; color: ${light ? '#646A73' : '#d1d5db'}; }
.rd-tools { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 20px 8px; padding: 22px 16px 16px; background: ${light ? '#f5f6f7' : '#1e1f24'}; border-top: 1px solid ${light ? '#e8ebed' : '#374151'}; }
.rd-tool { display: flex; flex-direction: column; align-items: center; gap: 9px; border: 0; background: transparent; color: inherit; cursor: pointer; font: inherit; font-size: 12px; }
.rd-tool span { display: grid; place-items: center; width: 54px; height: 54px; background: ${light ? '#ffffff' : '#2b3038'}; border-radius: 14px; border: 1px solid ${light ? '#eceeef' : '#374151'}; }
.rd-tool svg { width: 26px; height: 26px; }
.rd-tool:hover span { border-color: ${accent}; }
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
.rd-composer-row .rd-input { flex: 1 1 0%; width: 0; min-width: 0; min-height: 44px; max-height: 120px; border: 1px solid ${light ? '#e9edf3' : '#303848'}; border-radius: 8px; background: ${light ? '#ffffff' : '#222733'}; padding: 10px 12px; font-size: 15px; line-height: 20px; }
.rd-composer-row .rd-input:focus { border-color: ${accent}; }
.rd-composer { padding-bottom: env(safe-area-inset-bottom, 0px); }
.rd-panel.is-keyboard .rd-composer { padding-bottom: 0; }
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
  flex: 1; resize: none; color: inherit; outline: none; font: inherit;
  transition: background-color 0.12s, color 0.12s, border-color 0.12s;
  /* 边框、聚焦主色等外观统一见 .rd-composer-row .rd-input。 */
}
.rd-input::-webkit-scrollbar { width: 0; height: 0; display: none; }
.rd-input::-webkit-scrollbar-button { width: 0; height: 0; display: none; }
.rd-send {
  display: inline-flex; align-items: center; justify-content: center; flex: 0 0 58px; width: 58px; height: 44px;
  border: 0; border-radius: 8px; background: var(--rd-accent, ${accent}); color: var(--rd-accent-ink, ${accentInk}); font: 500 14px/1 var(--rd-font); cursor: pointer;
}
.rd-send:hover:not(:disabled) { filter: brightness(1.05); }
.rd-send svg { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 2; }
.rd-send:disabled { opacity: .4; cursor: not-allowed; }
.rd-hold {
  display: flex; align-items: center; justify-content: center; flex: 1 1 0%; width: 0; min-width: 0; height: 44px; padding: 0;
  border: 1px solid ${light ? '#e5e6eb' : '#3a4150'}; border-radius: 8px;
  background: ${light ? '#ffffff' : '#2a3140'}; color: ${light ? '#1f2329' : '#eef2f1'};
  font: 500 16px/1 var(--rd-font); cursor: pointer; user-select: none; -webkit-user-select: none;
  -webkit-touch-callout: none; touch-action: none; overscroll-behavior: none;
}
.rd-composer.is-holding .rd-hold { background: var(--rd-accent, ${accent}); border-color: var(--rd-accent, ${accent}); color: var(--rd-accent-ink, ${accentInk}); }
.rd-composer.is-silent .rd-hold { background: #ffb020; border-color: #ffb020; color: #111; }
.rd-composer.is-cancel .rd-hold { background: #fa5151; border-color: #fa5151; color: #fff; }
.rd-voice-mask {
  position: absolute; inset: 0; z-index: 6; display: flex; flex-direction: column; align-items: center;
  justify-content: flex-end; padding: 0 16px 18px; background: rgba(0, 0, 0, .38); pointer-events: none;
}
.rd-voice-mask[hidden] { display: none; }
.rd-voice-card {
  width: 160px; height: 88px; border-radius: 14px; background: var(--rd-accent, ${accent}); color: var(--rd-accent-ink, ${accentInk});
  display: flex; align-items: center; justify-content: center;
}
.rd-voice-mask.is-silent .rd-voice-card { background: #ffb020; color: #111; }
.rd-voice-mask.is-cancel .rd-voice-card { background: #fa5151; color: #fff; }
.rd-voice-mask.is-silent .rd-voice-waves i { animation: none; transform: scaleY(.35); }
.rd-voice-waves { display: flex; align-items: center; justify-content: center; gap: 3px; height: 36px; }
.rd-voice-waves i {
  display: block; width: 3px; height: 16px; border-radius: 2px; background: currentColor; transform-origin: center;
  animation: rd-wave .9s ease-in-out infinite;
}
.rd-voice-waves i:nth-child(2), .rd-voice-waves i:nth-child(8) { animation-delay: .1s; }
.rd-voice-waves i:nth-child(3), .rd-voice-waves i:nth-child(7) { animation-delay: .2s; }
.rd-voice-waves i:nth-child(4), .rd-voice-waves i:nth-child(6) { animation-delay: .3s; }
.rd-voice-waves i:nth-child(5) { animation-delay: .4s; }
.rd-voice-mask.is-live .rd-voice-waves i { animation: none; }
@keyframes rd-wave { 0%, 100% { transform: scaleY(.35); } 50% { transform: scaleY(1.7); } }
.rd-voice-cancel { display: inline-flex; color: inherit; }
.rd-voice-cancel svg { width: 28px; height: 28px; }
.rd-voice-count { font-size: 42px; font-weight: 500; line-height: 1; color: inherit; }
.rd-voice-tip { margin: 16px 0 4px; color: #fff; font-size: 16px; font-weight: 600; text-shadow: 0 1px 2px rgba(0,0,0,.35); }
.rd-voice-toast {
  position: absolute; left: 50%; top: 42%; z-index: 45; transform: translate(-50%, -50%);
  width: max-content; max-width: 220px; padding: 22px 16px 16px; border-radius: 12px;
  background: rgba(28, 28, 28, .82); color: #fff; text-align: center; pointer-events: none;
}
.rd-voice-toast[hidden] { display: none; }
.rd-voice-toast b {
  display: grid; place-items: center; width: 36px; height: 36px; margin: 0 auto 10px;
  border: 2px solid #fff; border-radius: 50%; font-size: 22px; font-weight: 600; line-height: 1;
}
.rd-voice-toast span { display: block; font-size: 14px; line-height: 1.45; }
.rd-footer { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 14px 12px; font-size: 12px; color: ${light ? '#5b6172' : '#a8aebb'}; }
.rd-footer[hidden] { display: none; }
.rd-stars { display: inline-flex; gap: 2px; }
.rd-star { border: 0; background: transparent; padding: 0; cursor: pointer; color: ${light ? '#c9cede' : '#4c525d'}; }
.rd-star svg { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 1.6; }
.rd-star:hover svg, .rd-star:hover ~ .rd-star svg { fill: #fbbf24; stroke: #fbbf24; }
@media (max-width: 480px) {
  /* 仅非嵌入浮层用 vw/dvh 铺满手机屏；嵌入态保持上面的 100%。 */
  .rd-panel:not(.is-embedded) { ${side}: 0; bottom: 0; width: 100vw; height: 100vh; height: 100dvh; max-width: none; border-radius: 0; border: 0; }
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
.rd-empty .rd-avatar.lg { width: 44px; height: 44px; border-radius: 12px; background: var(--rd-accent, ${accent}); color: var(--rd-accent-ink, ${accentInk}); }
.rd-welcome-body { flex: 1; min-width: 0; }
.rd-welcome-body > strong { font-size: 14px; font-weight: 600; }
.rd-empty p { padding: 0; border: 0; background: transparent; border-radius: 0; max-width: none; color: #646A73; font-size: 13px; line-height: 1.6; margin-top: 3px; }
.rd-welcome-suggestions { margin: 8px 0 0; }
.rd-thread-loading { align-self: center; margin: 28px 0; font-size: 12px; color: #8F959E; }
.rd-guide-title { color: #8F959E; margin-bottom: 6px; }
.rd-channel { border-color: #E5E8EF; padding: 8px 14px; }
.rd-channel-row { gap: 6px; }
/* 芯片铺在浅底上：浅主色用深墨字，深主色可保留品牌色字；勿写死 color:${accent}。 */
.rd-channel-chip { color: var(--rd-chip-ink, ${questionInk}); background: color-mix(in srgb, var(--rd-accent, ${accent}) 18%, #fff); border: 1px solid color-mix(in srgb, var(--rd-accent, ${accent}) 42%, transparent); border-radius: 999px; padding: 4px 10px; font-size: 12px; }
.rd-channel-chip:hover { background: color-mix(in srgb, var(--rd-accent, ${accent}) 28%, #fff); }
.rd-channel-card { border-color: #E5E8EF; border-radius: 10px; }
.rd-row { align-items: flex-start; gap: 8px; }
.rd-avatar.sm { width: 32px; height: 32px; border-radius: 50%; align-self: flex-start; background: color-mix(in srgb, var(--rd-accent, ${accent}) 12%, transparent); color: var(--rd-accent, ${accent}); }
.rd-avatar.sm svg { width: 20px; height: 20px; }
.rd-bubble-group { max-width: calc(100% - 44px); gap: 4px; }
.rd-row.is-mine .rd-bubble-group { max-width: 85%; }
.rd-sender { font-size: 12px; color: #646A73; }
  .rd-ai-badge { display: inline-flex; align-items: center; justify-content: center; margin-left: 6px; padding: 0 6px; height: 15px; font-size: 10px; font-weight: 700; line-height: 1; color: var(--rd-accent-ink, ${accentInk}); background: var(--rd-accent, ${accent}); border-radius: 4px; vertical-align: middle; letter-spacing: .5px; }
  .rd-ai-note { font-size: 11px; color: #8F959E; display: inline-flex; align-items: center; gap: 6px; margin-top: 2px; }
  .rd-handoff-btn { border: 1px solid color-mix(in srgb, var(--rd-accent, ${accent}) 55%, #646A73); color: var(--rd-chip-ink, ${questionInk}); background: color-mix(in srgb, var(--rd-accent, ${accent}) 14%, #fff); border-radius: 999px; padding: 1px 10px; font-size: 11px; line-height: 1.6; cursor: pointer; }
  .rd-handoff-btn:hover { background: var(--rd-accent, ${accent}); color: var(--rd-accent-ink, ${accentInk}); }
.rd-bubble { padding: 9px 12px; border-color: #E5E8EF; border-radius: 4px 12px 12px; color: #1F2329; box-shadow: 0 1px 3px rgba(31,35,41,.02); }
.rd-row.is-mine .rd-bubble { background: var(--rd-accent, ${accent}); color: var(--rd-accent-ink, ${accentInk}); border-color: var(--rd-accent, ${accent}); border-radius: var(--rd-radius, 12px) var(--rd-radius-sm, 4px) var(--rd-radius, 12px) var(--rd-radius, 12px); }
.rd-bubble:has(.rd-image) { padding: 6px; border-radius: 12px; }
.rd-image { margin: 0; }
.rd-image img { border-radius: 8px; min-width: 120px; min-height: 90px; }
.rd-time { color: #8F959E; font-size: 11px; }
.rd-day, .rd-time-separator { align-self: center; color: #8F959E; font-size: 12px; margin: 2px 0; }
/* composer 的格局统一在基础层定义，这里只补浅色主题的占位色。 */
.rd-input::placeholder { color: #8F959E; }
/* iPhone 嵌入：父页 viewport-fit=cover 时 iframe 能读到 safe-area；宿主不垫顶，顶栏必须自己让出，否则与状态栏重叠。 */
.is-embedded .rd-header { position: relative; min-height: 56px; padding: calc(6px + env(safe-area-inset-top, 0px)) 12px 6px; }
.is-embedded .rd-header-main { margin: 0 auto; max-width: calc(100% - 88px); text-align: center; }
.is-embedded .rd-heading { align-items: center; }
.is-embedded .rd-heading strong { font-size: 18px; }
.is-embedded .rd-service-subtitle { display: block; }
.is-embedded .rd-subtitle { font-size: 11px; }
.is-embedded .rd-header-actions { position: absolute; right: 8px; top: calc(10px + env(safe-area-inset-top, 0px)); }
.is-embedded .rd-page-back { position: fixed; left: 8px; top: calc(10px + env(safe-area-inset-top, 0px)); }
.is-embedded .rd-back { display: none; }
.is-embedded .rd-body, .is-embedded .rd-messages { background: #F2F3F5; }
@media (max-width: 480px) {
  .rd-panel:not(.is-embedded) { bottom: 0; height: 100dvh; }
  .rd-panel:not(.is-embedded) .rd-header { min-height: 56px; }
  .rd-messages { padding: 12px; gap: 14px; }
}
` : ''}
/* 与坐席工作台统一的外观；企业主色、嵌入模式和全部功能继续由配置驱动。 */
.rd-panel { border-radius: 17px; border-color: ${light ? '#e9edf3' : '#303848'}; }
.rd-panel:not(.is-embedded) { width: 360px; }
.rd-header { background: ${accent}; color: ${accentInk}; padding: 22px 20px; border-bottom: 0; }
.rd-heading strong { color: ${accentInk}; font-size: 18px; }
.rd-subtitle, .rd-service-subtitle { color: ${accentInk}; font-size: 11px; opacity: .78; }
.rd-header-actions .rd-icon { color: ${accentInk}; background: transparent; }
.rd-header .rd-page-back { color: ${accentInk}; }
.rd-body, .rd-messages { background: ${light ? '#fafbfd' : '#171b24'}; }
.rd-messages { padding: 20px 16px; gap: 20px; }
.rd-empty { border-color: ${light ? '#e9edf3' : '#303848'}; box-shadow: none; padding: 16px; }
.rd-bubble { background: ${light ? '#ffffff' : '#2a2f38'}; padding: 12px 15px; border-color: ${light ? '#e9edf3' : '#303848'}; box-shadow: none; border-radius: 2px 10px 10px 10px; }
.rd-row.is-mine .rd-bubble { background: ${light ? accent + '12' : accent}; color: ${light ? '#202b3d' : '#fff'}; border-color: ${light ? accent + '20' : accent}; border-radius: 10px 2px 10px 10px; }
.rd-avatar.sm { border-radius: 10px; }
.is-embedded.rd-panel { border-radius: 0; }
/* composer（rd-composer / rd-composer-row / rd-input / rd-hold / rd-send）只在基础层定义，避免多处覆盖；配色仍由企业主色驱动。 */
@media (max-width: 480px) { .rd-panel:not(.is-embedded) { width: 100vw; border-radius: 0; } .rd-header { padding: 14px 16px; } }
`;
  }
}
