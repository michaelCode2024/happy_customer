'use strict';
const el = id => document.getElementById(id);
const query = new URLSearchParams(location.search);
const ticket = query.get('invite') || '';
// 宿主可把 identityToken + groupId 放进查询串，打开已入群用户的群页。
const identityToken = query.get('identityToken') || '';
const deepGroupId = query.get('groupId') || query.get('group') || '';
const cache = query.has('console')
  ? 'liaoqiao-console-group'
  : 'liaoqiao-group-' + (ticket || deepGroupId || (identityToken ? 'identity' : 'anon'));
let token = '', groupId = '', actorId = '', actorKind = 'widget';
let socket, retry, searchTimer, pollTimer, items = [], pending = null, sending = false;
let group = null, refreshGeneration = 0, call = null, peer = null, media = null;
let callBusy = false, polling = false, startedAt = null, connectTimeout = null;
let networkFailure = false;
let callAttempt = 0;
let mediaGeneration = 0, ended = false, notifiedCalls = new Set();
try { const saved = JSON.parse(sessionStorage.getItem(cache)); if (saved) ({token, groupId, actorId, actorKind = 'widget'} = saved); } catch {}
function error(e) { if(/Failed to fetch|NetworkError/.test(e.message)) { networkFailure=true; e = new Error('网络连接中断，正在重试…'); } if([401,403,404].includes(e.status)) { stopMedia(); if(call) terminal('已离开群聊或登录失效，通话结束'); } el('error').textContent = e.message || String(e); el('error').hidden = false; }
async function api(method, path, body) {
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 15000);
  try {
    const res = await fetch(path, {method, signal: controller.signal, headers: {'Content-Type': 'application/json', ...(token ? {Authorization: 'Bearer ' + token} : {})}, ...(body !== undefined ? {body: JSON.stringify(body)} : {})});
    const data = await res.json();
    if (!res.ok) { const e = new Error(data.message || '请求失败'); e.status = res.status; throw e; }
    if(networkFailure) { networkFailure=false; el('error').hidden=true; }
    return data;
  } catch(e) { if(e.name === 'AbortError') throw new Error('请求超时，请重试'); throw e; } finally { clearTimeout(timer); }
}
const path = suffix => '/api/v1/groups/' + groupId + suffix;
const mine = m => m.actorId === actorId && m.kind === actorKind;
function render() {
  const host = el('messages'), bottom = host.scrollHeight - host.scrollTop - host.clientHeight < 70;
  host.replaceChildren();
  for (const m of items) {
    const box = document.createElement('div'); box.className = 'message' + (mine(m) ? ' mine' : '');
    const meta = document.createElement('div'); meta.className = 'meta';
    meta.textContent = m.name + ' · ' + (m.kind === 'widget' ? '客户' : '客服') + ' · ' + new Date(m.createdAt).toLocaleTimeString('zh-CN', {hour: '2-digit', minute: '2-digit'});
    const text = document.createElement('div'); text.className = 'bubble' + (m.recalled ? ' tombstone' : ''); text.textContent = m.recalled ? '该消息已被撤回' : m.content;
    const card = m.metadata?.card;
    if (!m.recalled && m.messageType === 'CARD' && card && ['PRODUCT', 'ORDER'].includes(card.kind)) {
      text.replaceChildren();
      const title = document.createElement('strong'); title.textContent = card.title; text.append(title);
      for (const value of [card.kind === 'ORDER' ? '订单号：' + card.orderNumber : '', card.status || '', Number.isSafeInteger(card.amountMinor) ? `${card.currency} ${Math.floor(card.amountMinor / 100)}.${String(card.amountMinor % 100).padStart(2, '0')}` : '']) {
        if (value) { const line = document.createElement('div'); line.textContent = value; text.append(line); }
      }
      if (typeof card.url === 'string' && /^https?:\/\//.test(card.url)) { const link = document.createElement('a'); link.href = card.url; link.target = '_blank'; link.rel = 'noopener noreferrer'; link.textContent = card.kind === 'ORDER' ? '查看订单' : '查看商品'; text.append(link); }
    }
    box.append(meta, text);
    if (mine(m) && !m.recalled) {
      const button = document.createElement('button'); button.className = 'recall'; button.textContent = '撤回';
      button.onclick = async () => { button.disabled = true; try { await api('POST', path('/messages/' + m.id + '/recall'), {}); await refresh(); } catch(e) { error(e); button.disabled = false; } };
      box.append(button);
    }
    host.append(box);
  }
  if (bottom) host.scrollTop = host.scrollHeight;
}
async function refresh(older = false) {
  if (!token) return;
  const generation = ++refreshGeneration, q = el('search').value.trim();
  const [list, result] = await Promise.all([
    api('GET', path('?includeMembers=false')),
    api('GET', path('/messages?q=' + encodeURIComponent(q) + (older && items.length ? '&before=' + Math.min(...items.map(m => m.sequence)) : '')))
  ]);
  if (generation !== refreshGeneration) return;
  group = list.group;
  // 外观随本群所属渠道配置更新，独立群页与嵌入页使用相同来源。
  let channelStyle = document.getElementById('groupChannelStyle');
  if (!channelStyle) { channelStyle = document.createElement('style'); channelStyle.id = 'groupChannelStyle'; document.head.append(channelStyle); }
  channelStyle.textContent = group.customCss || '';
  if (!group) { stopMedia(); throw new Error('你已退出或被移出此群'); }
  el('title').textContent = group.name;
  el('announcement').textContent = '群公告：' + group.announcement; el('announcement').hidden = !group.announcement;
  const closed = group.archived || group.dissolved;
  el('closed').hidden = !closed && group.canSend !== false; el('closed').textContent = group.dissolved ? '群已解散，历史消息保留。' : group.archived ? '群已归档，仅可查看历史。' : '当前群仅群主和管理员可发言，你仍可查看消息。';
  el('draft').disabled = closed || group.canSend === false; el('send').disabled = closed || group.canSend === false || sending; el('callButton').disabled = closed;
  if (group.archived && call) await finishCall('群已归档或解散');
  const page = result.items.reverse();
  items = older ? [...new Map([...page, ...items].map(m => [m.id, m])).values()].sort((a,b) => a.sequence - b.sequence) : page;
  el('older').hidden = !!q || result.items.length < 100; render();
  if (!q && !older && items.length && el('messages').scrollHeight - el('messages').scrollTop - el('messages').clientHeight < 70 && document.visibilityState === 'visible' && document.hasFocus()) await api('POST', path('/read'), {sequence: Math.max(...items.map(m=>m.sequence))});
}
function connect() {
  if (!token || ended) return;
  socket = new WebSocket(location.origin.replace(/^http/, 'ws') + '/ws/groups?token=' + encodeURIComponent(token));
  socket.onopen = () => { el('status').textContent = '已连接'; refresh().catch(error); };
  socket.onmessage = e => { try { const event = JSON.parse(e.data); if (event.type === 'group.updated' && event.data?.groupId === groupId) { refresh().catch(error); pollCalls().catch(error); } } catch {} };
  socket.onclose = () => { if (token && !ended) { el('status').textContent = '重连中'; retry = setTimeout(connect, 3000); } };
}
async function start() {
  el('join').hidden = true; el('loading').hidden = false;
  try {
    await refresh(); el('chat').hidden = false;
    for (const id of ['people', 'settings', 'callButton']) el(id).hidden = false;
    connect(); pollTimer = setInterval(() => pollCalls().catch(error), 1500); await pollCalls(); return true;
  } catch(e) { error(e); return false; } finally { el('loading').hidden = true; }
}
el('joinButton').onclick = async () => {
  el('joinButton').disabled = true; el('error').hidden = true;
  try {
    const body = {name: el('name').value.trim()};
    if (identityToken) body.identityToken = identityToken;
    const result = await api('POST', '/api/v1/group-join/' + encodeURIComponent(ticket), body);
    token = result.token; groupId = result.groupId; actorId = result.visitorId; actorKind = 'widget';
    sessionStorage.setItem(cache, JSON.stringify({token, groupId, actorId, actorKind})); await start();
  } catch(e) { error(e); } finally { el('joinButton').disabled = false; }
};
async function openWithIdentity() {
  el('join').hidden = true; el('loading').hidden = false; el('error').hidden = true;
  try {
    const result = await api('POST', '/api/v1/groups/session', {identityToken, groupId: deepGroupId});
    token = result.token; groupId = result.groupId; actorId = result.visitorId; actorKind = 'widget';
    sessionStorage.setItem(cache, JSON.stringify({token, groupId, actorId, actorKind}));
    // 票据勿长期留在地址栏，避免 Referer / 历史泄露。
    history.replaceState({}, '', location.pathname + '?groupId=' + encodeURIComponent(groupId));
    await start();
  } catch(e) { el('join').hidden = !ticket; error(e); } finally { el('loading').hidden = true; }
}
el('send').onclick = async () => {
  const content = el('draft').value.trim(); if (!content || sending || group?.archived || group?.dissolved || group?.canSend === false) return;
  sending = true; el('send').disabled = true; el('error').hidden = true;
  if (!pending || pending.content !== content) pending = {content, clientId: crypto.randomUUID()};
  try { await api('POST', path('/messages'), pending); pending = null; el('draft').value = ''; await refresh(); el('messages').scrollTop = el('messages').scrollHeight; }
  catch(e) { error(e); } finally { sending = false; el('send').disabled = !!group?.archived || !!group?.dissolved || group?.canSend === false; }
};
el('search').oninput = () => { ++refreshGeneration; clearTimeout(searchTimer); searchTimer = setTimeout(() => refresh().catch(error), 300); };
el('search').onkeydown = e => { if (e.key === 'Enter') { clearTimeout(searchTimer); refresh().catch(error); } };
el('older').onclick = () => refresh(true).catch(error);
async function members(forCall = false) {
  const data = await api('GET', path('')); el('memberList').replaceChildren();
  for (const m of data.members) {
    const row = document.createElement('div'); row.className = 'member';
    const label = document.createElement('span'); label.textContent = m.name;
    const role = document.createElement('small'); role.textContent = (m.id === group.ownerId && m.kind === group.ownerKind ? '群主' : m.isManager ? '管理员' : m.kind === 'widget' ? '成员' : '客服') + (m.id === actorId && m.kind === actorKind ? ' · 我' : ''); label.append(role); row.append(label);
    if (!group.archived && !(m.id === actorId && m.kind === actorKind)) {
      const button = document.createElement('button'); button.textContent = '语音通话';
      button.onclick = () => { el('members').close(); initiate(m).catch(error); }; row.append(button);
    }
    const isOwner = actorKind === (group.ownerKind || 'agent') && group.ownerId === actorId;
    if (!forCall && !group.archived && isOwner && !(m.id === actorId && m.kind === actorKind)) {
      const manager = document.createElement('button'); manager.textContent = m.isManager ? '撤销管理员' : '设为管理员';
      manager.onclick = async () => {
        if (!confirm((m.isManager ? '撤销' : '授予') + m.name + '的管理员权限？管理员可发言和生成邀请。')) return;
        manager.disabled = true;
        try { await api('PUT', path('/manager'), {kind:m.kind,id:m.id,isManager:!m.isManager}); el('members').close(); await refresh(); }
        catch(e) { error(e); } finally { manager.disabled = false; }
      }; row.append(manager);
      const remove = document.createElement('button'); remove.textContent = '移除'; remove.className = 'danger';
      remove.onclick = async () => {
        if (!confirm('将' + m.name + '移出群聊？移除后不能继续访问此群。')) return;
        remove.disabled = true;
        try { await api('DELETE', path('/members/' + m.kind + '/' + m.id)); el('members').close(); await refresh(); }
        catch(e) { error(e); } finally { remove.disabled = false; }
      }; row.append(remove);
      if (m.kind === actorKind) {
        const transfer = document.createElement('button'); transfer.textContent = '转让群主';
        transfer.onclick = async () => {
          if (!confirm('将群主转让给' + m.name + '？你将失去群主管理权限。')) return;
          transfer.disabled = true;
          try { await api('PUT', path('/owner'), {kind:m.kind,id:m.id}); el('members').close(); await refresh(); }
          catch(e) { error(e); } finally { transfer.disabled = false; }
        }; row.append(transfer);
      }
    }
    el('memberList').append(row);
  }
  el('members').querySelector('h3').textContent = forCall ? '选择通话成员' : '群成员';
  el('leave').hidden = actorKind === (group.ownerKind || 'agent') && group.ownerId === actorId;
  el('members').showModal();
}
el('people').onclick = () => members().catch(error);
el('callButton').onclick = () => members(true).catch(error);
el('closeMembers').onclick = () => el('members').close();
el('leave').onclick = async () => {
  el('leave').disabled = true;
  try {
    if (call) await finishCall('已退出群聊');
    await api('DELETE', path('/members/' + actorKind + '/' + actorId));
    sessionStorage.removeItem(cache); token = ''; ended = true; clearTimeout(retry); clearInterval(pollTimer); socket?.close();
    el('members').close(); el('chat').hidden = true;
    for (const id of ['people', 'settings', 'callButton']) el(id).hidden = true;
    el('status').textContent = '已退出'; error(new Error('你已退出群聊，需使用新的邀请重新加入。'));
  } catch(e) { error(e); } finally { el('leave').disabled = false; }
};
el('settings').onclick = async () => {
  try {
    const data = await api('GET', path('')); const me = data.members.find(m => m.kind === actorKind && m.id === actorId);
    group = data.group;
    const owner = actorKind === (group.ownerKind || 'agent') && group.ownerId === actorId;
    el('groupRules').hidden = !owner || group.archived || group.dissolved;
    el('speakingMode').value = group.speakingMode || 'ALL'; el('maxMembers').value = group.maxMembers || 100;
    el('requireIdentity').checked = !!group.requireIdentity;
    el('inviteSection').hidden = !group.canInvite || group.archived || group.dissolved;
    el('inviteResult').textContent = '';
    el('nickname').value = me?.name || ''; el('dialogError').textContent = '';
    el('saveNickname').disabled = group.dissolved; el('dissolve').hidden = actorKind !== (group.ownerKind || 'agent') || group.ownerId !== actorId || group.dissolved;
    el('preferences').showModal();
  } catch(e) { error(e); }
};
el('closeSettings').onclick = () => el('preferences').close();
el('saveGroupRules').onclick = async () => {
  const capacity = Number(el('maxMembers').value);
  if (!Number.isInteger(capacity) || capacity < 2 || capacity > 5000) { el('dialogError').textContent = '群人数上限需为2至5000的整数'; return; }
  el('saveGroupRules').disabled = true;
  try { await api('PATCH', path('/policy'), {speakingMode:el('speakingMode').value,maxMembers:capacity,requireIdentity:el('requireIdentity').checked}); el('preferences').close(); await refresh(); }
  catch(e) { el('dialogError').textContent = e.message; }
  finally { el('saveGroupRules').disabled = false; }
};
el('createInvite').onclick = async () => {
  el('createInvite').disabled = true;
  try { const result = await api('POST', path('/invite'), {}); el('inviteResult').textContent = '24小时有效；新邀请会撤销旧邀请。' + result.url; }
  catch(e) { el('dialogError').textContent = e.message; }
  finally { el('createInvite').disabled = false; }
};
el('saveNickname').onclick = async () => {
  el('saveNickname').disabled = true;
  try { await api('PATCH', path('/me'), {name: el('nickname').value.trim()}); el('preferences').close(); await refresh(); }
  catch(e) { el('dialogError').textContent = e.message; }
  finally { el('saveNickname').disabled = !!group?.dissolved; }
};
el('dissolve').onclick = () => { el('preferences').close(); el('dissolveError').textContent = ''; el('dissolveConfirm').showModal(); };
el('cancelDissolve').onclick = () => el('dissolveConfirm').close();
el('confirmDissolve').onclick = async () => {
  el('confirmDissolve').disabled = true;
  try { await api('POST', path('/dissolve'), {}); el('dissolveConfirm').close(); await refresh(); }
  catch(e) { el('dissolveError').textContent = e.message; }
  finally { el('confirmDissolve').disabled = false; }
};

function stopMedia() {
  ++mediaGeneration; clearTimeout(connectTimeout); connectTimeout = null;
  media?.getTracks().forEach(t => t.stop()); media = null;
  if (peer) { peer.onconnectionstatechange = null; peer.close(); peer = null; }
  el('remoteAudio').srcObject = null; startedAt = null;
}
async function microphone() {
  if (!navigator.mediaDevices?.getUserMedia) throw new Error('此浏览器无法使用麦克风，请使用 HTTPS 或本机地址打开');
  const generation = ++mediaGeneration;
  let timeout;
  const request = navigator.mediaDevices.getUserMedia({audio: {echoCancellation: true, noiseSuppression: true}, video: false});
  // Late permission results must release tracks after cancellation or timeout.
  request.then(stream => { if (generation !== mediaGeneration) stream.getTracks().forEach(t => t.stop()); }, () => {});
  try {
    const stream = await Promise.race([request, new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('麦克风授权未完成，请允许麦克风后重试')), 12000); })]);
    if (generation !== mediaGeneration) { stream.getTracks().forEach(t => t.stop()); throw new Error('通话已取消'); }
    media = stream; return stream;
  } catch(e) { if (generation === mediaGeneration) ++mediaGeneration; throw e; }
  finally { clearTimeout(timeout); }
}
function showCall(name, state, incoming = false) {
  el('callName').textContent = name; el('callState').textContent = state; el('duration').textContent = '';
  el('acceptCall').hidden = !incoming; el('declineCall').hidden = !incoming;
  el('muteCall').hidden = true; el('muteCall').textContent = '静音'; el('closeCall').hidden = true; el('endCall').hidden = incoming;
  if (!el('callCard').open) el('callCard').showModal();
}
async function createPeer() {
  const stream = await microphone();
  const generation = mediaGeneration;
  const config = await api('GET', path('/calls'));
  if (generation !== mediaGeneration || !media) throw new Error('通话已取消');
  peer = new RTCPeerConnection({iceServers: config.iceServers || []});
  stream.getTracks().forEach(t => peer.addTrack(t, stream));
  peer.ontrack = event => { el('remoteAudio').srcObject = event.streams[0] || new MediaStream([event.track]); el('remoteAudio').play().catch(() => { el('callState').textContent = '音频播放受限，点击接听或静音按钮后重试'; }); };
  peer.onconnectionstatechange = () => {
    if (!peer) return;
    if (peer.connectionState === 'connected') { clearTimeout(connectTimeout); startedAt = Date.now(); el('callState').textContent = '通话中'; el('muteCall').hidden = false; }
    else if (peer.connectionState === 'failed') finishCall('连接失败，请检查网络或配置中继服务').catch(error);
    else if (peer.connectionState === 'disconnected') el('callState').textContent = '连接中断，正在恢复…';
  };
  return peer;
}
async function localSDP(pc, kind) {
  await pc.setLocalDescription(kind === 'offer' ? await pc.createOffer() : await pc.createAnswer());
  if (pc.iceGatheringState !== 'complete') await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pc.removeEventListener('icegatheringstatechange', changed); reject(new Error('语音网络协商超时，请重试')); }, 10000);
    function changed() { if (pc.iceGatheringState === 'complete') { clearTimeout(timer); pc.removeEventListener('icegatheringstatechange', changed); resolve(); } }
    pc.addEventListener('icegatheringstatechange', changed); changed();
  });
  return {type: pc.localDescription.type, sdp: pc.localDescription.sdp};
}
async function initiate(member) {
  if (call || callBusy || (typeof room !== 'undefined' && room)) { error(new Error('已有通话，请先挂断')); return; }
  const attempt = ++callAttempt;
  callBusy = true; showCall(member.name, '正在请求麦克风权限…');
  try {
    const pc = await createPeer(); const offer = await localSDP(pc, 'offer');
    if(attempt !== callAttempt) throw new Error('通话已取消');
    const result = await api('POST', path('/calls'), {recipientKind: member.kind, recipientId: member.id, offer});
    if(attempt !== callAttempt) { await api('POST',path('/calls/'+result.id),{action:'end'}); throw new Error('通话已取消'); }
    call = {id: result.id, callerId: actorId, callerKind: actorKind, recipientId: member.id, state: 'RINGING'};
    el('callState').textContent = '正在呼叫，等待对方接听…'; await pollCalls();
  } catch(e) { stopMedia(); terminal(e.message); }
  finally { callBusy = false; }
}
function terminal(message) {
  call = null; el('callState').textContent = message;
  for (const id of ['acceptCall', 'declineCall', 'muteCall', 'endCall']) el(id).hidden = true;
  el('closeCall').hidden = false;
}
async function finishCall(message = '通话已结束') {
  ++callAttempt;
  const current = call; call = null; stopMedia(); terminal(message);
  if (current) await api('POST', path('/calls/' + current.id), {action: 'end'});
}
async function pollCalls() {
  if (!token || !groupId || polling || ended) return;
  polling = true;
  try {
    const data = await api('GET', path('/calls'));
    if (call) {
      const current = data.items.find(c => c.id === call.id);
      if (!current || !['RINGING','ACCEPTED'].includes(current.state)) {
        stopMedia(); terminal(current?.state === 'DECLINED' ? '对方已拒接' : current?.state === 'MISSED' ? '无人接听，呼叫已超时' : '通话已结束'); return;
      }
      if(current.state === 'ACCEPTED' && !peer && !callBusy && current.recipientId === actorId && current.recipientKind === actorKind) { stopMedia(); terminal('已在其他页面接听'); return; }
      if (peer && current.state === 'ACCEPTED' && !peer.remoteDescription && !callBusy && current.callerId === actorId && current.callerKind === actorKind) {
        await peer.setRemoteDescription(current.answer); el('callState').textContent = '对方已接听，正在连接…'; armConnectTimeout();
      }
      if(peer?.connectionState === 'connected') {
        const stats = await peer.getStats();
        for(const report of stats.values()) {
          if(report.kind === 'audio' && report.type === 'inbound-rtp') el('remoteAudio').dataset.receivedBytes = String(report.bytesReceived || 0);
          if(report.kind === 'audio' && report.type === 'outbound-rtp') el('remoteAudio').dataset.sentBytes = String(report.bytesSent || 0);
        }
      }
      if (startedAt) { const seconds = Math.floor((Date.now() - startedAt) / 1000); el('duration').textContent = Math.floor(seconds / 60).toString().padStart(2,'0') + ':' + (seconds % 60).toString().padStart(2,'0'); }
      return;
    }
    if (callBusy) return;
    const incoming = data.items.find(c => c.state === 'RINGING' && c.recipientId === actorId && c.recipientKind === actorKind && !notifiedCalls.has(c.id));
    if (incoming) { call = incoming; notifiedCalls.add(incoming.id); for(const dialog of document.querySelectorAll('dialog[open]')) dialog.close(); showCall(incoming.callerName, '邀请你进行语音通话', true); }
  } finally { polling = false; }
}
function armConnectTimeout() {
  clearTimeout(connectTimeout);
  connectTimeout = setTimeout(() => { if (peer?.connectionState !== 'connected') finishCall('语音连接超时，请检查网络或配置中继服务').catch(error); }, 25000);
}
el('acceptCall').onclick = async () => {
  if (callBusy || !call) return;
  callBusy = true; el('acceptCall').disabled = true; el('callState').textContent = '正在请求麦克风权限…';
  const current = call;
  try {
    const pc = await createPeer(); await pc.setRemoteDescription(current.offer);
    const answer = await localSDP(pc,'answer');
    if (!call || call.id !== current.id) throw new Error('来电已结束');
    await api('POST', path('/calls/' + current.id), {action: 'accept', answer});
    el('acceptCall').hidden = true; el('declineCall').hidden = true; el('endCall').hidden = false;
    el('callState').textContent = '正在连接…'; armConnectTimeout();
  } catch(e) { stopMedia(); el('callState').textContent = e.message; }
  finally { callBusy = false; el('acceptCall').disabled = false; }
};
el('declineCall').onclick = async () => {
  if (!call) return; const current = call; stopMedia(); terminal('已拒接');
  try { await api('POST', path('/calls/' + current.id), {action: 'decline'}); } catch(e) { error(e); }
};
el('endCall').onclick = () => finishCall().catch(error);
el('muteCall').onclick = () => { if (media) { const tracks = media.getAudioTracks(), enabled = tracks.some(t => t.enabled); tracks.forEach(t => t.enabled = !enabled); el('muteCall').textContent = enabled ? '取消静音' : '静音'; el('remoteAudio').play().catch(() => {}); } };
el('closeCall').onclick = () => el('callCard').close();
el('callCard').addEventListener('cancel', e => { if (call || callBusy) e.preventDefault(); });

