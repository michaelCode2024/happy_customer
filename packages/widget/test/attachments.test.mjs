import test from 'node:test';
import assert from 'node:assert/strict';
import { ChatStore } from '../build/modules/store.js';
import { VisitorApi } from '../build/modules/api.js';
import { VisitorSocket } from '../build/modules/socket.js';
import { resolveOptions } from '../build/modules/config.js';
const realConnect = VisitorSocket.prototype.connect;
const realClose = VisitorSocket.prototype.close;

test('登录身份缓存与退出后的匿名身份隔离，WebView 票据可以初始化', async () => {
  const cache = new Map();
  globalThis.localStorage = { getItem: key => cache.get(key) ?? null, setItem: (key, value) => cache.set(key, value) };
  const inputs = [];
  VisitorSocket.prototype.connect = () => {};
  VisitorSocket.prototype.close = () => {};
  VisitorApi.prototype.bootstrap = async input => {
    inputs.push(input);
    return { token: `token-${inputs.length}`, visitorId: `visitor-${inputs.length}`, expiresIn: 3600, inbox: {}, agentsOnline: 0 };
  };
  VisitorApi.prototype.listConversations = async () => ({ items: [] });
  const signed = new ChatStore(resolveOptions({ endpoint: 'http://localhost', inboxKey: 'test', storage: 'identity-test', bridge: { getVisitor: () => ({identityToken:'backend-ticket'}) } }));
  const guest = new ChatStore(resolveOptions({ endpoint: 'http://localhost', inboxKey: 'test', storage: 'identity-test' }));
  try {
    await signed.init();
    await guest.init();
    assert.equal(inputs.length, 2, '匿名初始化不得复用登录账号缓存');
    assert.equal(inputs[0].identityToken, 'backend-ticket');
    assert.equal(inputs[1].identityToken, undefined);
    assert.ok(cache.has('identity-test.test.signed'));
    assert.ok(cache.has('identity-test.test.guest'));
  } finally { signed.destroy(); guest.destroy(); delete globalThis.localStorage; }
});

// 隔离传输层，只验证首次附件建会话和失败重试的业务语义。
function fixture({ uploadFails = false, sendFails = false } = {}) {
  let uploads = 0, creates = 0;
  const sent = [];
  const conversation = { id: 'c1', status: 'OPEN', lastSequence: 0 };
  VisitorSocket.prototype.subscribe = () => {};
  VisitorSocket.prototype.close = () => {};
  VisitorApi.prototype.createConversation = async (_, content) => {
    creates++;
    assert.equal(content, '', '附件创建会话时不应伪造文字消息');
    return { conversation };
  };
  VisitorApi.prototype.pageMessages = async () => ({ items: [], hasOlder: false });
  VisitorApi.prototype.getConversation = async () => conversation;
  VisitorApi.prototype.upload = async (_, file) => {
    uploads++;
    if (uploadFails && uploads === 1) throw new Error('network interrupted');
    return { id: 'a1', fileName: file.name, contentType: file.type, sizeBytes: file.size, url: '/file/a1' };
  };
  VisitorApi.prototype.sendMessage = async (id, input) => {
    sent.push(input);
    if (sendFails && sent.length === 1) throw new Error('message interrupted');
    return { ...input, id: 'm1', conversationId: id, senderType: 'VISITOR', sequence: 1, createdAt: new Date().toISOString() };
  };
  const store = new ChatStore(resolveOptions({ endpoint: 'http://localhost', inboxKey: 'test', storage: '' }));
  return { store, sent, get uploads() { return uploads; }, get creates() { return creates; } };
}

test('首次咨询可以直接发送图片，不要求先发文字', async () => {
  const f = fixture();
  await f.store.sendFiles([new File(['image'], 'photo.png', { type: 'image/png' })]);
  assert.equal(f.creates, 1);
  assert.equal(f.sent[0].messageType, 'IMAGE');
  assert.deepEqual(f.sent[0].attachmentIds, ['a1']);
  assert.equal(f.store.snapshot.uploading, 0);
  assert.equal(f.store.snapshot.messages.length, 1);
  f.store.destroy();
});

test('首条文字只显示一条气泡，并通过幂等标识完成发送', async () => {
  const f = fixture();
  await f.store.send('你好');
  assert.equal(f.creates, 1);
  assert.equal(f.sent[0].messageType, 'TEXT');
  assert.equal(f.store.snapshot.messages.length, 1);
  assert.notEqual(f.store.snapshot.messages[0].delivery, 'SENDING');
  f.store.destroy();
});

test('上传失败后重试重新上传文件，保留原消息幂等 ID', async () => {
  const f = fixture({ uploadFails: true });
  await f.store.sendFiles([new File(['document'], 'help.txt', { type: 'text/plain' })]);
  const failed = f.store.snapshot.messages[0];
  assert.equal(failed.delivery, 'FAILED');
  await f.store.retry(failed.localId);
  assert.equal(f.uploads, 2);
  assert.equal(f.sent[0].clientMessageId, failed.localId);
  assert.deepEqual(f.sent[0].attachmentIds, ['a1']);
  assert.equal(f.store.snapshot.messages.length, 1);
  f.store.destroy();
});

