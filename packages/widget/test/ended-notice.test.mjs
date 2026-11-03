import test from 'node:test';
import assert from 'node:assert/strict';
import { ChatStore } from '../build/modules/store.js';
import { VisitorApi } from '../build/modules/api.js';
import { VisitorSocket } from '../build/modules/socket.js';
import { resolveOptions } from '../build/modules/config.js';
const realConnect = VisitorSocket.prototype.connect;
const realClose = VisitorSocket.prototype.close;

const now = () => new Date().toISOString();

// 结束提示是 SYSTEM/EVENT 行：访客线程要看得见，但状态必须保持已结束。
test('结束提示进入访客线程且保持已结束状态', async () => {
  let socket;
  class FakeWebSocket {
    static OPEN = 1;
    readyState = 1;
    constructor() { socket = this; }
    send() {}
    close() {}
  }
  const previousWebSocket = globalThis.WebSocket;
  globalThis.WebSocket = FakeWebSocket;
  VisitorSocket.prototype.connect = realConnect;
  VisitorSocket.prototype.close = realClose;
  VisitorApi.prototype.bootstrap = async () => ({ token: 'ended-token', visitorId: 'ended-visitor', expiresIn: 3600, inbox: {}, agentsOnline: 1 });
  VisitorApi.prototype.listConversations = async () => ({ items: [{ id: 'c1', status: 'RESOLVED', lastSequence: 1, reopenGraceMinutes: 1440 }] });
  VisitorApi.prototype.listMessages = async () => ({ items: [{ id: 'm1', conversationId: 'c1', senderType: 'VISITOR', sequence: 1, messageType: 'TEXT', content: '第一个问题', createdAt: now() }], hasOlder: false });
  VisitorApi.prototype.pageMessages = async () => ({ items: [{ id: 'm1', conversationId: 'c1', senderType: 'VISITOR', sequence: 1, messageType: 'TEXT', content: '第一个问题', createdAt: now() }], hasOlder: false, lastSequence: 1 });
  VisitorApi.prototype.getConversation = async () => ({ id: 'c1', status: 'RESOLVED', lastSequence: 1 });
  VisitorApi.prototype.markRead = async () => ({});
  VisitorApi.prototype.markDelivered = async () => ({});
  const store = new ChatStore(resolveOptions({ endpoint: 'http://localhost', inboxKey: 'ended-test', storage: '' }));
  const status = () => store.snapshot.conversations.find((item) => item.id === 'c1').status;
  try {
    await store.init();
    assert.equal(store.snapshot.activeId, 'c1');
    assert.equal(status(), 'RESOLVED');
    await store.selectConversation('c1');
    assert.equal(store.snapshot.activeId, 'c1');
    assert.equal(status(), 'RESOLVED');
  } finally {
    store.destroy();
    globalThis.WebSocket = previousWebSocket;
  }
});