// 第三方跨域交接：只接收明确声明的宿主来源及实际父窗口，凭证不进入URL。
if (query.get('embed') === '1' && (window.parent !== window || window.opener)) {
  token = ''; el('join').hidden = true; el('loading').hidden = false;
  let parentOrigin = '';
  try { const u = new URL(query.get('parentOrigin')); if (['http:', 'https:'].includes(u.protocol) && u.origin === query.get('parentOrigin')) parentOrigin = u.origin; } catch {}
  const host = window.parent !== window ? window.parent : window.opener;
  if (!parentOrigin || !deepGroupId) error(new Error('请配置准确的parentOrigin和groupId'));
  else {
    const ready = setInterval(() => host.postMessage({type:'relaydesk.group.ready',groupId:deepGroupId}, parentOrigin), 500);
    let authenticating = false;
    window.addEventListener('message', async event => {
      if (event.origin !== parentOrigin || event.source !== host || token || authenticating) return;
      const data = event.data;
      if (data?.type !== 'relaydesk.group.authenticate' || data.groupId !== deepGroupId || typeof data.token !== 'string') return;
      authenticating = true;
      token = data.token; groupId = deepGroupId;
      try {
        const me = await api('GET', path(''));
        actorId = me.actorId; actorKind = me.actorKind;
        if (!await start()) throw new Error('群聊初始化失败，请重新打开');
        clearInterval(ready);
        host.postMessage({type:'relaydesk.group.authenticated',groupId}, parentOrigin);
      } catch(e) { token = ''; error(e); }
      finally { authenticating = false; }
    });
    setTimeout(() => { clearInterval(ready); if (!token) { el('loading').hidden = true; error(new Error('身份交接超时，请重新打开群聊')); } }, 30000);
  }
} else if (query.has('console') && (window.opener || window.parent !== window)) {
  // Only the same-origin parent (embedded console) or opener may hand off login.
  const sourceWindow = window.parent !== window ? window.parent : window.opener;
  token = ''; el('join').hidden = true; el('loading').hidden = false;
  const ready = setInterval(() => sourceWindow?.postMessage('liaoqiao-group-ready', location.origin), 400);
  window.addEventListener('message', async event => {
    if (event.origin !== location.origin || event.source !== sourceWindow || token) return;
    let data; try { data = typeof event.data === 'string' ? JSON.parse(event.data) : event.data; } catch { return; }
    if(data?.type !== 'liaoqiao-group-auth') return;
    ({token,groupId,actorId,actorKind} = data); clearInterval(ready);
    await start();
  });
  setTimeout(() => { clearInterval(ready); if (!token) { el('loading').hidden = true; error(new Error('登录交接未完成，请返回客服工作台重新打开')); } }, 15000);
} else if (token) start();
else if (identityToken && deepGroupId) openWithIdentity();
else if (!ticket) { el('joinButton').disabled = true; error(new Error('请通过客服提供的有效邀请链接进入，或由业务系统打开群聊。')); }
else if (identityToken) {
  // 邀请链接 + 登录票据：称呼可空，服务端用票据里的昵称。
  el('name').placeholder = '可选，默认使用登录昵称';
  const hint = el('join').querySelector('p');
  if (hint) hint.textContent = '已识别登录身份，确认后加入群聊。';
}
window.addEventListener('pagehide', () => {
  ended = true; clearTimeout(retry); clearTimeout(searchTimer); clearInterval(pollTimer); socket?.close();
  if (call && token) fetch(path('/calls/' + call.id), {method:'POST',keepalive:true,headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify({action:'end'})}).catch(() => {});
  stopMedia();
});

document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'&&token)refresh().catch(error);});
window.addEventListener('focus',()=>{if(token)refresh().catch(error);});
