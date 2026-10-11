// Public entry point. Importing this module registers the element; loading it as
// a script on someone else's site additionally auto-mounts a widget when the
// script tag carries data-endpoint and data-inbox-key.

import { TAG_NAME, RelayDeskWidgetElement, optionsFromElement } from './widget.js';
import type { RelayDeskWidgetOptions, WidgetEvent, WidgetBridge } from './config.js';

export type { RelayDeskWidgetOptions, WidgetEvent, WidgetBridge } from './config.js';
export type { ChatMessage, Conversation, Message, SenderType, MessageType, ConversationStatus } from './types.js';
export { RelayDeskWidgetElement, optionsFromElement } from './widget.js';

interface RelayDeskGlobal {
  mount: (options: RelayDeskWidgetOptions) => RelayDeskWidgetElement;
  unmount: () => void;
  /** Present once a widget has been mounted. */
  readonly widget?: RelayDeskWidgetElement;
}

declare global {
  interface Window {
    RelayDesk?: RelayDeskGlobal;
    /** Optional configuration object, read before the script attributes. */
    RelayDeskSettings?: RelayDeskWidgetOptions;
  }
}

if (typeof window !== 'undefined' && !customElements.get(TAG_NAME)) {
  customElements.define(TAG_NAME, RelayDeskWidgetElement);
}

let mounted: RelayDeskWidgetElement | undefined;

function mount(options: RelayDeskWidgetOptions): RelayDeskWidgetElement {
  if (mounted?.isConnected) {
    mounted.configure(options);
    return mounted;
  }
  const element = document.createElement(TAG_NAME) as RelayDeskWidgetElement;
  // configure() before insertion, so the first paint already has data and the
  // panel never flashes an empty shell.
  element.configure(options);
  document.body.appendChild(element);
  mounted = element;
  return element;
}

function unmount(): void {
  mounted?.remove();
  mounted = undefined;
}

if (typeof window !== 'undefined') {
  const api: RelayDeskGlobal = {
    mount,
    unmount,
    get widget() {
      return mounted;
    },
  };
  window.RelayDesk = api;

  // Auto-mount: prefer an explicit window.RelayDeskSettings (a CMS or a tag
  // manager usually sets that), then fall back to the loading script's own
  // data-* attributes.
  const boot = (): void => {
    const settings = window.RelayDeskSettings;
    if (settings?.endpoint && settings.inboxKey) {
      api.mount(settings);
      return;
    }
    const script = document.currentScript as HTMLScriptElement | null;
    // The script tag that loaded us is the usual source, but a tag manager may
    // inject us without currentScript, so any matching tag is accepted.
    const candidates: HTMLScriptElement[] = script
      ? [script, ...document.querySelectorAll<HTMLScriptElement>('script[data-inbox-key]')]
      : Array.from(document.querySelectorAll<HTMLScriptElement>('script[data-inbox-key]'));
    for (const candidate of candidates) {
      const options = optionsFromScript(candidate);
      if (options) {
        api.mount(options);
        return;
      }
    }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }
}

/** Reads the widgets configuration straight off a <script> tag. */
function optionsFromScript(script: HTMLScriptElement): RelayDeskWidgetOptions | undefined {
  const endpoint = script.dataset.endpoint;
  const inboxKey = script.dataset.inboxKey;
  if (!endpoint || !inboxKey) {
    return undefined;
  }
  const options: RelayDeskWidgetOptions = { endpoint, inboxKey };
  if (script.dataset.title) {
    options.title = script.dataset.title;
  }
  if (script.dataset.primaryColor) {
    options.primaryColor = script.dataset.primaryColor;
  }
  if (script.dataset.position === 'left' || script.dataset.position === 'right') {
    options.position = script.dataset.position;
  }
  if (script.dataset.launcher === 'bubble' || script.dataset.launcher === 'bar' || script.dataset.launcher === 'none') {
    options.launcher = script.dataset.launcher;
  }
  if (script.dataset.autoOpen === 'true') {
    options.autoOpen = true;
  }
  if (script.dataset.embedded === 'true') {
    options.embedded = true;
  }
  if (script.dataset.theme === 'light' || script.dataset.theme === 'dark') {
    options.theme = script.dataset.theme;
  }
  if (script.dataset.parentOrigin) {
    options.parentOrigin = script.dataset.parentOrigin;
  }
  if (script.dataset.externalId) {
    options.externalId = script.dataset.externalId;
  }
  if (script.dataset.identityToken) options.identityToken = script.dataset.identityToken;
  if (script.dataset.displayName) {
    options.displayName = script.dataset.displayName;
  }
  if (script.dataset.storage !== undefined) {
    options.storage = script.dataset.storage;
  }
  return options;
}

export { mount, unmount };
