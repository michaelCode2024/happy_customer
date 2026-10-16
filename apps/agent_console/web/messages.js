'use strict';
// 宿主提供短期身份，列表和消息均读取服务端真实权限范围；票据不进URL或存储。
const params = new URLSearchParams(location.search), staff = params.get('role') === 'staff';
const parentOrigin = params.get('parentOrigin'), inboxKey = params.get('inboxKey'), inboxId = params.get('inboxId');
const byId = id => document.getElementById(id);
let token = '', identity = '', starting = false, renewing = false, timer, inbox, generation = 0, selectedGroup = '';
async function api(method, path, body, credential = token) {
  const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),15000);
  let res;
  try {res = await fetch(path, {method,signal:controller.signal, headers:{'Content-Type':'application/json', ...(credential ? {Authorization:'Bearer '+credential}: {})}, ...(body === undefined ? {} : {body:JSON.stringify(body)})});}
  catch(e){throw new Error(e.name==='AbortError'?'请求超时，请重试':'网络连接失败，请重试');}
  finally{clearTimeout(timeout);}
  const data = await res.json();
  if (!res.ok) {const e=new Error(data.message || '消息服务暂不可用');e.status=res.status;throw e;}
  return data;
}
function showError(e) {
  byId('errorText').textContent = e.message; byId('error').hidden = false;
  // 聊天票据失效后请宿主重新取身份，不绕过业务登录，也不永久停在关闭占位页。
  if(e.status===401 && !renewing){renewing=true;token='';clearInterval(timer);const event={source:'tongyu',type:'close'};
    if(parent!==window && parentOrigin)parent.postMessage(event,parentOrigin);
    else window.flutter_inappwebview?.callHandler('tongyuHost',JSON.stringify(event));}
}
function applyBrand(config) {
  inbox = config;
  // 渠道管理员已有的自定义CSS配置也应用到列表及本渠道群聊，不预置任何品牌。
  let style = byId('channelStyle');
  if (!style) {style = document.createElement('style'); style.id='channelStyle'; document.head.append(style);}
  style.textContent = config.customCss || '';
}
async function refresh() {
  if (!token || !byId('detail').hidden) return;
  const current = ++generation;
  const results = await Promise.allSettled([
    api('GET', staff ? '/api/v1/console/conversations?filter=all&limit=100&inboxId='+encodeURIComponent(inboxId || '') : '/api/v1/widget/conversations'),
    api('GET','/api/v1/groups')
  ]);
  if (current !== generation || !byId('detail').hidden) return;
  byId('error').hidden = true;
  const rows = [];
  results.forEach((result,index) => {
    if (result.status === 'rejected') {const error=result.reason;error.message=(index ? '群消息' : '聊天历史')+'加载失败：'+error.message;showError(error); return;}
    for (const item of result.value.items || []) rows.push({...item, isGroup:index===1});
  });
  // 群列表本身没有预览和时间，读取成员有权限的最新消息后统一按活跃时间排序。
  await Promise.all(rows.filter(row=>row.isGroup).map(async row=>{
    try{const data=await api('GET','/api/v1/groups/'+row.id+'/messages?after='+Math.max(0,(row.sequence||0)-1));
      const last=(data.items||[])[0];if(last){row.preview=last.recalled?'该消息已撤回':last.content;row.lastMessageAt=last.createdAt;}
    }catch(e){if(current===generation)showError(e);}
  }));
  if(current!==generation || !byId('detail').hidden)return;
  rows.sort((a,b) => new Date(b.lastMessageAt || b.updatedAt || b.createdAt || 0)-new Date(a.lastMessageAt || a.updatedAt || a.createdAt || 0));
  const list=byId('list'); list.replaceChildren();
  byId('state').hidden = rows.length > 0;
  byId('state').textContent = results.some(r=>r.status==='rejected') ? '暂时无法加载，请重试' : '暂无群聊和聊天记录';
  for (const row of rows) {
    const button=document.createElement('button'); button.className='item';
    const name=row.isGroup ? row.name : staff ? row.visitorName || '客户咨询' : row.assigneeName || '联系店主';
    const avatar=document.createElement('span'); avatar.className='avatar'; avatar.textContent=row.isGroup?'群':'聊';
    const summary=document.createElement('span'); summary.className='summary';
    const title=document.createElement('strong'); title.textContent=name;
    const tag=document.createElement('span'); tag.className='kind'; tag.textContent=row.isGroup?'群聊':'聊天'; title.append(tag);
    const preview=document.createElement('small'); preview.textContent=row.isGroup ? (row.preview || row.announcement || '暂无群消息') : row.lastMessagePreview || '暂无消息';
    summary.append(title,preview); const meta=document.createElement('span'); meta.className='meta';
    if(row.lastMessageAt) meta.textContent=new Date(row.lastMessageAt).toLocaleString('zh-CN',{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'});
    const unread=row.isGroup?row.unread:staff?row.agentUnread:row.visitorUnread;
    if(unread>0){const badge=document.createElement('span');badge.className='badge';badge.textContent=String(unread);meta.append(document.createElement('br'),badge);}
    button.append(avatar,summary,meta); button.onclick=()=>openRow(row,name); list.append(button);
  }
}
function back() {
  ++generation; window.TongYu?.unmount(); byId('thread').src='about:blank'; byId('thread').hidden=true;
  byId('detail').hidden=true; byId('widget').hidden=true; selectedGroup=''; void refresh();
}
function openRow(row,name) {
  ++generation; byId('detailTitle').textContent=name; byId('detail').hidden=false;
  const frame=byId('thread');
  if(row.isGroup){selectedGroup=row.id;frame.hidden=false;frame.src='/groups.html?embed=1&groupId='+encodeURIComponent(row.id)+'&parentOrigin='+encodeURIComponent(location.origin);}
  else if(staff){frame.hidden=false;frame.src='/console/?embedded=1&conversationId='+encodeURIComponent(row.id)+'&parentOrigin='+encodeURIComponent(location.origin);}
  else {byId('widget').hidden=false;window.TongYu.mount({endpoint:location.origin,inboxKey,identityToken:identity,conversationId:row.id,embedded:true,launcher:'none',autoOpen:true,source:'APP',storage:'',parentOrigin:location.origin,onEvent:event=>{if(event.type==='close')back();}});}
}
async function authenticate(value) {
  if(starting || token || !value)return;
  starting=true;
  try{
    identity=value;
    if(staff){token=identity;try{applyBrand(await api('GET','/api/v1/admin/inboxes/'+encodeURIComponent(inboxId)));}catch{ /* 普通店员仍可读取其接待列表。 */ }}
    else{const result=await api('POST','/api/v1/widget/bootstrap',{inboxKey,identityToken:identity},'');token=result.token;applyBrand(result.inbox);}
    await refresh();timer=setInterval(()=>void refresh().catch(showError),5000);
    // App WebView 宿主依赖 tongyuHost 的 ready 才能撤掉连接遮罩；iframe 宿主已靠 host-ready。
    const ready={source:'tongyu',type:'ready'};
    if(parent!==window && parentOrigin)parent.postMessage(ready,parentOrigin);
    else window.flutter_inappwebview?.callHandler('tongyuHost',JSON.stringify(ready));
  }catch(e){token='';showError(e);byId('state').textContent='加载失败，请重新打开消息页';}finally{starting=false;}
}
window.addEventListener('message', async event=>{
  const frame=byId('thread');
  if(event.source===frame.contentWindow && event.origin===location.origin){
    let data;try{data=typeof event.data==='string'?JSON.parse(event.data):event.data;}catch{return;}
    if(data?.type==='tongyu.group.ready' && data.groupId===selectedGroup)frame.contentWindow.postMessage({type:'tongyu.group.authenticate',groupId:selectedGroup,token},location.origin);
    if(data?.source==='tongyu' && data.type==='host-ready')frame.contentWindow.postMessage({type:'authenticate',identityToken:token},location.origin);
    if(data?.source==='tongyu' && data.type==='close')back();
    if(data?.type==='tongyu.group.authenticated' && inbox?.customCss){const style=frame.contentDocument.createElement('style');style.textContent=inbox.customCss;frame.contentDocument.head.append(style);}
    return;
  }
  if(event.source!==parent || event.origin!==parentOrigin || starting || token) return;
  let data;try{data=typeof event.data==='string'?JSON.parse(event.data):event.data;}catch{return;}
  if(data?.type!=='authenticate' || typeof data.identityToken!=='string' || !data.identityToken) return;
  await authenticate(data.identityToken);
});
byId('back').onclick=back;byId('retry').onclick=()=>void (token?refresh():authenticate(identity)).catch(showError);
window.addEventListener('pagehide',()=>clearInterval(timer));
if(window.__tongyuHostIdentity?.identityToken)void authenticate(window.__tongyuHostIdentity.identityToken);
else if(parentOrigin && parentOrigin!=='*')parent.postMessage({source:'tongyu',type:'host-ready'},parentOrigin);
else {byId('state').textContent='请从已登录的客户端打开消息页';}
