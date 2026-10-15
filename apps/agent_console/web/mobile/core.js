/* Account-scoped text snapshots only. Never cache tokens, media, or API responses
 * in the service worker; revocation is rechecked by the server on each request. */
const C='/api/v1/console',A='/api/v1/admin',G='/api/v1/groups';
const $=id=>document.getElementById(id);
const state={page:'messages',root:'messages',queue:'mine',search:'',inbox:'',resolved:false,session:null,me:null,ent:{features:{}},inboxes:[],conversations:[],groups:[],knowledge:[],categories:[],canned:[],notifications:[],agents:[],stats:{},current:null,messages:[],group:null,members:[],draft:'',note:false,quote:null,pending:[],sending:false,aiDraft:false,panel:null,emojiCat:'常用',emojiTab:'emoji',emojiQuery:'',recent:[],generation:0,offline:false,moreHistory:false,days:7};
function readStore(key,fallback=null){try{return JSON.parse(localStorage.getItem(key))??fallback}catch{return fallback}}
function writeStore(key,value){try{localStorage.setItem(key,JSON.stringify(value))}catch{}}
function sessionScope(){return state.me?`${state.me.tenant?.id||state.session?.tenant?.id}.${state.me.id}`:''}
function cachePrefix(){return 'tongyu.mobile.v1.'+sessionScope()+'.'}
function purgeCache(){for(const key of Object.keys(localStorage))if(key.startsWith(cachePrefix()))localStorage.removeItem(key)}
function cached(path){const saved=readStore(cachePrefix()+path);return saved&&Date.now()-saved.time<86400000?saved.data:null}
function cache(path,data){try{const keys=Object.keys(localStorage).filter(k=>k.startsWith(cachePrefix()));while(keys.length>80)localStorage.removeItem(keys.shift());writeStore(cachePrefix()+path,{time:Date.now(),data})}catch{}}
function canCache(path){return /^\/api\/v1\/console\/(inboxes|conversations(?:\/[\w-]+(?:\/(messages|pins))?)?)(\?|$)/.test(path)}
class ApiError extends Error{constructor(status,body){super(body.message||body.error||'操作未完成，请稍后重试');this.status=status;this.code=body.code||''}}
async function api(path,options={}){
 const token=state.session?.token;const headers={...(token?{Authorization:'Bearer '+token}:{}),...options.headers};if(options.body&&!(options.body instanceof FormData)){headers['Content-Type']='application/json';options.body=JSON.stringify(options.body)}
 try{if(!navigator.onLine)throw new TypeError('offline');const response=await fetch(path,{...options,signal:typeof AbortSignal.timeout==='function'?AbortSignal.timeout(path.endsWith('/assist')?90000:25000):undefined,headers,cache:'no-store',credentials:'same-origin'});const body=await response.json().catch(()=>({}));if(token&&token!==state.session?.token)throw new ApiError(499,{message:'账号已切换，请重新操作'});if(!response.ok){if(response.status===401&&token){purgeCache();forgetSession();go('login',false)}if(response.status===403||body.code==='CONVERSATION_NOT_FOUND'){purgeCache();if(body.code==='CONVERSATION_NOT_FOUND'&&state.current){state.current=null;state.messages=[];if(state.page==='chat')go('messages')}}throw new ApiError(response.status,body)}
  state.offline=false;networkNotice();if((!options.method||options.method==='GET')&&token&&canCache(path))cache(path,body);return body;
 }catch(error){if(error instanceof ApiError)throw error;state.offline=true;networkNotice();if((!options.method||options.method==='GET')&&canCache(path)){const data=cached(path);if(data)return data}throw new ApiError(0,{message:'网络未连接，请联网后重试；回复草稿已保留在本机'})}
}
const post=(path,body={})=>api(path,{method:'POST',body});
function networkNotice(){$('network').innerHTML=state.offline?'<div class="offline-notice">当前离线 · 可查看已保存文本，发送消息需要联网</div>':''}
function forgetSession(clearStorage=true){if(clearStorage){localStorage.removeItem('tongyu.mobile.session');for(const k of ['token','agent','tenant','inboxes','expiresAt'])localStorage.removeItem('flutter.relaydesk.'+k);}state.session=null;state.me=null;state.current=null;state.group=null;state.messages=[];state.conversations=[];state.groups=[];state.notifications=[];state.knowledge=[];state.canned=[];state.agents=[];state.draft='';state.pending=[];state.ent={features:{}};window.tongyuClearPush?.().catch(()=>{});closeSocket()}
function persistSession(){writeStore('tongyu.mobile.session',state.session)}
function isSupervisor(){return state.me?.role==='SUPERVISOR'}
function feature(name){return state.ent.features?.[name]===true}
function toast(text){$('toast').textContent=text;clearTimeout(state.toastTimer);state.toastTimer=setTimeout(()=>$('toast').textContent='',3200)}
function fail(error){toast(error.message||'操作未完成，请重试')}
async function runAction(fn){try{await fn()}catch(error){fail(error)}}
function time(value){if(!value)return '';const date=new Date(value);return isNaN(+date)?'':date.toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'})}
function day(value){if(!value)return '';return new Date(value).toLocaleDateString('zh-CN',{month:'long',day:'numeric'})}
function avatar(name,color='blue',badge=0){return `<div class="avatar ${color}">${esc((name||'访客').slice(0,1))}${badge?`<span class="badge">${Math.min(badge,99)}</span>`:''}</div>`}
function iconButton(name,label,code){return `<button class="icon" aria-label="${label}" onclick="${esc(code)}">${icon(name)}</button>`}
function header(title,actions='',back=null){return `<header class="header">${back?iconButton('back','返回',`backTo('${back}')`):''}<h2 class="${back?'small-title':''}">${esc(title)}</h2>${actions}</header>`}
function row(label,i,code,extra=''){return `<button class="list-row" onclick="${esc(code)}">${icon(i)}<span class="label">${esc(label)}</span>${extra}${icon('chevron','chev')}</button>`}
function search(placeholder,code,value=''){return `<div class="search">${icon('search')}<input aria-label="${placeholder}" placeholder="${placeholder}" value="${esc(value)}" oninput="${code}"></div>`}
function empty(text){return `<div class="empty">${icon('message')}<br>${esc(text)}</div>`}
function loading(){return '<div class="loading">正在加载…</div>'}
function sheet(title,body,description=''){closeInline();$('shade').hidden=false;$('sheet').hidden=false;$('sheet').innerHTML=`<div class="handle"></div><div class="sheet-title"><h3>${esc(title)}</h3>${iconButton('close','关闭',"closeSheet()")}</div>${description?`<div class="sheet-description">${esc(description)}</div>`:''}${body}`;labelFields($('sheet'))}
function closeSheet(){state.aiRequest=(state.aiRequest||0)+1;state.aiBusy=false;stopRecording(true);$('sheet').hidden=true;$('shade').hidden=true}
$('shade').onclick=closeSheet;
function sheetOption(i,label,code){return `<button class="sheet-option" onclick="${esc(code)}">${icon(i)}${esc(label)}</button>`}
async function copyText(text){try{await navigator.clipboard.writeText(text);toast('已复制')}catch{sheet('复制内容',`<textarea class="field" readonly rows="5">${esc(text)}</textarea>`,'请长按选择并复制')} }
function applyTheme(mode){writeStore('tongyu.mobile.theme',mode);const dark=mode==='dark'||mode==='system'&&matchMedia('(prefers-color-scheme:dark)').matches;document.documentElement.style.colorScheme=dark?'dark':'light';$('app').classList.toggle('dark',dark);const color=dark?'#1c222c':'#ffffff';document.body.style.background=color;document.documentElement.style.background=color;if($('mobile-loading')){$('mobile-loading').style.background=color;$('mobile-loading').style.color=dark?'#e2e8f0':'#425466'}document.querySelector('meta[name=theme-color]').content=color}
function viewport(){const vv=window.visualViewport;document.documentElement.dataset.keyboard=vv&&innerHeight-vv.height>120?'open':'closed';document.documentElement.style.setProperty('--app-height',(vv?.height||innerHeight)+'px')}
window.visualViewport?.addEventListener('resize',viewport);window.addEventListener('resize',viewport);viewport();applyTheme(readStore('tongyu.mobile.theme',readStore('flutter.relaydesk.themeMode','system')));
function nav(){const entries=[['messages','message','消息'],...(feature('groups')?[['groups','groups','群聊']]:[]),['overview','grid','工作台'],['more','user','我的']];$('nav').hidden=!entries.some(e=>e[0]===state.page);$('nav').innerHTML=entries.map(([p,i,l])=>`<button class="${state.page===p?'active':''}" onclick="go('${p}')">${icon(i)}${l}</button>`).join('')}
function routeHash(){const id=['chat','profile'].includes(state.page)?state.current?.id:['groupchat','call'].includes(state.page)?state.group?.id:state.page==='article'?state.article?.id:state.page==='editReply'?state.replyEdit?.id:null;return '#'+state.page+(id?'?id='+id:'')}

function backTo(page){go(page,false)}
function go(page,push=true){const from=state.page;if(['knowledge','canned'].includes(page)&&['messages','groups','overview','more','chat','groupchat'].includes(from))state.toolOrigin=from;saveLocalDraft();state.generation++;closeSheet();closeInline();state.page=page;if(['messages','groups','overview','more'].includes(page))state.root=page;if(push)history.pushState({page,from},'',location.pathname+location.search+routeHash());else history.replaceState({page},'',location.pathname+location.search+routeHash());render();const navigationGeneration=state.generation;$('screen').setAttribute?.('aria-busy','true');runAction(async()=>{try{await loadPage(page)}finally{if(navigationGeneration===state.generation)$('screen').setAttribute?.('aria-busy','false')}})}
window.addEventListener('popstate',()=>runAction(restoreRoute));
async function restoreRoute(){const [page,query='']=location.hash.slice(1).split('?'),id=new URLSearchParams(query).get('id');if(!state.me){go(page==='install'?'install':'login',false);return}
 if(page==='chat'&&id)return openChat(id,false);
 if(page==='groupchat'&&id)return openGroup(id,false);
 if(page==='profile'&&id){const r=await api(C+'/conversations/'+encodeURIComponent(id));state.current=r.conversation;state.visitor=r.visitor;return go('profile',false)}
 if(page==='call'&&id){const r=await api(G+'/'+encodeURIComponent(id));state.group=r.group;state.members=r.members||[];return go('call',false)}
 if(page==='article'&&id){state.knowledge=(await api(C+'/knowledge')).items||[];state.article=state.knowledge.find(k=>k.id===id);return go(state.article?'article':'knowledge',false)}
 if(page==='editReply'&&id){state.canned=(await api(C+'/canned-responses')).items||[];state.replyEdit=state.canned.find(k=>k.id===id);return go('editReply',false)}
 if(['chat','profile'].includes(page))return go('messages',false);if(['groupchat','call'].includes(page))return go('groups',false);if(page==='article')return go('knowledge',false);
 go(views[page]?page:'messages',false)}

function render(){const view=views[state.page];$('screen').innerHTML=view?view():empty('页面不可用');labelFields($('screen'));nav();if(state.page==='chat'||state.page==='groupchat'){syncInput();scrollBottom()}}
function visibleThread(){return ['chat','groupchat'].includes(state.page)}
function currentId(){return state.page==='groupchat'?state.group?.id:state.current?.id}
function groupMode(){return state.page==='groupchat'}
function draftKey(){return 'draft.'+(groupMode()?'g.':'c.')+currentId()}
function saveLocalDraft(){if(!state.me||!visibleThread()||!currentId())return;writeStore(cachePrefix()+draftKey(),{content:state.draft,note:state.note,time:Date.now()})}
function restoreDraft(){const row=readStore(cachePrefix()+draftKey());state.draft=row&&Date.now()-row.time<7*86400000?row.content:'';state.note=!!row?.note;state.quote=null;state.aiDraft=false;state.pending=[]}
let socket,refreshTimer,refreshBusy=false;
function closeSocket(){socket?.close();socket=null;clearInterval(refreshTimer)}
function connect(){closeSocket();if(!state.session)return;const url=new URL('/ws/console',location.href);url.protocol=location.protocol==='https:'?'wss:':'ws:';url.searchParams.set('token',state.session.token);socket=new WebSocket(url);socket.onmessage=event=>{try{const e=JSON.parse(event.data);incomingAlert(e).catch(()=>{});if(e.type==='conversation.scope.changed'){purgeCache();state.notifications=[];if(state.page==='notifications')runAction(()=>loadPage('notifications'))}if(e.type==='conversation.scope.changed'||e.type.startsWith('conversation.')||e.type.startsWith('message.')||e.type==='group.updated')scheduleRefresh()}catch{}};socket.onclose=()=>{};refreshTimer=setInterval(scheduleRefresh,5000)}
function scheduleRefresh(){if(refreshBusy||document.visibilityState!=='visible'||!state.me)return;refreshBusy=true;Promise.resolve().then(async()=>{if(state.page==='messages')await loadConversations(false);if(state.page==='chat')await refreshThread();if(state.page==='groupchat')await refreshGroupThread();if(state.page==='groups')await loadGroups(false)}).catch(()=>{}).finally(()=>refreshBusy=false)}
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'){if(state.me&&(!socket||socket.readyState===WebSocket.CLOSED))connect();scheduleRefresh()}});window.addEventListener('online',()=>{state.offline=false;networkNotice();scheduleRefresh()});window.addEventListener('offline',()=>{state.offline=true;networkNotice()});
async function bootstrap(){
 state.session=readStore('tongyu.mobile.session');if(!state.session){const token=readStore('flutter.relaydesk.token');if(token)state.session={token,agent:readStore('flutter.relaydesk.agent'),tenant:readStore('flutter.relaydesk.tenant')}}
 if(state.session?.token){state.me=state.session.agent;try{state.me=await api(C+'/me');state.session.agent=state.me;state.session.tenant=state.me.tenant||state.session.tenant;persistSession();const [inboxes,ent,canned]=await Promise.all([api(C+'/inboxes'),api(C+'/entitlements'),api(C+'/canned-responses')]);state.inboxes=inboxes.items||[];state.ent=ent;state.canned=canned.items||[];cache('profile',{me:state.me,inboxes:state.inboxes,ent,canned:state.canned});connect()}catch(error){if(!state.session){go('login',false);return}const saved=cached('profile');if(error.status===0&&saved){Object.assign(state,saved);state.ent=saved.ent;state.offline=true}else{forgetSession();go('login',false);return}}}
 fetch('/console/pwa-release.json',{cache:'no-cache'}).then(r=>r.ok?r.json():null).then(r=>{state.release=r}).catch(()=>{});if(state.me){const id=new URLSearchParams(location.search).get('conversation');if(id){history.replaceState({},'',location.pathname+'#chat?id='+encodeURIComponent(id));await openChat(id,false)}else await restoreRoute()}else go('login',false);
 $('mobile-loading')?.remove();
}
async function login(){const button=$('login-button');button.disabled=true;try{const result=await post(C+'/login',{tenantSlug:$('tenant').value.trim(),email:$('username').value.trim(),password:$('password').value});purgeCache();forgetSession();state.session={token:result.token,agent:result.agent,tenant:result.tenant};state.me=result.agent;persistSession();history.replaceState({page:'messages'},'',location.pathname+location.search+'#messages');await bootstrap()}catch(error){fail(error)}finally{if($('login-button'))$('login-button').disabled=false;$('mobile-loading')?.remove()}}
async function logout(){saveLocalDraft();try{await post(C+'/logout')}catch{}purgeCache();forgetSession();go('login',false)}
setInterval(()=>{const status=window.tongyuPwaStatus?JSON.parse(window.tongyuPwaStatus()):{};if(status.update&&status.updateVersion)window.tongyuPwaAction('claimUpdatePrompt').then(result=>{if(result==='show')sheet('发现新版本',`<div class="detail-value">${esc(status.updateRelease?.version||'通语更新')}</div><div class="note-card">${(status.updateRelease?.notes||[]).map(n=>esc(n)).join('<br>')}</div><button class="primary" style="margin-top:20px" onclick="saveLocalDraft();window.tongyuPwaAction('update').then(toast)">保存草稿并更新</button><button class="secondary" onclick="closeSheet()">稍后更新</button>`)});},4000);

window.addEventListener('storage',event=>{if(state.platform||event.key!=='tongyu.mobile.session')return;const next=readStore('tongyu.mobile.session');if(next?.token===state.session?.token)return;purgeCache();forgetSession(false);$('screen').innerHTML=loading();$('nav').hidden=true;runAction(bootstrap)});
navigator.serviceWorker?.addEventListener('message',event=>{if(event.data?.type==='OPEN_CONVERSATION'&&state.me&&typeof event.data.id==='string')runAction(()=>openChat(event.data.id))});
window.addEventListener('message',event=>{if(event.origin===location.origin&&event.source===$('call-frame')?.contentWindow&&event.data?.type==='tongyu-call-close')backTo('groupchat')});

let fieldIndex=0;function labelFields(root){for(const label of root.querySelectorAll?.("label.field-label")||[]){const control=label.nextElementSibling;if(control?.matches("input,textarea,select")){if(!control.id)control.id="form-field-"+(++fieldIndex);label.htmlFor=control.id}}}

function customerName(c){const name=(c?.visitorName||c?.displayName||"").trim();return name&&name!=="访客"?name:"访客 "+String(c?.visitorId||c?.id||"").slice(0,6)}
