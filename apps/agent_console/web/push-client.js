/* 通知授权和订阅必须由用户点击触发；准备阶段不请求通知权限。 */
let tongyuPushContext=null, tongyuPushPending=null, tongyuPushGeneration=0;
let tongyuPushResult={stage:'idle',message:'尚未开启浏览器通知'};
const pushWait=(promise,message)=>new Promise((resolve,reject)=>{
  const timer=setTimeout(()=>reject(new Error(message)),20000);
  Promise.resolve(promise).then(value=>{clearTimeout(timer);resolve(value)},error=>{clearTimeout(timer);reject(error)});
});
function pushEnvironment(){
  const ios=/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
  const installed=navigator.standalone===true||window.matchMedia?.('(display-mode: standalone)').matches===true;
  if(ios&&!installed)throw new Error('请先在 Safari 中添加到主屏幕，再从主屏幕图标打开通语，开启手机系统通知');
  if(!window.isSecureContext||!navigator.serviceWorker||!('PushManager' in window)||!('Notification' in window))
    throw new Error('当前环境不支持浏览器通知。请使用 HTTPS 打开。iPhone 请使用 iOS 16.4 或以上，并从主屏幕打开');
  if(Notification.permission==='denied')throw new Error('系统通知被阻止，请在浏览器或系统设置中允许通知后重新检查');
}
// 正式工作台在 /console/。本机预览开在站点根目录，服务工作线程必须跟页面同一目录，否则订阅注册会 404。
function pushScope(){
  const path=location.pathname||'/';
  if(path==='/console'||path.startsWith('/console/'))return '/console/';
  const dir=new URL('.',location.href).pathname;
  return dir.endsWith('/')?dir:dir+'/';
}
function pushOrigin(server){
  try{
    const url=new URL(server||location.origin);
    if(url.protocol!=='https:'&&url.protocol!=='http:')return location.origin;
    return url.origin;
  }catch(_){return location.origin}
}
function pushApi(server,path){
  const origin=pushOrigin(server);
  return origin===location.origin?path:origin+path;
}
// 页面开久后 serviceWorker.ready 可能一直不返回。已有注册就直接用；没有活动 worker 时让等待中的版本接管，否则订阅发不出去。
async function consolePushRegistration(){
  const scope=pushScope();
  let registration=await navigator.serviceWorker.getRegistration(scope);
  if(!registration){
    await navigator.serviceWorker.register(scope+'tongyu-push-sw.js',{scope});
    registration=await navigator.serviceWorker.getRegistration(scope);
  }
  if(registration&&!registration.active&&registration.waiting){
    registration.waiting.postMessage({type:'ACTIVATE_QUIET'});
    await new Promise(resolve=>{
      let settled=false;
      const finish=()=>{
        if(settled)return;
        settled=true;
        clearTimeout(timer);
        navigator.serviceWorker.removeEventListener('controllerchange', finish);
        resolve();
      };
      const timer=setTimeout(finish, 2000);
      navigator.serviceWorker.addEventListener('controllerchange', finish);
    });
    registration=await navigator.serviceWorker.getRegistration(scope)||registration;
  }
  if(registration?.pushManager)return registration;
  return navigator.serviceWorker.ready;
}
window.tongyuPushStatus=()=>({...tongyuPushResult,permission:window.Notification?.permission||'unsupported'});
window.tongyuPreparePush=function(server,token){
  try{
    pushEnvironment();
    if(!token)throw new Error('请先登录客服账号');
  }catch(error){tongyuPushResult={stage:'error',message:error.message};return Promise.reject(error)}
  if(tongyuPushPending?.token===token)return tongyuPushPending.promise;
  // 核对开始时不清已有注册。页面开久后核对和点击会叠在一起，清掉后这次点击等不到授权弹窗。
  if(tongyuPushContext&&(tongyuPushContext.token!==token||tongyuPushContext.server!==pushOrigin(server))){
    tongyuPushGeneration+=1;
    tongyuPushContext=null;
  }
  const generation=tongyuPushGeneration;
  if(tongyuPushResult.stage!=='enabled')tongyuPushResult={stage:'preparing',message:'正在准备浏览器通知…'};
  const promise=(async()=>{
    const registration=await pushWait(consolePushRegistration(),'通知服务尚未就绪，请联网后重试');
    const response=await fetch(pushApi(server,'/api/v1/console/push/key'),{headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(15000),cache:'no-store'});
    if(!response.ok)throw new Error(response.status===401?'登录已失效，请重新登录后开启通知':'推送服务暂不可用，请稍后重试');
    const config=await response.json();
    const encoded=config.publicKey.replace(/-/g,'+').replace(/_/g,'/');
    const key=Uint8Array.from(atob(encoded+'='.repeat((4-encoded.length%4)%4)),c=>c.charCodeAt(0));
    let subscription=await pushWait(registration.pushManager.getSubscription(),'读取本机通知状态超时，请重试');
    if(subscription&&typeof subscription.expirationTime==='number'&&subscription.expirationTime<=Date.now()){
      try{await subscription.unsubscribe();}catch(_){}
      subscription=null;
    }
    if(generation!==tongyuPushGeneration)throw new Error('账号已切换，请重新开启通知');
    tongyuPushContext={token,server:pushOrigin(server),registration,key,subscription,generation};
    let enabled=false;
    if(subscription&&Notification.permission==='granted'){
      const status=await fetch(pushApi(server,'/api/v1/console/push/subscription/status'),{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({endpoint:subscription.endpoint}),signal:AbortSignal.timeout(15000),cache:'no-store'});
      if(!status.ok)throw new Error('读取通知状态失败，请重试');
      enabled=(await status.json()).enabled===true;
      // 浏览器订阅还在，但上次登录会话已失效时挂到当前会话，否则会一直显示未开启。
      if(!enabled&&generation===tongyuPushGeneration){
        const saved=await fetch(pushApi(server,'/api/v1/console/push/subscription'),{method:'PUT',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({endpoint:subscription.endpoint,keys:subscription.toJSON().keys}),signal:AbortSignal.timeout(15000)});
        if(saved.ok)enabled=(await saved.json().catch(()=>null))?.status==='OK';
      }
    }
    if(generation!==tongyuPushGeneration)throw new Error('账号已切换，请重新检查通知');
    tongyuPushResult=enabled?{stage:'enabled',message:'系统通知已开启'}:{stage:'ready',message:'系统通知已关闭，开启后可接收后台提醒'};
  })().catch(error=>{if(generation===tongyuPushGeneration)tongyuPushResult={stage:'error',message:error.name==='TimeoutError'?'网络连接超时，请重试':error.message};throw error;})
    .finally(()=>{if(tongyuPushPending?.promise===promise)tongyuPushPending=null});
  tongyuPushPending={token,promise};return promise;
};
function beginPushSubscription(context){
  if(context.subscription)return Promise.resolve(context.subscription);
  return context.registration.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:context.key});
}
window.tongyuEnablePush=async function(server,token){
  try{
    const origin=pushOrigin(server);
    const context=tongyuPushContext;
    const ready=!!(context&&context.token===token&&context.server===origin&&context.registration&&context.key);
    // 授权和订阅都要在这次点击里发出。先等网络或先播声音，Chrome 不会出授权窗，订阅也会被拒绝。
    let permissionPrompt=null;
    if(typeof Notification!=='undefined'&&Notification.permission==='default'){
      permissionPrompt=Notification.requestPermission();
    }
    let pending=null;
    if(typeof Notification!=='undefined'&&Notification.permission==='granted'&&ready){
      pending=beginPushSubscription(context);
      tongyuPushResult={stage:'subscribing',message:'正在把这台浏览器登记到消息通知…'};
    }
    pushEnvironment();
    if(!token)throw new Error('请先登录客服账号');
    if(permissionPrompt){
      const permission=await permissionPrompt;
      if(permission!=='granted')throw new Error('未获得系统通知授权，请在 Chrome 弹窗中选择允许');
    }
    let subscription;
    if(pending){
      subscription=await pushWait(pending,'连接系统通知服务超时，请检查网络后重试');
    }else{
      let next=tongyuPushContext;
      if(!next||next.token!==token||next.server!==origin||!next.registration||!next.key){
        await window.tongyuPreparePush(server,token);
        next=tongyuPushContext;
      }
      if(!next||next.token!==token||next.server!==origin||next.generation!==tongyuPushGeneration||!next.registration||!next.key){
        throw new Error('通知已准备好，请再点一次完成订阅');
      }
      tongyuPushResult={stage:'subscribing',message:'正在把这台浏览器登记到消息通知…'};
      subscription=await pushWait(beginPushSubscription(next),'连接系统通知服务超时，请检查网络后重试');
    }
    const active=tongyuPushContext;
    if(!active||active.generation!==tongyuPushGeneration)throw new Error('账号已切换，请重新开启通知');
    active.subscription=subscription;
    // 浏览器还会返回 expirationTime；接口仅接收发送推送所需字段。
    const {endpoint,keys}=subscription.toJSON();
    const saved=await fetch(pushApi(server,'/api/v1/console/push/subscription'),{method:'PUT',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({endpoint,keys}),signal:AbortSignal.timeout(15000)});
    if(!saved.ok)throw new Error(saved.status===401?'登录已失效，请重新登录后开启通知':'保存浏览器推送订阅失败，请重试');
    const confirmation=await saved.json().catch(()=>null);
    if(confirmation?.status!=='OK')throw new Error('未能确认浏览器推送订阅，请重试');
    if(active.generation!==tongyuPushGeneration)throw new Error('账号已切换，请重新开启通知');
    const iosDevice=/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
    tongyuPushResult={stage:'enabled',message:iosDevice?'手机系统通知已开启，订阅已保存。锁屏声音由手机通知设置控制':'浏览器通知已开启。关闭标签后仍会收到提醒'};
    return tongyuPushResult.message;
  }catch(error){
    let message=error.message;
    if(error.name==='InvalidStateError'){
      tongyuPushContext=null;
      message='通知服务已更新，请再点一次以允许浏览器推送';
    }
    if(error.name==='NotAllowedError'){
      const iosDevice=/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
      message=Notification.permission==='denied'
        ?(iosDevice?'系统通知未获允许，请到手机设置 → 通知 → 通语中允许通知':'系统通知未获允许，请在浏览器站点设置或系统通知里允许 Chrome')
        :'未获得系统通知授权，请再次点击开启，并在弹窗中选择允许';
    }
    if(error.name==='TimeoutError')message='网络连接超时，请重试';
    tongyuPushResult={stage:'error',message};throw new Error(message);
  }
};
window.tongyuDisablePush = async function(server, token) {
  ++tongyuPushGeneration;tongyuPushContext=null;tongyuPushPending=null;
  const registration=await navigator.serviceWorker?.getRegistration(pushScope());
  const subscription=await registration?.pushManager.getSubscription();
  if(!subscription){tongyuPushResult={stage:'idle',message:'系统通知已关闭'};return;}
  const response=await fetch(pushApi(server,'/api/v1/console/push/subscription'),{method:'DELETE',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({endpoint:subscription.endpoint})});
  if(!response.ok)throw new Error('关闭推送失败');
  if(!await subscription.unsubscribe())throw new Error('撤销本机通知订阅失败，请重试');
  tongyuPushResult={stage:'idle',message:'系统通知已关闭'};
};
// 同源多标签页原子领取提醒，避免两个工作台同时播报同一条消息。
window.tongyuClaimMessageAlert=async function(id){
  const claim=()=>{
    let history=[];try{history=JSON.parse(localStorage.getItem('tongyu.alertHistory')||'[]');}catch(_){}
    if(history.includes(id))return false;
    history.push(id);localStorage.setItem('tongyu.alertHistory',JSON.stringify(history.slice(-300)));return true;
  };
  return navigator.locks?navigator.locks.request('tongyu-message-alert',claim):claim();
};

