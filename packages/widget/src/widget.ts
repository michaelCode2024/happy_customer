// The custom element. It is deliberately thin: it owns the shadow root, listens
// to the store and forwards user intent, so all state lives in one place.

import { resolveOptions, type RelayDeskWidgetOptions, type ResolvedOptions } from './config.js';
import { ChatStore, type Snapshot } from './store.js';
import { WidgetView } from './ui.js';

export const TAG_NAME = 'relaydesk-widget';

export class RelayDeskWidgetElement extends HTMLElement {
  #store?: ChatStore;
  #view?: WidgetView;
  #options?: ResolvedOptions;
  #unsubscribe?: () => void;
  #pending?: RelayDeskWidgetOptions;
  #parentListener?: (event: MessageEvent) => void;
  #resizeObserver?: ResizeObserver;

  static get observedAttributes(): string[] {
    return ['inbox-key', 'endpoint', 'auto-open'];
  }

  /** Public API for pages that import the module rather than the embed script. */
  get widget(): RelayDeskWidgetElement {
    return this;
  }

  configure(options: RelayDeskWidgetOptions): void {
    if (this.#store) {
      this.#teardown();
    }
    const resolved = resolveOptions(options);
    this.#options = resolved;
    this.#store = new ChatStore(resolved);
    this.#view = new WidgetView(this.shadowRoot ?? this.attachShadow({ mode: 'open' }), resolved, this.#store, {
      onToggle: () => this.toggle(),
      onClose: () => this.close(),
      onSend: (text) => void this.#store?.send(text),
      onFiles: (files) => void this.#store?.sendFiles(files),
      onRetry: (localId) => void this.#store?.retry(localId),
      onSelectConversation: (id) => void this.#store?.selectConversation(id),
      onBack: () => this.#backToList(),
      onRate: (score) => void this.#store?.rate(score),
      onTyping: () => this.#store?.notifyTyping(),
      onQuote: (messageId) => this.#quote(messageId),
      onHandoff: (messageId) => void this.#store?.requestHandoff(messageId),
      onClearQuote: () => this.#store?.clearQuote(),
      onSearch: (query) => void this.#store?.search(query),
      onClearSearch: () => this.#store?.clearSearch(),
      onVoice: (blob, durationMs) => void this.#store?.sendVoice(blob, durationMs),
      onLoadOlder: () => void this.#store?.loadOlder(),
    });
    this.#unsubscribe = this.#store.subscribe((snapshot) => this.#view?.render(snapshot));
    // Server-side white-label branding (logo, avatar, font, CSS) arrives from
    // bootstrap after init; re-brand the view when it does.
    this.#store.onWhiteLabel = (whitelabel) => this.#view?.applyWhiteLabel(whitelabel);
    this.#bridge();
    if (resolved.autoOpen) {
      this.open();
    }
  }

  connectedCallback(): void {
    if (this.#store) {
      return;
    }
    if (this.#pending) {
      this.configure(this.#pending);
      this.#pending = undefined;
      return;
    }
    const fromAttributes = optionsFromElement(this);
    if (fromAttributes) {
      this.configure(fromAttributes);
    }
  }

  disconnectedCallback(): void {
    // Keep the session: pages move the element around (route changes, modals).
    this.#store?.close();
  }

  attributeChangedCallback(name: string, _previous: string | null, value: string | null): void {
    if (name === 'auto-open' && value !== null && value !== 'false' && this.#store) {
      this.open();
    }
  }

  open(): void {
    if (!this.#store) {
      this.#pending = { ...(this.#pending ?? (optionsFromElement(this) as RelayDeskWidgetOptions)) };
      this.connectedCallback();
      if (!this.#store) {
        return;
      }
    }
    this.#store.open();
    this.#view?.focusInput();
  }

  close(): void {
    this.#store?.close();
  }

  toggle(): void {
    this.#store?.toggle();
  }

  /** Sends a message on behalf of the host page (CSP-safe, no DOM poking). */
  async say(content: string): Promise<void> {
    await this.#store?.send(content);
  }

  /** Pre-fills the composer without sending. */
  prefill(content: string): void {
    this.#view?.setInputValue(content);
    this.#view?.focusInput();
  }

  get state(): Snapshot | undefined {
    return this.#store?.snapshot;
  }

  /** Quotes a message in this thread, so the next send is a reply to it. */
  #quote(messageId: string): void {
    const store = this.#store;
    if (!store) {
      return;
    }
    const target = store.snapshot.messages.find((message) => message.id === messageId);
    if (!target || target.deletedAt) {
      return;
    }
    store.quote(target);
    this.#view?.focusInput();
  }

  #backToList(): void {
    // Clearing the active conversation brings the picker back, which the view
    // derives from state rather than from a separate flag.
    const store = this.#store;
    if (!store) {
      return;
    }
    if (store.snapshot.conversations.length <= 1) {
      return;
    }
    store.clearActive();
  }

  /**
   * Bridges the widget to a native WebView and/or a parent iframe host.
   * Outbound events are JSON with { source: 'relaydesk', type, data }.
   */
  #bridge(): void {
    const bridge = this.#options?.bridge;
    if (bridge?.onMessage) {
      bridge.onMessage((payload) => this.#handleHostCommand(payload));
    }
    // iframe 宿主：默认走 parent.postMessage，方便业务系统嵌 /h5 而不注入 bridge。
    if (typeof window !== 'undefined' && window.parent && window.parent !== window) {
      this.#parentListener = (event: MessageEvent) => {
        if (event.source !== window.parent) {
          return;
        }
        const expected = this.#options?.parentOrigin ?? '*';
        if (expected !== '*' && event.origin !== expected) {
          return;
        }
        if (typeof event.data === 'string') {
          this.#handleHostCommand(event.data);
          return;
        }
        if (event.data && typeof event.data === 'object') {
          this.#handleHostCommand(JSON.stringify(event.data));
        }
      };
      window.addEventListener('message', this.#parentListener);
      if (typeof ResizeObserver !== 'undefined') {
        this.#resizeObserver = new ResizeObserver(() => {
          const height = Math.ceil(document.documentElement?.scrollHeight || document.body?.scrollHeight || 0);
          this.#store?.emitHost({ type: 'resize', data: { height } });
        });
        this.#resizeObserver.observe(document.documentElement);
      }
    }
  }

  #handleHostCommand(payload: string): void {
    let parsed: { type?: string; content?: string; source?: string; identityToken?: string } = {};
    try {
      parsed = typeof payload === 'string'
        ? JSON.parse(payload)
        : payload;
    } catch {
      return;
    }
    // 只接受宿主指令；忽略我们自己 postMessage 出去的业务事件。
    if (parsed.source === 'relaydesk' && !['open', 'close', 'say', 'prefill'].includes(parsed.type ?? '')) {
      return;
    }
    switch (parsed.type) {
      case 'authenticate':
        // 身份票据通过指定来源宿主传入，不进入 URL、浏览器历史或引荐日志。
        if (typeof parsed.identityToken === 'string' && parsed.identityToken && this.#options?.parentOrigin && this.#options.parentOrigin !== '*') {
          this.configure({ ...this.#options, externalId: undefined, identityToken: parsed.identityToken, autoOpen: true });
        }
        break;
      case 'open':
        this.open();
        break;
      case 'close':
        this.close();
        break;
      case 'say':
        if (parsed.content) {
          void this.say(parsed.content);
        }
        break;
      case 'prefill':
        if (parsed.content) {
          this.prefill(parsed.content);
        }
        break;
      default:
        break;
    }
  }

  #teardown(): void {
    this.#unsubscribe?.();
    this.#unsubscribe = undefined;
    if (this.#parentListener) {
      window.removeEventListener('message', this.#parentListener);
      this.#parentListener = undefined;
    }
    this.#resizeObserver?.disconnect();
    this.#resizeObserver = undefined;
    this.#store?.destroy();
    this.#store = undefined;
    this.#view = undefined;
  }
}

