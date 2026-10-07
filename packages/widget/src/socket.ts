// WebSocket transport. Sockets are a convenience channel: a dropped connection
// never loses data, because REST is the source of truth and the store refills
// from it on every reconnect.

import type { RealtimeEvent } from './types.js';

const HEARTBEAT_MS = 25_000;
const BACKOFF_MS = [1_000, 2_000, 5_000, 10_000, 20_000, 30_000];

export type SocketStatus = 'CONNECTING' | 'OPEN' | 'CLOSED';

export interface SocketHandlers {
  onEvent: (event: RealtimeEvent) => void;
  onStatus: (status: SocketStatus) => void;
  /** Called after a reconnect so the store can pull whatever it missed. */
  onReconnect: () => void;
  getToken: () => string;
}

function socketUrl(endpoint: string, token: string): string {
  const base = endpoint.replace(/^http/, 'ws');
  return `${base}/ws/widget?token=${encodeURIComponent(token)}`;
}

export class VisitorSocket {
  readonly #endpoint: string;
  readonly #handlers: SocketHandlers;
  #socket?: WebSocket;
  #heartbeat?: ReturnType<typeof setInterval>;
  #retry?: ReturnType<typeof setTimeout>;
  #attempt = 0;
  #closed = false;
  #everOpen = false;

  constructor(endpoint: string, handlers: SocketHandlers) {
    this.#endpoint = endpoint;
    this.#handlers = handlers;
  }

  get connected(): boolean {
    return this.#socket?.readyState === WebSocket.OPEN;
  }

  connect(): void {
    this.#closed = false;
    this.#open();
  }

  close(): void {
    this.#closed = true;
    this.#clearTimers();
    if (this.#socket) {
      this.#socket.onclose = null;
      this.#socket.onmessage = null;
      this.#socket.onerror = null;
      this.#socket.close();
      this.#socket = undefined;
    }
    this.#attempt = 0;
    this.#handlers.onStatus('CLOSED');
  }

  /** Joins the conversation stream; the visitor channel is always subscribed. */
  subscribe(conversationId: string): void {
    this.#send({ type: 'subscribe', conversationId });
  }

  unsubscribe(conversationId: string): void {
    this.#send({ type: 'unsubscribe', conversationId });
  }

  sendTyping(conversationId: string): void {
    this.#send({ type: 'typing', conversationId });
  }

  sendRead(conversationId: string): void {
    this.#send({ type: 'read', conversationId });
  }

  #send(frame: Record<string, string>): void {
    if (this.#socket?.readyState === WebSocket.OPEN) {
      this.#socket.send(JSON.stringify(frame));
    }
  }

  #open(): void {
    const token = this.#handlers.getToken();
    if (!token) {
      return;
    }
    this.#handlers.onStatus('CONNECTING');
    let socket: WebSocket;
    try {
      socket = new WebSocket(socketUrl(this.#endpoint, token));
    } catch {
      this.#scheduleRetry();
      return;
    }
    this.#socket = socket;

    socket.onopen = () => {
      this.#attempt = 0;
      this.#handlers.onStatus('OPEN');
      if (this.#everOpen) {
        this.#handlers.onReconnect();
      }
      this.#everOpen = true;
      this.#heartbeat = setInterval(() => this.#send({ type: 'ping' }), HEARTBEAT_MS);
    };

    socket.onmessage = (event: MessageEvent<string>) => {
      let parsed: RealtimeEvent;
      try {
        parsed = JSON.parse(event.data) as RealtimeEvent;
      } catch {
        return;
      }
      if (parsed.type === 'pong') {
        return;
      }
      this.#handlers.onEvent(parsed);
    };

    socket.onclose = () => {
      this.#clearTimers();
      if (this.#closed) {
        return;
      }
      this.#handlers.onStatus('CLOSED');
      this.#scheduleRetry();
    };

    socket.onerror = () => {
      // onclose always follows, which is where the retry is scheduled.
    };
  }

  #scheduleRetry(): void {
    if (this.#retry) {
      return;
    }
    const index = Math.min(this.#attempt, BACKOFF_MS.length - 1);
    const delay = BACKOFF_MS[index] ?? 30_000;
    this.#attempt += 1;
    this.#retry = setTimeout(() => {
      this.#retry = undefined;
      if (!this.#closed) {
        this.#open();
      }
    }, delay);
  }

  #clearTimers(): void {
    if (this.#heartbeat) {
      clearInterval(this.#heartbeat);
      this.#heartbeat = undefined;
    }
    if (this.#retry) {
      clearTimeout(this.#retry);
      this.#retry = undefined;
    }
  }
}
