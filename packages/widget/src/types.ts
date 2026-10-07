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
}

export interface Conversation {
  id: string;
  tenantId: string;
  inboxId: string;
  visitorId: string;
  subject?: string;
  status: ConversationStatus;
  assigneeId?: string;
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

export interface InboxInfo {
  id: string;
  name: string;
  welcomeMessage?: string;
  offlineMessage?: string;
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

export interface MessagePage {
  items: Message[] | null;
  lastSequence: number;
  hasMore: boolean;
}

export interface ConversationPage {
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
  };
}
