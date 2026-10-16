(() => {
  'use strict';
  if (window.TongyuSupport) return;
  const categories = [
    ['account', '登录与账号', '企业标识、账号登录、权限问题', 'user'],
    ['integration', '接入与集成', '网站嵌入、H5 与身份对接', 'link'],
    ['issue', '使用与故障', '消息、通知与功能异常', 'settings'],
  ];
  const paths = {headset:'M4 14v-3a8 8 0 0 1 16 0v3M4 12H2v7h4v-7H4m16 0h2v7h-4v-7h2m0 7c0 3-3 3-7 3',user:'M8 8a4 4 0 1 0 8 0 4 4 0 1 0-8 0M4 22v-3c0-6 16-6 16 0v3',link:'m10 14 4-4M8 16l-2 2a4 4 0 0 1-6-6l5-5a4 4 0 0 1 6 0m2 10a4 4 0 0 0 6 0l5-5a4 4 0 0 0-6-6l-2 2',settings:'M12 3v3m0 12v3M3 12h3m12 0h3M6 6l2 2m8 8 2 2M6 18l2-2m8-8 2-2M8 12a4 4 0 1 0 8 0 4 4 0 1 0-8 0',book:'M4 3h13l3 3v16H4zM8 8h7M8 12h8M8 16h6',close:'m6 6 12 12M18 6 6 18',send:'m3 11 18-8-8 18-2-8-8-2m8 2L21 3'};
  const icon = name => `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[name] || paths.headset}"/></svg>`;
  const key = 'tongyu.official-support.v1';
  let host, shadow, mode, opener, timer, config, connecting, session, sequence = 0, syncing = false, sending = false, category = 'integration', draft = '', contact = '', pending = null, online = false, ready = false, messages = new Map(), ticks = 0;
  const $ = id => shadow.getElementById(id);
  const categoryName = () => categories.find(c => c[0] === category)?.[1] || '技术咨询';
  const uuid = () => crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{const n=Math.random()*16|0;return (c==='x'?n:(n&3|8)).toString(16)});
  function store() { try { localStorage.setItem(key, JSON.stringify(session)); } catch {} }
  function rememberDraft() { if ($('support-draft')) draft = $('support-draft').value; if ($('support-contact')) contact = $('support-contact').value; }
  function status(text, error = false, retry = false) {
    const el = $('support-status'); if (!el) return;
    el.textContent = text; el.classList.toggle('error', error);
    if (retry) { const button = document.createElement('button'); button.textContent = '重试'; button.onclick = () => connect().then(() => { if (mode === 'chat') startPolling(); }).catch(fail); el.append(button); }
  }
  function fail(error) { status(error.status === 401 ? '会话已过期，请关闭后重新打开支持窗口。' : error.message || '暂时无法连接，请稍后重试。', true, !ready); }
  async function api(path, options = {}) {
    const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await fetch('/api/v1/widget' + path, {...options, signal:controller.signal, credentials:'omit', headers:{'Content-Type':'application/json', ...(session?.token && path !== '/bootstrap' ? {Authorization:'Bearer '+session.token} : {})}, body:options.body ? JSON.stringify(options.body) : undefined});
      const data = await response.json().catch(() => ({}));
      if (!response.ok) { const error = new Error(data.message || '支持服务暂时无法连接，请稍后重试。'); error.status = response.status; if (response.status === 401) { session = null; ready = false; try { localStorage.removeItem(key); } catch {} } throw error; }
      return data;
    } catch (error) { if (error.name === 'AbortError') throw new Error('连接超时，输入内容已保留，请重试。'); if (error instanceof TypeError) throw new Error('网络连接失败，输入内容已保留，请重试发送。'); throw error; }
    finally { clearTimeout(timeout); }
  }
  function availability(count) {
    online = Number(count) > 0;
    status(online ? '有客服可接待，请描述你遇到的问题。' : '当前暂无客服在线，可留下问题，我们上线后继续处理。');
    if ($('support-contact-wrap')) $('support-contact-wrap').hidden = online;
    if ($('support-send')) $('support-send').textContent = online ? '发送' : '提交留言';
  }
  async function connect() {
    if (connecting) return connecting;
    connecting = (async () => {
      ready = false; status('正在连接通语官方支持…');
      if (!config) { const response = await fetch('/website/support-config.json', {cache:'no-store'}); if (!response.ok) throw new Error('支持入口暂时不可用，请稍后重试。'); config = await response.json(); }
      if (!config.enabled || !config.inboxKey) throw new Error('支持入口暂时不可用，请稍后重试。');
      if (!session) { try { const saved = JSON.parse(localStorage.getItem(key)); if (saved?.expiresAt > Date.now() && saved.inboxKey === config.inboxKey) session = saved; } catch {} }
      if (!session?.token) {
        const data = await api('/bootstrap', {method:'POST', body:{inboxKey:config.inboxKey, displayName:location.pathname.startsWith('/console') ? '工作台咨询访客' : '官网咨询访客', referrer:location.origin+location.pathname, attributes:{supportSource:location.pathname.startsWith('/console') ? 'CONSOLE' : 'WEBSITE'}}});
        session = {token:data.token, inboxKey:config.inboxKey, expiresAt:Date.now()+data.expiresIn*1000}; store();
      }
      const list = await api('/conversations'); availability(list.agentsOnline);
      const current = (list.items || []).find(c => c.id === session.conversationId && c.status !== 'RESOLVED');
      if (!current) { session.conversationId = null; sequence = 0; messages.clear(); store(); }
      ready = true; await sync();
    })();
    try { await connecting; } finally { connecting = null; }
  }
  function drawMessages() {
    const list = $('support-messages'); if (!list) return;
    const atBottom = list.parentElement.scrollHeight - list.parentElement.scrollTop - list.parentElement.clientHeight < 80;
    list.replaceChildren();
    [...messages.values()].sort((a,b)=>a.sequence-b.sequence).forEach(message => {
      if (message.private || message.deletedAt) return;
      const row = document.createElement('div'); row.className = 'message' + (message.senderType === 'VISITOR' ? ' mine' : '');
      const bubble = document.createElement('div'); bubble.className = 'bubble'; bubble.textContent = message.content || (message.attachments?.length ? '收到附件，请联系技术支持确认附件内容。' : '');
      const label = document.createElement('small'); label.textContent = (message.senderType === 'VISITOR' ? '你' : message.senderType === 'AGENT' ? '通语支持' : '服务提示') + ' · ' + new Date(message.createdAt).toLocaleTimeString('zh-CN', {hour:'2-digit',minute:'2-digit'});
      row.append(bubble,label); list.append(row);
    });
    if (atBottom || sending) list.parentElement.scrollTop = list.parentElement.scrollHeight;
  }
  async function sync() {
    if (!ready || syncing || mode !== 'chat') return;
    syncing = true;
    try {
      let receivedReply = false;
      if (session?.conversationId) {
        const data = await api('/conversations/'+encodeURIComponent(session.conversationId)+'/messages?after='+sequence+'&limit=100');
        receivedReply = (data.items || []).some(m => m.senderType === 'AGENT' && !messages.has(m.id));
        (data.items || []).forEach(m => { messages.set(m.id,m); sequence = Math.max(sequence,m.sequence); }); drawMessages();
      }
      if (++ticks % 4 === 0 || receivedReply) { const list = await api('/conversations'); availability(list.agentsOnline); }
    } finally { syncing = false; }
  }
  async function send(event) {
    event?.preventDefault(); if (sending) return; rememberDraft();
    if (!draft.trim()) { $('support-draft').focus(); return; }
    sending = true; $('support-send').disabled = true; $('support-draft').disabled = true; $('support-contact').disabled = true;
    try {
      if (!ready) await connect();
      const content = (messages.size ? '' : '【'+categoryName()+'】\n') + draft.trim() + (!online && contact.trim() ? '\n联系方式：'+contact.trim() : '');
      if (!pending || pending.draft !== draft || pending.contact !== contact || pending.category !== category) pending = {draft,contact,category,body:{content,clientMessageId:uuid()}};
      if (!session.conversationId) { const data = await api('/conversations',{method:'POST',body:{subject:'通语官方支持 · '+categoryName(),source:location.pathname.startsWith('/console')?'PC':'WEB'}}); session.conversationId = data.conversation.id; store(); }
      const data = await api('/conversations/'+encodeURIComponent(session.conversationId)+'/messages',{method:'POST',body:pending.body});
      messages.set(data.id,data); sequence = Math.max(sequence,data.sequence); draft = ''; pending = null; if ($('support-draft')) $('support-draft').value = ''; drawMessages();
      status(online ? '消息已发送。' : '留言已保存，我们上线后会继续处理。');
    } catch (error) { fail(error); }
    finally { sending = false; if ($('support-send')) { $('support-send').disabled = false; $('support-draft').disabled = false; $('support-contact').disabled = false; } }
  }
  function startPolling() { clearInterval(timer); timer = setInterval(() => { if (!document.hidden && mode === 'chat') sync().catch(fail); },3000); }
  function close() {
    rememberDraft(); host?.removeAttribute('data-mode'); mode = null; clearInterval(timer); $('support-panel')?.remove(); $('support-backdrop')?.remove();
    if ($('support-launcher')) $('support-launcher').hidden = !document.body.hasAttribute('data-tongyu-support-launcher');
    opener?.focus?.();
  }
  function open(options = {}) {
    if (!host) init(); rememberDraft(); if (!mode) opener = document.activeElement;
    clearInterval(timer); mode = options.mode || 'help'; if (options.category) category = options.category;
    host.setAttribute('data-mode',mode);host.setAttribute('data-theme', document.querySelector('#app.dark') ? 'dark' : 'light');
    $('support-panel')?.remove(); $('support-backdrop')?.remove(); $('support-launcher').hidden = true;
    if (mode === 'help') { const backdrop = document.createElement('div'); backdrop.id = 'support-backdrop'; backdrop.className = 'backdrop'; backdrop.onclick = close; shadow.append(backdrop); }
    const panel = document.createElement('section'); panel.id = 'support-panel'; panel.className = 'panel '+mode; panel.setAttribute('role','dialog'); panel.setAttribute('aria-modal',String(mode === 'help')); panel.setAttribute('aria-labelledby','support-title');
    panel.innerHTML = mode === 'help' ? `<header class="head"><div><h2 id="support-title">技术支持与帮助</h2><p>登录前，也能获得帮助。</p></div><button class="close" aria-label="关闭支持面板">${icon('close')}</button></header><div class="help-body">${categories.map(([id,name,description,i])=>`<button class="category" data-category="${id}">${icon(i)}<span><strong>${name}</strong><small>${description}</small></span><span class="chevron">›</span></button>`).join('')}<a class="docs" href="/website/help.html">${icon('book')}<span>帮助文档</span></a></div><footer class="help-foot"><button class="primary" id="support-contact-button">${icon('headset')}联系技术支持</button></footer>` : `<header class="head"><span class="identity"><img src="/website/logo.svg" alt="" width="32" height="32"></span><div><h2 id="support-title">通语官方支持</h2><p>技术咨询与使用帮助</p></div><button class="close" aria-label="关闭支持面板">${icon('close')}</button></header><div id="support-status" class="status" role="status" aria-live="polite"></div><div class="conversation"><p class="welcome">你好，请选择需要帮助的事项，或直接描述你的问题。</p><div class="choices">${categories.map(([id,name])=>`<button class="choice ${id===category?'active':''}" data-category="${id}">${name}　›</button>`).join('')}</div><div id="support-messages" role="log" aria-label="与通语官方支持的对话" aria-live="polite"></div></div><form class="composer"><div class="contact" id="support-contact-wrap" hidden><label for="support-contact">联系方式（选填，方便后续跟进）</label><input id="support-contact" maxlength="150" autocomplete="off" placeholder="邮箱或其他联系方式"></div><textarea id="support-draft" maxlength="3000" aria-label="描述你的问题" placeholder="描述你的问题…"></textarea><div class="compose-actions"><a href="/website/help.html">帮助文档</a><button class="primary" id="support-send" type="submit">发送</button></div><p class="notice">由通语官方支持团队接待</p></form>`;
    shadow.append(panel); panel.querySelector('.close').onclick = close;
    panel.querySelectorAll('[data-category]').forEach(button => button.onclick = () => { category = button.dataset.category; if (mode === 'help') open({mode:'chat',category}); else { panel.querySelectorAll('.choice').forEach(c=>c.classList.toggle('active',c.dataset.category===category)); $('support-draft').focus(); } });
    if (mode === 'help') $('support-contact-button').onclick = () => open({mode:'chat',category});
    else { $('support-draft').value = draft; $('support-contact').value = contact; panel.querySelector('form').onsubmit = send; $('support-draft').onkeydown = e => { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); } }; drawMessages(); connect().then(()=>{if(mode==='chat')startPolling()}).catch(fail); }
    panel.querySelector('button').focus();
  }
  function init() {
    if (host || !document.body) return;
    host = document.createElement('tongyu-official-support'); shadow = host.attachShadow({mode:'open'});
    shadow.innerHTML = `<link rel="stylesheet" href="/website/support.css"><button id="support-launcher" class="launcher" aria-label="联系通语官方支持">${icon('headset')}联系通语</button>`;
    document.body.append(host); $('support-launcher').hidden = !document.body.hasAttribute('data-tongyu-support-launcher'); $('support-launcher').onclick = () => open({mode:'chat'});
    document.addEventListener('click', e => { const trigger = e.target.closest('[data-tongyu-support]'); if (!trigger) return; e.preventDefault(); open({mode:trigger.dataset.tongyuSupport || 'help',category:trigger.dataset.supportCategory}); });
    shadow.addEventListener('keydown', e => {
      if (e.key === 'Escape') { e.preventDefault(); close(); }
      if (e.key !== 'Tab' || mode !== 'help') return;
      const items = [...$('support-panel').querySelectorAll('button,a,input,textarea')].filter(el=>!el.disabled&&!el.hidden), first=items[0],last=items.at(-1);
      if (e.shiftKey && shadow.activeElement===first) { e.preventDefault(); last.focus(); } else if (!e.shiftKey && shadow.activeElement===last) { e.preventDefault(); first.focus(); }
    });
  }
  window.TongyuSupport = {open,close};
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded',init,{once:true}); else init();
})();