test('附件已上传但消息失败，重试复用附件而非重复上传', async () => {
  const f = fixture({ sendFails: true });
  await f.store.sendFiles([new File(['document'], 'help.txt')]);
  await f.store.retry(f.store.snapshot.messages[0].localId);
  assert.equal(f.uploads, 1);
  assert.equal(f.sent.length, 2);
  assert.equal(f.sent[0].clientMessageId, f.sent[1].clientMessageId);
  assert.deepEqual(f.sent[1].attachmentIds, ['a1']);
  f.store.destroy();
});

test('首条语音上传失败重试仍保留音频类型和时长', async () => {
  const f = fixture({ uploadFails: true });
  await f.store.sendVoice(new Blob(['audio'], { type: 'audio/webm' }), 3456);
  await f.store.retry(f.store.snapshot.messages[0].localId);
  assert.equal(f.sent[0].messageType, 'AUDIO');
  assert.equal(f.sent[0].metadata.durationMs, 3456);
  assert.equal(f.creates, 1);
  f.store.destroy();
});


test('访客端拒绝私有消息事件，公开回复仍能实时显示', async () => {
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
  VisitorApi.prototype.markRead = async () => ({});
  VisitorApi.prototype.markDelivered = async () => ({});
  VisitorApi.prototype.pageMessages = async () => ({items:[],hasOlder:false});
  const store = new ChatStore(resolveOptions({endpoint:'http://localhost',inboxKey:'private-test',storage:''}));
  try {
    await store.init();
    await store.selectConversation('c1');
    const message = {id:'private1',conversationId:'c1',senderType:'AGENT',sequence:1,messageType:'EVENT',content:'internal secret',private:true,createdAt:new Date().toISOString()};
    for (const type of ['message.created','message.updated']) socket.onmessage({data:JSON.stringify({type,conversationId:'c1',data:message})});
    assert.equal(store.snapshot.messages.length,0);
    socket.onmessage({data:JSON.stringify({type:'message.created',conversationId:'c1',data:{...message,id:'public1',private:false,messageType:'TEXT',content:'public reply'}})});
    assert.equal(store.snapshot.messages.length,1);
    assert.equal(store.snapshot.messages[0].content,'public reply');
  } finally {store.destroy();globalThis.WebSocket=previousWebSocket;}
});


test('缓存登录恢复时刷新在线客服数量和接待文案', async () => {
  const cache = new Map();
  globalThis.localStorage = {getItem:key=>cache.get(key)??null,setItem:(key,value)=>cache.set(key,value)};
  VisitorSocket.prototype.connect = () => {};
  VisitorSocket.prototype.close = () => {};
  VisitorApi.prototype.bootstrap = async () => ({token:'cached-token',visitorId:'visitor',expiresIn:3600,inbox:{},agentsOnline:1,aiEnabled:false});
  VisitorApi.prototype.listConversations = async () => ({items:[],agentsOnline:2,aiEnabled:true,welcomeMessage:'fresh welcome'});
  const options=resolveOptions({endpoint:'http://localhost',inboxKey:'cached-presence',storage:'presence-test'});
  const first=new ChatStore(options);const restored=new ChatStore(options);
  try {
    await first.init();await restored.init();
    assert.equal(restored.snapshot.agentsOnline,2);
    assert.equal(restored.snapshot.aiEnabled,true);
    assert.equal(restored.snapshot.welcomeMessage,'fresh welcome');
  } finally {first.destroy();restored.destroy();delete globalThis.localStorage;}
});


const { requestMicrophone, collectRecordingChunks } = await import('../build/modules/recording.js');
test('录音停止后最后一段音频仍进入本次录音', async () => {
  const recorder = new EventTarget();
  const chunks = collectRecordingChunks(recorder);
  const event = new Event('dataavailable');
  event.data = new Blob(['final-opus-chunk']);
  recorder.dispatchEvent(event);
  assert.equal(await new Blob(chunks).text(), 'final-opus-chunk');
});
test('麦克风授权超时释放迟到的音轨，允许再次请求', async () => {
  let grant;
  let stopped = 0;
  const pending = requestMicrophone(() => new Promise(resolve => { grant = resolve; }), 5);
  await assert.rejects(pending, /授权未完成/);
  grant({ getTracks: () => [{stop() { stopped++; }}] });
  await Promise.resolve();
  assert.equal(stopped, 1);
  const stream = {getTracks: () => []};
  assert.equal(await requestMicrophone(async () => stream, 50), stream);
});
test('麦克风拒绝授权及时返回错误', async () => {
  await assert.rejects(requestMicrophone(async () => { throw new Error('permission denied'); }), /permission denied/);
});

