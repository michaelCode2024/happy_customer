/* 只在用户主动开启时订阅；令牌不写入 service worker 或浏览器持久存储。 */
window.tongyuEnablePush = async function(server, token) {
  if (!window.isSecureContext || !('serviceWorker' in navigator) || !('PushManager' in window))
    throw new Error('此浏览器不支持后台推送');
  const permission = await Notification.requestPermission();
  if (permission !== 'granted') return '通知未获允许，请在系统或浏览器设置中允许通语通知';
  const origin = new URL(server || location.origin).origin;
  if (origin !== location.origin) throw new Error('请在客服服务的同源页面开启推送');
  const registration = await (window.tongyuPwaReady || navigator.serviceWorker.register('/console/tongyu-push-sw.js', {scope:'/console/'}));
  const ready = await navigator.serviceWorker.ready;
  const response = await fetch('/api/v1/console/push/key', {headers:{Authorization:'Bearer '+token}});
  if (!response.ok) throw new Error('推送服务暂不可用');
  const config=await response.json();
  const encoded=config.publicKey.replace(/-/g,'+').replace(/_/g,'/');
  const key=Uint8Array.from(atob(encoded+'='.repeat((4-encoded.length%4)%4)), c=>c.charCodeAt(0));
  let subscription=await ready.pushManager.getSubscription();
  if(!subscription) subscription=await ready.pushManager.subscribe({userVisibleOnly:true, applicationServerKey:key});
  const saved=await fetch('/api/v1/console/push/subscription',{method:'PUT',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(subscription.toJSON())});
  if(!saved.ok) {await subscription.unsubscribe();throw new Error('保存推送订阅失败');}
  return '后台消息提醒已开启；锁屏声音请在系统通知设置中允许';
};
window.tongyuDisablePush = async function(server, token) {
  const registration=await navigator.serviceWorker?.getRegistration('/console/');
  const subscription=await registration?.pushManager.getSubscription();
  if(!subscription)return;
  if(new URL(server||location.origin).origin!==location.origin)throw new Error('服务地址不一致');
  const response=await fetch('/api/v1/console/push/subscription',{method:'DELETE',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({endpoint:subscription.endpoint})});
  if(!response.ok)throw new Error('关闭推送失败');
  await subscription.unsubscribe();
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
  const registration=await navigator.serviceWorker?.getRegistration('/console/');
  const subscription=await registration?.pushManager.getSubscription();
  if(subscription)await subscription.unsubscribe();
  await navigator.clearAppBadge?.();
};
