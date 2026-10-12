// Wire types shared with the Go backend. The visitor API, the agent console and
// the open API all return these same shapes, so anything added here has to stay
// compatible with `messageView` and `conversationView` in internal/server.

export type SenderType = 'VISITOR' | 'AGENT' | 'SYSTEM';

export type MessageType = 'TEXT' | 'IMAGE' | 'FILE' | 'AUDIO' | 'VIDEO' | 'CARD';

export type ConversationStatus = 'OPEN' | 'PENDING' | 'RESOLVED';

export type ConversationSource = 'WEB' | 'H5' | 'APP' | 'PC' | 'API';

export interface Attachment {
  id: string;
  fileName: string;
  contentType: string;
  sizeBytes: number;
  url: string;
}

// One aggregated reaction. The server groups by emoji and lists the actors, so a
// client can render a count without fetching every reaction row.
export interface Reaction {
  emoji: string;
  count: number;
  actors: string[];
  mine?: boolean;
}

export interface Message {
  id: string;
  conversationId: string;
  senderType: SenderType;
  senderId?: string;
  senderName?: string;
  clientMessageId?: string;
  sequence: number;
  messageType: MessageType;
  content: string;
  metadata?: Record<string, unknown>;
  attachments?: Attachment[];
  createdAt: string;
  // Set when the message quotes an earlier one. The quoted body travels with
  // the message so the widget can render the quote without holding the whole
  // thread in memory.
  replyToId?: string;
  replyTo?: QuotedMessage;
  editedAt?: string;
  // A recalled message keeps its row so sequence numbers stay gapless, but its
  // content is stripped before it leaves the server. The client renders a
  // tombstone from this timestamp alone.
  deletedAt?: string;
  pinnedAt?: string;
  forwardedFromId?: string;
  reactions?: Reaction[] | null;
  // Internal notes are never sent to a visitor socket; the field exists here so
  // the same shape can describe an agent's view in tests and tooling.
  private?: boolean;
}

// The quoted excerpt attached to a reply. It is a snapshot rather than a
// reference, because the original may be edited or recalled after the reply was
// written and the quote should keep showing what was actually answered.
export interface QuotedMessage {
  id: string;
  sequence: number;
  senderType: SenderType;
  senderName?: string;
  messageType: MessageType;
  content: string;
  deletedAt?: string;
}

export interface Conversation {
  id: string;
  tenantId: string;
  inboxId: string;
  visitorId: string;
  subject?: string;
  status: ConversationStatus;
  assigneeId?: string;
  acceptedAt?: string;
  assignmentExpiresAt?: string;
  assigneeName?: string;
  priority: number;
  source: ConversationSource;
  lastSequence: number;
  lastMessagePreview?: string;
  lastMessageAt?: string;
  agentUnread: number;
  visitorUnread: number;
  visitorName?: string;
  tags?: string[];
  createdAt: string;
  updatedAt: string;
}

export interface ChannelItem { id: string; title: string; description?: string; imageUrl?: string; action: "REPLY" | "LINK" | "HANDOFF"; value: string; }
export interface ChannelPresentation { channelTitle?: string; channelSubtitle?: string; openReply?: string; guideText?: string; guideQuestions?: string[]; diversionLinks?: ChannelItem[]; menuItems?: ChannelItem[]; quickLinks?: ChannelItem[]; cards?: ChannelItem[]; }

export interface InboxInfo {
 automation?: ChannelPresentation;
  id: string;
  name: string;
  welcomeMessage?: string;
  offlineMessage?: string;
  // Server-side white-label branding delivered on bootstrap.
  logoUrl?: string;
  avatarUrl?: string;
  fontFamily?: string;
  bubbleRadius?: number;
  customCss?: string;
}

export interface BootstrapResult {
  visitorId: string;
  displayName?: string;
  token: string;
  expiresIn: number;
  inbox: InboxInfo;
  aiEnabled: boolean;
  agentsOnline: number;
  openConversations: number;
  serverTime: string;
}

// A page of history. Reading upward and reading downward are different
// questions, so the server answers both with the same shape: hasMore says there
// is more in the direction asked for, hasOlder says the top of the thread is
// still above what was returned. A client can therefore offer "load earlier"
// without guessing whether it just reached the beginning of the conversation.
export interface MessagePage {
  items: Message[] | null;
  hasMore: boolean;
  hasOlder: boolean;
  firstSequence: number;
  lastSequence: number;
  // Only the widget's page carries these: a visitor sees one thread, so its
  // unread count is a property of the page rather than of a conversation list.
  visitorUnread?: number;
  /** 坐席已读水位：访客气泡「已读」依赖它。 */
  agentLastReadSequence?: number;
  /** 坐席已送达水位：访客气泡「已送达」依赖它。 */
  agentLastDeliveredSequence?: number;
}

// A search hit. The excerpt carries << >> around the matched terms, which the
// widget renders as a highlight; the server builds it because the database's
// ts_headline cannot segment Chinese.
export interface SearchHit {
  messageId: string;
  conversationId: string;
  sequence: number;
  content: string;
  excerpt: string;
  rank: number;
  createdAt: string;
  messageType: MessageType;
  senderType: SenderType;
  senderName?: string;
}

export interface ConversationPage {
 automation?: ChannelPresentation;
  agentsOnline?: number;
  aiEnabled?: boolean;
  welcomeMessage?: string;
  offlineMessage?: string;
  items: Conversation[] | null;
}

export interface RealtimeEvent {
  type: string;
  tenantId?: string;
  conversationId?: string;
  data?: unknown;
  meta?: Record<string, unknown>;
}

// Delivery state is a client-side concept only: the server knows nothing about
// a message until it accepts it.
export type DeliveryState = 'SENDING' | 'SENT' | 'FAILED';

export interface ChatMessage {
  // The server id once known; the local id until then.
  id: string;
  localId: string;
  conversationId: string;
  senderType: SenderType;
  senderName?: string;
  sequence: number;
  messageType: MessageType;
  content: string;
  attachments: Attachment[];
  createdAt: string;
  delivery: DeliveryState;
  error?: string;
  // Present once the server has accepted the message, so a retry can be
  // correlated with the original send rather than creating a duplicate.
  clientMessageId?: string;
  replyTo?: QuotedMessage;
  editedAt?: string;
  deletedAt?: string;
  pinnedAt?: string;
  forwardedFromId?: string;
  reactions: Reaction[];
  // Round-tripped so a retry can re-send a voice note's duration, which the
  // player needs before the audio element has loaded enough to report it.
  metadata?: Record<string, unknown>;
}

export interface TypingState {
  actorType: 'AGENT' | 'VISITOR';
  actorName?: string;
  at: number;
}

export function toChatMessage(message: Message): ChatMessage {
  return {
    id: message.id,
    localId: message.id,
    conversationId: message.conversationId,
    senderType: message.senderType,
    senderName: message.senderName,
    sequence: message.sequence,
    messageType: message.messageType,
    content: message.content,
    attachments: message.attachments ?? [],
    createdAt: message.createdAt,
    delivery: 'SENT',
    clientMessageId: message.clientMessageId,
    replyTo: message.replyTo,
    editedAt: message.editedAt,
    deletedAt: message.deletedAt,
    pinnedAt: message.pinnedAt,
    forwardedFromId: message.forwardedFromId,
    reactions: message.reactions ?? [],
    metadata: message.metadata,
  };
}
