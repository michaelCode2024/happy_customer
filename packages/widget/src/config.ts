// Everything an embedding page can influence. The embed script turns data-*
// attributes and window.RelayDeskSettings into this shape, and a page that
// imports the module configures the element directly.

export interface RelayDeskWidgetOptions {
  /** Origin of the RelayDesk server, for example https://chat.example.com. */
  endpoint: string;
  /** Public key of the inbox the conversation belongs to. */
  inboxKey: string;
  /** Stable id for the visitor from the host application (user id, phone...). */
  externalId?: string;
  displayName?: string;
  email?: string;
  phone?: string;
  locale?: string;
  /** Extra attributes stored on the visitor, useful for segmentation. */
  attributes?: Record<string, unknown>;
  referrer?: string;
  /** Header text of the panel and the title of the launcher. */
  title?: string;
  subtitle?: string;
  welcomeMessage?: string;
  offlineMessage?: string;
  placeholder?: string;
  primaryColor?: string;
  /** 'right' | 'left' pins the launcher and the panel. */
  position?: 'right' | 'left';
  theme?: 'light' | 'dark';
  launcher?: 'bubble' | 'bar' | 'none';
  zIndex?: number;
  /** Open the panel as soon as the element connects. */
  autoOpen?: boolean;
  /** Pre-filled subject of the first conversation. */
  subject?: string;
  /** localStorage key prefix; set to '' to keep the session in memory only. */
  storage?: string;
  /** Skip the launcher and speak to the host page, for App WebView embeds. */
  embedded?: boolean;
  onEvent?: (event: WidgetEvent) => void;
  bridge?: WidgetBridge;
}

export interface WidgetEvent {
  type: 'ready' | 'open' | 'close' | 'message' | 'sent' | 'failed' | 'conversation' | 'rating' | 'unread' | 'error';
  data?: unknown;
}

/** Implemented by the host page so a WebView can react to widget state. */
export interface WidgetBridge {
  postMessage?: (payload: string) => void;
  onMessage?: (handler: (payload: string) => void) => void;
  /** Native clients can supply the visitor identity directly. */
  getVisitor?: () => { externalId?: string; displayName?: string; email?: string; phone?: string } | undefined;
}

export const DEFAULTS = {
  title: '在线客服',
  subtitle: '通常几分钟内回复',
  welcomeMessage: '',
  offlineMessage: '',
  placeholder: '请输入您的问题…',
  primaryColor: '#356ae6',
  position: 'right' as const,
  theme: 'light' as const,
  launcher: 'bubble' as const,
  zIndex: 2147483000,
  storage: 'relaydesk.widget',
  autoOpen: false,
  embedded: false,
};

export type ResolvedOptions = Omit<Required<RelayDeskWidgetOptions>, 'onEvent' | 'bridge' | 'attributes'> &
  Pick<RelayDeskWidgetOptions, 'onEvent' | 'bridge' | 'attributes'>;

/** Fills in every optional field so the rest of the code never re-checks. */
export function resolveOptions(input: RelayDeskWidgetOptions): ResolvedOptions {
  if (!input.endpoint) {
    throw new Error('RelayDesk: endpoint is required');
  }
  if (!input.inboxKey) {
    throw new Error('RelayDesk: inboxKey is required');
  }
  return {
    ...DEFAULTS,
    ...(input as RelayDeskWidgetOptions),
    endpoint: input.endpoint.replace(/\/+$/, ''),
    inboxKey: input.inboxKey,
  } as ResolvedOptions;
}
