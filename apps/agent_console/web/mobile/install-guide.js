(() => {
  const dismissKey='tongyu.pwa.install.dismissedUntil';
  let dismissedUntil=0,appInstalled=false,busy=false;
  try{dismissedUntil=Number(localStorage.getItem(dismissKey))||0}catch{}
  const ios=()=>/iPhone|iPad|iPod/i.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
  const mobile=()=>ios()||/Android|Mobile/i.test(navigator.userAgent);
  const embedded=()=>/MicroMessenger|QQ\/|FBAN|FBAV|Instagram|Line\//i.test(navigator.userAgent);
  function status(){try{return JSON.parse(window.tongyuPwaStatus?.()||'{}')}catch{return {}}}
  const standalone=()=>appInstalled||navigator.standalone===true||matchMedia('(display-mode: standalone)').matches||matchMedia('(display-mode: fullscreen)').matches;
  function dismiss(){dismissedUntil=Date.now()+7*86400000;try{localStorage.setItem(dismissKey,String(dismissedUntil))}catch{}refresh()}
  function refresh(){
    const app=$('app');if(!app)return;
    let banner=$('install-invitation');
    if(!mobile()||standalone()||Date.now()<dismissedUntil||state.page==='install'){banner?.remove();return}
    if(!banner){banner=document.createElement('aside');banner.id='install-invitation';banner.className='install-invitation';banner.setAttribute('aria-label','安装通语到桌面');app.insertBefore(banner,$('screen'))}
    const native=status().canInstall&&!ios()&&!embedded();
    banner.innerHTML=`<img src="/console/favicon.svg" width="36" height="36" alt=""><div><strong>把通语添加到桌面</strong><small>下次轻点图标，直接进入工作台</small></div><button type="button" class="install-invite-action">${native?'安装':'查看步骤'}</button><button type="button" class="install-invite-close" aria-label="暂不显示安装提示">${icon('close')}</button>`;
    banner.querySelector('.install-invite-action').onclick=()=>native?install():go('install');banner.querySelector('.install-invite-close').onclick=dismiss;
  }
  function guide(){
    const apple=ios(),inApp=embedded(),chromeIOS=apple&&/CriOS/i.test(navigator.userAgent),native=status().canInstall&&!apple&&!inApp;
    let steps;
    if(inApp)steps=[['在系统浏览器中打开','轻点当前浏览器的更多菜单，选择在 Safari 或浏览器中打开。','more'],['打开安装菜单',apple?'在 Safari 的工具栏或更多菜单中找到分享。':'在浏览器菜单中查找「安装应用」或「添加到主屏幕」。',apple?'share':'plus'],['添加到桌面','按照浏览器提示确认，之后从桌面图标打开通语。','check']];
    else if(apple)steps=[['打开 Safari',chromeIOS?'复制当前页面地址，在 Safari 中打开。':'在 Safari 中打开通语客服页面。','link'],['找到分享按钮','在工具栏或更多菜单中轻点分享图标。','share'],['添加到主屏幕','在分享菜单中选择「添加到主屏幕」；如果没有，请到「编辑操作」中添加。','plus'],['确认添加','如有「作为网页 App 打开」选项，请保持开启，再轻点「添加」。','check']];
    else steps=[['在手机 Chrome 中打开','用 Chrome 打开通语客服页面。','link'],['安装通语',native?'点击下方「安装通语」，在浏览器的安装提示中确认。':'轻点浏览器右上角菜单，选择「安装应用」或「添加到主屏幕」；具体名称以浏览器显示为准。','plus'],['从桌面打开','完成添加后，在手机桌面轻点通语图标。','check']];
    return header('添加到桌面','',state.me?'more':'login')+`<div class="section install-guide"><div class="install-guide-hero"><img src="/console/favicon.svg" width="58" height="58" alt="通语"><div><h2>让服务，触手可及。</h2><p>把通语放到桌面，下次直接打开。</p></div></div>${standalone()?'<div class="install-complete">'+icon('check')+'你已从桌面应用打开通语</div>':`<div class="card install-guide-card"><h3>${inApp?'先切换到系统浏览器':apple?'在 iPhone / iPad 上添加':native?'安装通语到桌面':'在手机浏览器中添加'}</h3>${steps.map(([title,description,i],index)=>`<div class="install-guide-step"><span class="install-step-number">${index+1}</span><div><h4>${esc(title)}</h4><p>${esc(description)}</p><div class="install-step-cue">${icon(i)}<span>${esc(i==='share'?'分享':i==='plus'?apple?'添加到主屏幕':'安装应用 / 添加到主屏幕':i==='check'?'通语 · 从桌面打开':i==='more'?'更多 · 在浏览器中打开':location.host)}</span></div></div></div>`).join('')}${chromeIOS||inApp?'<button type="button" class="secondary" onclick="copyText(location.origin+\'/console/?surface=agent\')">复制客服页面地址</button>':''}${native?'<button type="button" class="primary" id="install-guide-action" onclick="tongyuInstallFromGuide()">'+icon('download')+'安装通语</button>':''}<p id="install-guide-status" role="status" aria-live="polite"></p></div>`}<div class="install-guide-note">添加到桌面后仍需登录客服账号。系统通知需要单独授权。${!isSecureContext?' 当前连接不支持安装，请通过安全连接打开客服页面。':''}</div></div>`;
  }
  async function install(){
    if(busy||standalone())return;busy=true;
    const button=$('install-guide-action');if(button)button.disabled=true;let feedback='';
    try{
      const request=window.tongyuPwaAction('install');
      const message=await request;feedback=message;
      if($('install-guide-status'))$('install-guide-status').textContent=message;else toast(message);
    }catch(error){const message='暂时无法打开安装提示，请使用浏览器菜单添加到桌面。';feedback=message;if($('install-guide-status'))$('install-guide-status').textContent=message;else toast(message)}
    finally{busy=false;if(button?.isConnected)button.disabled=false;if(state.page==='install'){render();if($('install-guide-status'))$('install-guide-status').textContent=feedback}refresh()}
  }
  window.tongyuInstallFromGuide=install;
  window.tongyuRefreshInstallInvitation=refresh;
  views.install=guide;
  new MutationObserver(refresh).observe($('app'),{attributes:true,attributeFilter:['data-page']});
  window.addEventListener('tongyu:installchange',()=>{refresh();if(state.page==='install'&&!busy)render()});
  window.addEventListener('appinstalled',()=>{appInstalled=true;dismiss();if(state.page==='install')render()});
  window.addEventListener('pageshow',refresh);
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')refresh()});
  if(state.page==='install')render();else refresh();
})();
