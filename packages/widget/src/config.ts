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
  /** 客户后端签发的短期身份票据，API Key 不得传到客户端。 */
  identityToken?: string;
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
  /** Brand image shown in the launcher and panel header (overrides the icon). */
  logoUrl?: string;
  /** Brand image used as the agent avatar in the thread and welcome screen. */
  avatarUrl?: string;
  /** Raw CSS injected into the widget's shadow root; scoped to the widget only. */
  customCss?: string;
  /** Font family for the panel; falls back to the system stack when empty. */
  fontFamily?: string;
  /** Bubble corner radius in pixels (default 12). */
  bubbleRadius?: number;
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
  /** 会话来源用于渠道统计，H5 页面默认 H5，App WebView 可指定 APP。 */
  source?: "WEB" | "H5" | "APP" | "PC";
  /**
   * Target origin for window.parent.postMessage when the widget runs inside an
   * iframe. Defaults to '*' so a host product can listen without pre-sharing
   * origins; tighten this in production (e.g. https://app.example.com).
   */
  parentOrigin?: string;
  onEvent?: (event: WidgetEvent) => void;
  bridge?: WidgetBridge;
}

export interface WidgetEvent {
  type:
    | 'ready'
    | 'open'
    | 'close'
    | 'message'
    | 'sent'
    | 'failed'
    | 'conversation'
    | 'rating'
    | 'unread'
    | 'error'
    | 'resize'
    | 'message-updated';
  data?: unknown;
}

/** Implemented by the host page so a WebView can react to widget state. */
export interface WidgetBridge {
  postMessage?: (payload: string) => void;
  onMessage?: (handler: (payload: string) => void) => void;
  /** Native clients can supply the visitor identity directly. */
  getVisitor?: () => { externalId?: string; identityToken?: string; displayName?: string; email?: string; phone?: string } | undefined;
}

export const DEFAULTS = {
  title: '语聊客服',
  subtitle: '语聊为您服务',
  welcomeMessage: '',
  offlineMessage: '',
  placeholder: '请输入消息…',
  // 默认使用语聊品牌蓝；接入企业可覆盖，不改已有自定义主题。
  primaryColor: '#4263EB',
  logoUrl: '',
  avatarUrl: '',
  customCss: '',
  fontFamily: '',
  bubbleRadius: 12,
  position: 'right' as const,
  theme: 'light' as const,
  launcher: 'bubble' as const,
  zIndex: 2147483000,
  storage: 'relaydesk.widget',
  autoOpen: false,
  embedded: false,
  parentOrigin: '*',
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
