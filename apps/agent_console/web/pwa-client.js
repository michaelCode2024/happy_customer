/* 安装与更新必须由用户主动触发；更新不刷新未提交的回复。 */
(function(){
  let installEvent=null, registration=null, failure='', updating=false, shellReady=false, waitingVersion='', waitingRelease={};
  const ios=()=>/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
  const embedded=()=>/MicroMessenger|QQ\/|FBAN|FBAV|Instagram|Line\//i.test(navigator.userAgent);
  const installed=()=>matchMedia('(display-mode: standalone)').matches||matchMedia('(display-mode: fullscreen)').matches||navigator.standalone===true;
  const installChanged=()=>window.dispatchEvent(new CustomEvent('tongyu:installchange'));
  // iOS 26 主屏幕：启动瞬间采样贴边实色；冷启动采样条先压在启动遮罩上，首帧后再降回画布下。
  let chromeReady=false;
  function placeSafariTints(){
    if(!ios())return;
    const standalone=installed();
    if(standalone)document.documentElement.classList.add('tongyu-ios-standalone');
    else document.documentElement.classList.remove('tongyu-ios-standalone');
    const topTint=document.getElementById('safari-top-tint');
    const bottomTint=document.getElementById('safari-bottom-tint');
    const z=standalone&&!chromeReady?'100000':'0';
    if(topTint){
      topTint.style.display=standalone?'block':'none';
      topTint.style.height='12px';
      topTint.style.zIndex=z;
      if(!topTint.style.backgroundColor)topTint.style.backgroundColor='#ffffff';
    }
    if(bottomTint){
      bottomTint.style.display=standalone?'block':'none';
      bottomTint.style.height='12px';
      bottomTint.style.zIndex=z;
      if(!bottomTint.style.backgroundColor)bottomTint.style.backgroundColor='#ffffff';
    }
  }
  window.tongyuPlaceSafariTints=placeSafariTints;
  if(ios())placeSafariTints();
  window.addEventListener('flutter-first-frame',()=>{chromeReady=true;placeSafariTints();},{once:true});
  window.addEventListener('resize',placeSafariTints);
  window.addEventListener('orientationchange',placeSafariTints);
  window.addEventListener('beforeinstallprompt',event=>{event.preventDefault();installEvent=event;installChanged();});
  window.addEventListener('appinstalled',()=>{installEvent=null;installChanged();});
  const ready= async()=>{
    if(!isSecureContext||!('serviceWorker' in navigator))throw new Error('当前浏览器不支持 PWA，请使用 HTTPS 和支持的浏览器');
    const existing=await navigator.serviceWorker.getRegistration('/console/');
    try { registration=await navigator.serviceWorker.register('/console/tongyu-push-sw.js',{scope:'/console/',updateViaCache:'none'}); }
    catch(error) { if(!existing)throw error; registration=existing; }
    registration.addEventListener('updatefound',()=>{
      const worker=registration.installing;
      worker?.addEventListener('statechange',()=>{
        if(worker.state==='redundant')failure='离线资源准备失败，请联网后重试';
      });
    });
    if(navigator.onLine) registration.update().catch(()=>{});
    return registration;
  };
  window.tongyuPwaReady=ready();
  window.tongyuPwaReady.catch(error=>{failure=error.message;});
  const promptedVersions=new Set();
  function checkWaiting(){
    if(!registration?.waiting){waitingVersion='';waitingRelease={};return;}
    const channel=new MessageChannel();
    channel.port1.onmessage=event=>{waitingVersion=event.data?.version||'';waitingRelease=event.data?.release||{};channel.port1.close();};
    registration.waiting.postMessage({type:'SHELL_STATUS'},[channel.port2]);
    setTimeout(()=>channel.port1.close(),2000);
  }
  async function checkShell(){
    checkWaiting();
    const controller=navigator.serviceWorker?.controller;
    if(!controller){shellReady=false;return;}
    const channel=new MessageChannel();
    channel.port1.onmessage=event=>{shellReady=event.data?.ready===true;channel.port1.close();};
    controller.postMessage({type:'SHELL_STATUS'},[channel.port2]);
    setTimeout(()=>channel.port1.close(),2000);
  }
  setInterval(checkShell,3000);checkShell();
  navigator.serviceWorker?.addEventListener('controllerchange',()=>{if(updating)location.reload();});
  window.tongyuPwaStatus=()=>JSON.stringify({supported:!!navigator.serviceWorker&&isSecureContext,offline:!navigator.onLine,
    installed:installed(),canInstall:!!installEvent,ready:shellReady,
    update:!!registration?.waiting,updateVersion:waitingVersion,updateRelease:waitingRelease,error:failure,ios:ios(),embedded:embedded(),android:/Android/i.test(navigator.userAgent)});
  window.tongyuPwaAction=async action=>{
    if(action==='claimUpdatePrompt'){
      if(!registration?.waiting||!waitingVersion)return '';
      const key='tongyu.update.prompt.'+waitingVersion;
      if(promptedVersions.has(key))return '';
      try{if(sessionStorage.getItem(key))return '';sessionStorage.setItem(key,'1');}catch(_){}
      promptedVersions.add(key);return 'show';
    }
    if(action==='consumeInstallRequest'){
      const url=new URL(location.href);url.searchParams.delete('install');history.replaceState(history.state,'',url);return '';
    }
    if(action==='install'){
      if(installed())return '已作为应用打开';
      if(installEvent){const event=installEvent;installEvent=null;try{await event.prompt();const choice=await event.userChoice;return choice.outcome==='accepted'?'请完成浏览器的安装确认，然后从桌面图标打开通语':'已取消安装，可稍后在个人设置中重新安装';}finally{installChanged();}}
      return /iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1)?'请在 Safari 中点「分享 → 添加到主屏幕」，如有「作为 Web App 打开」请保持开启':'请使用浏览器菜单中的「安装通语」或「安装应用」；首次访问请等待离线资源准备完成';
    }
    if(action==='checkUpdate'){
      const reg=await window.tongyuPwaReady;await reg.update();
      return reg.waiting?'新版本已下载，保存草稿后点击「更新应用」':reg.installing?'正在下载新版本，完成后会显示更新提示':'当前没有可用更新';
    }
    if(action==='update'){
      const reg=await window.tongyuPwaReady;
      if(reg.waiting){updating=true;reg.waiting.postMessage({type:'ACTIVATE_UPDATE'});return '正在更新…';}
      await reg.update();return '已检查更新；有新版本时会显示更新入口';
    }
    if(action==='retry'){failure='';if(!registration)registration=await ready();await registration.update();return '已重新检查离线资源与更新';}
    if(action==='persist'){
      if(!navigator.storage?.persist)return '当前浏览器不提供持久存储申请；系统仍可能清理本机缓存';
      return await navigator.storage.persist()?'已获准保留本机数据':'浏览器未授予持久存储；系统仍可能清理缓存';
    }
    return '';
  };
  window.tongyuSetBadge=count=>{if(count>0)navigator.setAppBadge?.(count).catch(()=>{});else navigator.clearAppBadge?.().catch(()=>{});};
  window.addEventListener('online',()=>registration?.update().catch(()=>{}));
  setInterval(()=>{if(document.visibilityState==='visible'&&navigator.onLine)registration?.update().catch(()=>{});},60*60*1000);
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible'&&navigator.onLine)registration?.update().catch(()=>{});});
})();
