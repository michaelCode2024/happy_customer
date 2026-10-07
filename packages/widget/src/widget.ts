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
    this.#view = new WidgetView(this.attachShadow({ mode: 'open' }), resolved, this.#store, {
      onToggle: () => this.toggle(),
      onClose: () => this.close(),
      onSend: (text) => void this.#store?.send(text),
      onFiles: (files) => void this.#store?.sendFiles(files),
      onRetry: (localId) => void this.#store?.retry(localId),
      onSelectConversation: (id) => void this.#store?.selectConversation(id),
      onBack: () => this.#backToList(),
      onRate: (score) => void this.#store?.rate(score),
      onTyping: () => this.#store?.notifyTyping(),
    });
    this.#unsubscribe = this.#store.subscribe((snapshot) => this.#view?.render(snapshot));
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
   * Bridges the widget to a native WebView: events go out as JSON strings and
   * the host can push commands back in on window.RelayDesk.
   */
  #bridge(): void {
    const bridge = this.#options?.bridge;
    if (bridge?.onMessage) {
      bridge.onMessage((payload) => {
        let parsed: { type?: string; content?: string } = {};
        try {
          parsed = JSON.parse(payload) as { type?: string; content?: string };
        } catch {
          return;
        }
        switch (parsed.type) {
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
      });
    }
  }

  #teardown(): void {
    this.#unsubscribe?.();
    this.#unsubscribe = undefined;
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
    ['subject', 'subject'],
    ['storage', 'storage'],
  ];
  for (const [attribute, key] of mapping) {
    const value = element.getAttribute(attribute);
    if (value !== null) {
      (options as unknown as Record<string, unknown>)[key] = value;
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