// 退出账号时撤销本机订阅，即使服务端暂时不可达也不继续接收前一账号的提醒。
window.tongyuClearPush = async function() {
  ++tongyuPushGeneration;tongyuPushContext=null;tongyuPushPending=null;
  tongyuPushResult={stage:'idle',message:'尚未开启浏览器通知'};
  const registration=await navigator.serviceWorker?.getRegistration(pushScope());
  const subscription=await registration?.pushManager.getSubscription();
  if(subscription)await subscription.unsubscribe();
  await navigator.clearAppBadge?.();
};
// 系统通知由服务工作线程登记展示。页面直接 new Notification 时，标签开久后浏览器会把后台通知丢掉。
window.tongyuShowDeskNotice=function(title, body, tag){
  const text=String(title||'客户');
  const detail=String(body||'');
  const name=typeof tag==='string'&&tag.indexOf('tongyu-')===0?tag:'tongyu-message';
  const icon=pushScope()+'icons/Icon-192.png';
  const options={body:detail, tag:name, icon, badge:icon};
  const fallback=()=>{ try{ if(typeof Notification!=='undefined') new Notification(text,{body:detail, tag:name}); }catch(_){} };
  if(typeof Notification==='undefined'||Notification.permission!=='granted')return;
  const lookup=navigator.serviceWorker?.getRegistration?.(pushScope());
  if(!lookup){ fallback(); return; }
  lookup.then(found=>{
    if(found&&typeof found.showNotification==='function')return found.showNotification(text, options).catch(fallback);
    fallback();
  }).catch(fallback);
};