/** Builds options from the element's attributes, or undefined when unset. */
export function optionsFromElement(element: HTMLElement): RelayDeskWidgetOptions | undefined {
  const endpoint = element.getAttribute('endpoint') ?? (typeof window !== 'undefined' ? (window as never as Record<string, string>)['RELAYDESK_ENDPOINT'] : undefined);
  const inboxKey = element.getAttribute('inbox-key');
  if (!endpoint || !inboxKey) {
    return undefined;
  }
  const attributes = element.getAttribute('attributes');
  let parsedAttributes: Record<string, unknown> | undefined;
  if (attributes) {
    try {
      parsedAttributes = JSON.parse(attributes) as Record<string, unknown>;
    } catch {
      parsedAttributes = undefined;
    }
  }
  const options: RelayDeskWidgetOptions = {
    endpoint,
    inboxKey,
    attributes: parsedAttributes,
  };
  const mapping: Array<[string, keyof RelayDeskWidgetOptions]> = [
    ['external-id', 'externalId'],
    ['identity-token', 'identityToken'],
    ['display-name', 'displayName'],
    ['email', 'email'],
    ['phone', 'phone'],
    ['locale', 'locale'],
    ['title', 'title'],
    ['subtitle', 'subtitle'],
    ['welcome-message', 'welcomeMessage'],
    ['offline-message', 'offlineMessage'],
    ['placeholder', 'placeholder'],
    ['primary-color', 'primaryColor'],
    ['logo-url', 'logoUrl'],
    ['avatar-url', 'avatarUrl'],
    ['custom-css', 'customCss'],
    ['font-family', 'fontFamily'],
    ['subject', 'subject'],
    ['storage', 'storage'],
  ];
  for (const [attribute, key] of mapping) {
    const value = element.getAttribute(attribute);
    if (value !== null) {
      (options as unknown as Record<string, unknown>)[key] = value;
    }
  }
  const bubbleRadius = element.getAttribute('bubble-radius');
  if (bubbleRadius !== null) {
    const r = Number(bubbleRadius);
    if (Number.isFinite(r) && r >= 0) {
      options.bubbleRadius = r;
    }
  }
  const position = element.getAttribute('position');
  if (position === 'left' || position === 'right') {
    options.position = position;
  }
  const theme = element.getAttribute('theme');
  if (theme === 'light' || theme === 'dark') {
    options.theme = theme;
  }
  const launcher = element.getAttribute('launcher');
  if (launcher === 'bubble' || launcher === 'bar' || launcher === 'none') {
    options.launcher = launcher;
  }
  const embedded = element.getAttribute('embedded');
  if (embedded !== null) {
    options.embedded = embedded !== 'false';
  }
  const autoOpen = element.getAttribute('auto-open');
  if (autoOpen !== null) {
    options.autoOpen = autoOpen !== 'false';
  }
  const zIndex = Number(element.getAttribute('z-index'));
  if (Number.isFinite(zIndex) && zIndex > 0) {
    options.zIndex = zIndex;
  }
  return options;
}
