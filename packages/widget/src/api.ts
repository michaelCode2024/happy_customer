// Typed REST client for the visitor API. Every call returns parsed JSON or
// throws ApiError, so callers can tell an expired token (401) from a genuinely
// missing conversation (404).

import type {
  BootstrapResult,
  Conversation,
  ConversationPage,
  Message,
  MessagePage,
  MessageType,
  SearchHit,
} from './types.js';

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
  }

  /** True when the visitor token is gone and a fresh bootstrap is required. */
  get isAuthError(): boolean {
    return this.status === 401;
  }
}

export interface BootstrapInput {
  inboxKey: string;
  identityToken?: string;
  externalId?: string;
  displayName?: string;
  email?: string;
  phone?: string;
  locale?: string;
  attributes?: Record<string, unknown>;
  referrer?: string;
}

export interface SendInput {
  content: string;
  clientMessageId: string;
  messageType: MessageType;
  attachmentIds?: string[];
  /** Quotes an earlier message in this conversation. */
  replyToId?: string;
  metadata?: Record<string, unknown>;
}

export class VisitorApi {
  readonly #endpoint: string;
  #token = '';

  constructor(endpoint: string) {
    this.#endpoint = endpoint;
  }

  get token(): string {
    return this.#token;
  }

  setToken(token: string): void {
    this.#token = token;
  }

  /** Absolute URL of a stored file, carrying the token so <img> can load it. */
  fileUrl(url: string): string {
    if (!url) {
      return '';
    }
    // The server returns an absolute URL (PUBLIC_BASE_URL + path), but an
    // older or proxied deployment may return a path, so both are accepted.
    const absolute = /^https?:\/\//.test(url) ? url : this.#endpoint + url;
    const separator = absolute.includes('?') ? '&' : '?';
    return `${absolute}${separator}token=${encodeURIComponent(this.#token)}`;
  }

  bootstrap(input: BootstrapInput): Promise<BootstrapResult> {
    return this.#json<BootstrapResult>('POST', '/api/v1/widget/bootstrap', input, false);
  }

  createConversation(subject: string, content: string, source: string): Promise<{ conversation: Conversation; message?: Message }> {
    const body: Record<string, unknown> = { subject, source };
    if (content.trim()) {
      body.content = content;
    }
    return this.#json('POST', '/api/v1/widget/conversations', body);
  }

  listConversations(): Promise<ConversationPage> {
    return this.#json('GET', '/api/v1/widget/conversations');
  }

  getConversation(id: string): Promise<Conversation> {
    return this.#json('GET', `/api/v1/widget/conversations/${id}`);
  }

  listMessages(id: string, after = 0, limit = 50): Promise<MessagePage> {
    return this.#json('GET', `/api/v1/widget/conversations/${id}/messages?after=${after}&limit=${limit}`);
  }

  /**
   * Reads one page in a given direction. `before` walks back through history;
   * `after` walks forward, either to catch up after a dropped socket or to pull
   * the tail on first load.
   */
  pageMessages(id: string, options: { after?: number; before?: number; limit?: number }): Promise<MessagePage> {
    const params = new URLSearchParams();
    if (options.after) {
      params.set('after', String(options.after));
    }
    if (options.before) {
      params.set('before', String(options.before));
    }
    params.set('limit', String(options.limit ?? 50));
    return this.#json('GET', `/api/v1/widget/conversations/${id}/messages?${params.toString()}`);
  }

  search(id: string, query: string, limit = 20): Promise<{ items: SearchHit[] | null }> {
    const params = new URLSearchParams({ q: query, limit: String(limit) });
    return this.#json('GET', `/api/v1/widget/conversations/${id}/search?${params.toString()}`);
  }

  sendMessage(id: string, input: SendInput): Promise<Message> {
    return this.#json('POST', `/api/v1/widget/conversations/${id}/messages`, input);
  }

  markRead(id: string, sequence: number): Promise<unknown> {
    return this.#json('POST', `/api/v1/widget/conversations/${id}/read`, { sequence });
  }

  /**
   * Reports the highest server sequence the visitor's device has actually
   * received. This is not the same as read: a chat window can be open on a
   * background tab, so the receipt lets the agent see "delivered" before the
   * visitor has looked at it.
   */
  markDelivered(id: string, sequence: number): Promise<unknown> {
    return this.#json('POST', `/api/v1/widget/conversations/${id}/delivered`, { sequence });
  }

  typing(id: string): Promise<unknown> {
    return this.#json('POST', `/api/v1/widget/conversations/${id}/typing`, {});
  }

  rate(id: string, score: number, comment: string): Promise<unknown> {
    return this.#json('POST', `/api/v1/widget/conversations/${id}/rating`, { score, comment });
  }

  /** Visitor-initiated handoff: asks a human agent to take over an AI reply. */
  requestHandoff(id: string): Promise<unknown> {
    return this.#json('POST', `/api/v1/widget/conversations/${id}/handoff`, {});
  }

  /**
   * Uploads one file against a conversation. XMLHttpRequest rather than fetch:
   * upload progress matters for a phone photo on a slow connection, and fetch
   * still cannot report it.
   */
  upload(conversationId: string, file: File, onProgress?: (percent: number) => void): Promise<{ id: string; fileName: string; contentType: string; sizeBytes: number; url: string }> {
    return new Promise((resolve, reject) => {
      const form = new FormData();
      form.append('file', file, file.name);
      const request = new XMLHttpRequest();
      request.open('POST', `${this.#endpoint}/api/v1/uploads?conversationId=${encodeURIComponent(conversationId)}`);
      request.setRequestHeader('Authorization', `Bearer ${this.#token}`);
      request.upload.addEventListener('progress', (event) => {
        if (event.lengthComputable && onProgress) {
          onProgress(Math.round((event.loaded / event.total) * 100));
        }
      });
      request.addEventListener('load', () => {
        let parsed: unknown = undefined;
        try {
          parsed = JSON.parse(request.responseText);
        } catch {
          parsed = undefined;
        }
        if (request.status >= 200 && request.status < 300 && parsed) {
          resolve(parsed as { id: string; fileName: string; contentType: string; sizeBytes: number; url: string });
          return;
        }
        const error = parsed as { code?: string; message?: string } | undefined;
        reject(new ApiError(request.status, error?.code ?? 'UPLOAD_FAILED', error?.message ?? '上传失败'));
      });
      request.addEventListener('error', () => reject(new ApiError(0, 'NETWORK_ERROR', '网络异常，上传失败')));
      request.addEventListener('abort', () => reject(new ApiError(0, 'ABORTED', '上传已取消')));
      request.send(form);
    });
  }

  async #json<T>(method: string, path: string, body?: unknown, authorized = true): Promise<T> {
    const headers: Record<string, string> = {};
    if (authorized && this.#token) {
      headers['Authorization'] = `Bearer ${this.#token}`;
    }
    const init: RequestInit = { method, headers };
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json; charset=utf-8';
      init.body = JSON.stringify(body);
    }
    let response: Response;
    try {
      response = await fetch(this.#endpoint + path, init);
    } catch {
      throw new ApiError(0, 'NETWORK_ERROR', '网络异常，请检查网络后重试');
    }
    const text = await response.text();
    let parsed: unknown = undefined;
    if (text) {
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = undefined;
      }
    }
    if (!response.ok) {
      const payload = parsed as { code?: string; message?: string } | undefined;
      throw new ApiError(response.status, payload?.code ?? 'HTTP_' + response.status, payload?.message ?? '请求失败');
    }
    return parsed as T;
  }
}