test('菜单首次发送和失败重试保留服务端校验用的菜单 ID', async () => {
  const f = fixture({ sendFails: true });
  try {
    await f.store.selectChannelItem({ id: 'service-hours', title: '服务时间', action: 'REPLY', value: '09:00' });
    assert.deepEqual(f.sent[0].metadata, { menuId: 'service-hours' });
    const failed = f.store.snapshot.messages[0];
    await f.store.retry(failed.localId);
    assert.deepEqual(f.sent[1].metadata, { menuId: 'service-hours' });
    assert.equal(f.sent[0].clientMessageId, f.sent[1].clientMessageId);
    await f.store.selectChannelItem({ id: 'link', title: '链接', action: 'LINK', value: 'https://example.com' });
    assert.equal(f.sent.length, 2, '跳转链接不应伪造聊天消息');
  } finally { f.store.destroy(); }
});


test('隐藏页面不自动已读，重复推送不重复计数，失败回执保留未读', async () => {
  const previousDocument = globalThis.document;
  const previousWebSocket = globalThis.WebSocket;
  let socket; let reads = 0; let delivers = 0; let rejectRead = true;
  globalThis.document = {visibilityState:'hidden',hasFocus:()=>false,addEventListener(){},removeEventListener(){}};
  globalThis.WebSocket = class {
    static OPEN=1; readyState=1;
    constructor(){socket=this;} send(){} close(){}
  };
  VisitorSocket.prototype.connect=realConnect;
  VisitorSocket.prototype.close=realClose;
  VisitorApi.prototype.bootstrap=async()=>({token:'test',visitorId:'v1',expiresIn:3600,inbox:{},agentsOnline:1});
  VisitorApi.prototype.listConversations=async()=>({items:[{id:'c1',visitorUnread:0,lastSequence:0,status:'OPEN'}]});
  VisitorApi.prototype.pageMessages=async()=>({items:[],hasOlder:false});
  VisitorApi.prototype.markDelivered=async()=>{delivers++;return {};};
  VisitorApi.prototype.markRead=async()=>{reads++;if(rejectRead)throw new Error('offline');return {};};
  const store=new ChatStore(resolveOptions({endpoint:'http://localhost',inboxKey:'hidden-receipt',storage:''}));
  try {
    await store.init(); await store.selectConversation('c1');store.open();
    const message={id:'m1',conversationId:'c1',sequence:1,senderType:'AGENT',messageType:'TEXT',content:'reply',createdAt:new Date().toISOString()};
    const event={data:JSON.stringify({type:'message.created',conversationId:'c1',data:message})};
    socket.onmessage(event);socket.onmessage(event);
    // 隐藏页：应上报送达、不上报已读，未读角标保留。
    await new Promise(resolve=>setTimeout(resolve, 450));
    assert.equal(reads,0);assert.ok(delivers>=1,'隐藏页也应上报已送达');assert.equal(store.snapshot.unread,1);
    globalThis.document.visibilityState='visible';globalThis.document.hasFocus=()=>true;
    store.open();await new Promise(resolve=>setImmediate(resolve));
    assert.equal(reads,1);assert.equal(store.snapshot.unread,1);
    rejectRead=false;store.open();await new Promise(resolve=>setImmediate(resolve));
    assert.equal(store.snapshot.unread,0);
  } finally {store.destroy();globalThis.document=previousDocument;globalThis.WebSocket=previousWebSocket;}
});

test('面板收起时只送达不已读，打开聚焦后才已读', async () => {
  const previousDocument = globalThis.document;
  const previousWebSocket = globalThis.WebSocket;
  let socket; let reads = 0; let delivers = 0;
  globalThis.document = {visibilityState:'visible',hasFocus:()=>true,addEventListener(){},removeEventListener(){}};
  globalThis.WebSocket = class {
    static OPEN=1; readyState=1;
    constructor(){socket=this;} send(){} close(){}
  };
  VisitorSocket.prototype.connect=realConnect;
  VisitorSocket.prototype.close=realClose;
  VisitorApi.prototype.bootstrap=async()=>({token:'test',visitorId:'v1',expiresIn:3600,inbox:{},agentsOnline:1});
  VisitorApi.prototype.listConversations=async()=>({items:[{id:'c1',visitorUnread:0,lastSequence:0,status:'OPEN'}]});
  VisitorApi.prototype.pageMessages=async()=>({items:[],hasOlder:false});
  VisitorApi.prototype.markDelivered=async()=>{delivers++;return {};};
  VisitorApi.prototype.markRead=async()=>{reads++;return {};};
  const store=new ChatStore(resolveOptions({endpoint:'http://localhost',inboxKey:'closed-delivered',storage:''}));
  try {
    await store.init(); await store.selectConversation('c1');
    // 面板保持收起：消息进列表后只应送达。
    const message={id:'m2',conversationId:'c1',sequence:2,senderType:'AGENT',messageType:'TEXT',content:'hi',createdAt:new Date().toISOString()};
    socket.onmessage({data:JSON.stringify({type:'message.created',conversationId:'c1',data:message})});
    await new Promise(resolve=>setTimeout(resolve, 450));
    assert.ok(delivers>=1);assert.equal(reads,0);assert.equal(store.snapshot.unread,1);
    store.open();
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(reads,1);assert.equal(store.snapshot.unread,0);
  } finally {store.destroy();globalThis.document=previousDocument;globalThis.WebSocket=previousWebSocket;}
});
