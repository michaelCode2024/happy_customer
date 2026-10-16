/* 通知授权和订阅必须由用户点击触发；准备阶段不请求通知权限。 */
let tongyuPushContext=null, tongyuPushPending=null, tongyuPushGeneration=0;
let tongyuPushResult={stage:'idle',message:'尚未开启手机系统通知'};
const pushWait=(promise,message)=>new Promise((resolve,reject)=>{
  const timer=setTimeout(()=>reject(new Error(message)),20000);
  Promise.resolve(promise).then(value=>{clearTimeout(timer);resolve(value)},error=>{clearTimeout(timer);reject(error)});
});
function pushEnvironment(){
  const ios=/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
  const installed=navigator.standalone===true||window.matchMedia?.('(display-mode: standalone)').matches===true;
  if(ios&&!installed)throw new Error('请先在 Safari 中添加到主屏幕，再从主屏幕图标打开通语，开启手机系统通知');
  if(!window.isSecureContext||!navigator.serviceWorker||!('PushManager' in window)||!('Notification' in window))
    throw new Error('当前环境不支持手机系统通知。iPhone 请使用 iOS 16.4 或以上，并从主屏幕打开');
  if(Notification.permission==='denied')throw new Error('系统通知被阻止，请在浏览器或系统设置中允许通知后重新检查');
}
window.tongyuPushStatus=()=>({...tongyuPushResult,permission:window.Notification?.permission||'unsupported'});
window.tongyuPreparePush=function(server,token){
  try{
    pushEnvironment();
    if(new URL(server||location.origin).origin!==location.origin)throw new Error('请在客服服务的同源页面开启推送');
    if(!token)throw new Error('请先登录客服账号');
  }catch(error){tongyuPushResult={stage:'error',message:error.message};return Promise.reject(error)}
  if(tongyuPushPending?.token===token)return tongyuPushPending.promise;
  const generation=++tongyuPushGeneration;
  tongyuPushContext=null;tongyuPushResult={stage:'preparing',message:'正在准备手机系统通知…'};
  const promise=(async()=>{
    const registration=await pushWait((async()=>{
      await (window.tongyuPwaReady||navigator.serviceWorker.register('/console/tongyu-push-sw.js',{scope:'/console/'}));
      return navigator.serviceWorker.ready;
    })(),'通知服务尚未就绪，请联网后重试');
    const response=await fetch('/api/v1/console/push/key',{headers:{Authorization:'Bearer '+token},signal:AbortSignal.timeout(15000),cache:'no-store'});
    if(!response.ok)throw new Error(response.status===401?'登录已失效，请重新登录后开启通知':'推送服务暂不可用，请稍后重试');
    const config=await response.json();
    const encoded=config.publicKey.replace(/-/g,'+').replace(/_/g,'/');
    const key=Uint8Array.from(atob(encoded+'='.repeat((4-encoded.length%4)%4)),c=>c.charCodeAt(0));
    const subscription=await pushWait(registration.pushManager.getSubscription(),'读取本机通知状态超时，请重试');
    if(generation!==tongyuPushGeneration)throw new Error('账号已切换，请重新开启通知');
    tongyuPushContext={token,registration,key,subscription,generation};
    let enabled=false;
    if(subscription&&Notification.permission==='granted'){
      const status=await fetch('/api/v1/console/push/subscription/status',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({endpoint:subscription.endpoint}),signal:AbortSignal.timeout(15000),cache:'no-store'});
      if(!status.ok)throw new Error('读取通知状态失败，请重试');
      enabled=(await status.json()).enabled===true;
    }
    if(generation!==tongyuPushGeneration)throw new Error('账号已切换，请重新检查通知');
    tongyuPushResult=enabled?{stage:'enabled',message:'系统通知已开启'}:{stage:'ready',message:'系统通知已关闭，开启后可接收后台提醒'};
  })().catch(error=>{if(generation===tongyuPushGeneration)tongyuPushResult={stage:'error',message:error.name==='TimeoutError'?'网络连接超时，请重试':error.message};throw error;})
    .finally(()=>{if(tongyuPushPending?.promise===promise)tongyuPushPending=null});
  tongyuPushPending={token,promise};return promise;
};
window.tongyuEnablePush=async function(server,token){
  try{
    pushEnvironment();
    if(new URL(server||location.origin).origin!==location.origin)throw new Error('服务地址不一致');
    if(tongyuPushContext?.token!==token){
      await window.tongyuPreparePush(server,token);
      throw new Error('通知已准备好，请再次点击「开启手机系统通知」以申请系统授权');
    }
    const context=tongyuPushContext;
    // subscribe 在点击调用栈内执行；此前不等待权限、注册 worker 或网络请求。
    const pending=context.subscription||context.registration.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:context.key});
    tongyuPushResult={stage:'subscribing',message:'请在系统弹窗中允许通知，正在连接通知服务…'};
    const subscription=await pushWait(pending,'连接系统通知服务超时，请检查网络后重试');
    if(context.generation!==tongyuPushGeneration)throw new Error('账号已切换，请重新开启通知');
    context.subscription=subscription;
    // 浏览器还会返回 expirationTime；接口仅接收发送推送所需字段。
    const {endpoint,keys}=subscription.toJSON();
    const saved=await fetch('/api/v1/console/push/subscription',{method:'PUT',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({endpoint,keys}),signal:AbortSignal.timeout(15000)});
    if(!saved.ok)throw new Error(saved.status===401?'登录已失效，请重新登录后开启通知':'保存手机推送订阅失败，请重试');
    const confirmation=await saved.json().catch(()=>null);
    if(confirmation?.status!=='OK')throw new Error('未能确认手机推送订阅，请重试');
    if(context.generation!==tongyuPushGeneration)throw new Error('账号已切换，请重新开启通知');
    tongyuPushResult={stage:'enabled',message:'手机系统通知已开启，订阅已保存。锁屏声音由手机通知设置控制'};
    return tongyuPushResult.message;
  }catch(error){
    let message=error.message;
    if(error.name==='NotAllowedError')message=Notification.permission==='denied'?'系统通知未获允许，请到手机设置 → 通知 → 通语中允许通知':'未获得系统通知授权，请再次点击开启，并在弹窗中选择允许';
    if(error.name==='TimeoutError')message='网络连接超时，请重试';
    tongyuPushResult={stage:'error',message};throw new Error(message);
  }
};
window.tongyuDisablePush = async function(server, token) {
  ++tongyuPushGeneration;tongyuPushContext=null;tongyuPushPending=null;
  const registration=await navigator.serviceWorker?.getRegistration('/console/');
  const subscription=await registration?.pushManager.getSubscription();
  if(!subscription){tongyuPushResult={stage:'idle',message:'系统通知已关闭'};return;}
  if(new URL(server||location.origin).origin!==location.origin)throw new Error('服务地址不一致');
  const response=await fetch('/api/v1/console/push/subscription',{method:'DELETE',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({endpoint:subscription.endpoint})});
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
  tongyuPushResult={stage:'idle',message:'尚未开启手机系统通知'};
  const registration=await navigator.serviceWorker?.getRegistration('/console/');
  const subscription=await registration?.pushManager.getSubscription();
  if(subscription)await subscription.unsubscribe();
  await navigator.clearAppBadge?.();
};
