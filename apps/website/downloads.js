(async function(){
  const button=document.querySelector('#android-download');
  try {
    const response=await fetch('/downloads/release.json',{cache:'no-store'});
    if(!response.ok)throw new Error('unavailable');
    const release=await response.json();
    const apk=new URL(release.android.url,location.origin);
    if(apk.origin!==location.origin||!apk.pathname.startsWith('/downloads/')||!apk.pathname.endsWith('.apk'))throw new Error('invalid');
    button.href=apk.href;button.removeAttribute('aria-disabled');button.textContent='下载安卓安装包';
    document.querySelector('#android-info').textContent=`版本 ${release.android.version} · 更新于 ${release.android.updatedAt}`;
    if(release.android.sha256)document.querySelector('#android-status').textContent='安装包校验 SHA-256：'+release.android.sha256;
  }catch(_){button.textContent='安装包准备中';document.querySelector('#android-info').textContent='安装包尚未发布，请先使用网页版';document.querySelector('#android-status').innerHTML='<a href="/console/?surface=agent">打开网页版工作台 →</a>';}
})();

// 苹果入口只讲实际操作；电脑用户扫码到手机，不混入安卓和桌面安装流程。
(function(){
 const link=document.getElementById('pwa-install');
 if(!link)return;
 link.addEventListener('click',event=>{
  event.preventDefault();
  const ios=/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
  const embedded=/MicroMessenger|QQ\/|FBAN|FBAV|Instagram|Line\//i.test(navigator.userAgent);
  const standalone=matchMedia('(display-mode: standalone)').matches||navigator.standalone===true;
  const dialog=document.createElement('dialog');dialog.className='pwa-install-dialog';
  const heading=document.createElement('h2');heading.textContent=standalone?'通语已可使用':'iPhone 怎么使用通语？';
  const intro=document.createElement('p');intro.textContent=standalone?'直接打开工作台即可，无需重复添加。':embedded?'先通过右上角菜单，用 Safari 浏览器打开。':ios?'只需添加一次，以后从桌面图标打开。':'请用 iPhone 相机扫描二维码，在 Safari 中打开此页面。';
  dialog.append(heading,intro);
  if(!ios&&!standalone){const qr=document.createElement('img');qr.src='/website/download-qr.svg';qr.alt='使用 iPhone 相机扫码打开使用指引';qr.className='apple-guide-qr';qr.width=144;qr.height=144;dialog.append(qr);}
  const steps=document.createElement('ol');
  const lines=standalone?[]:['在 Safari 中打开通语工作台。','点击分享按钮（方框向上箭头），向下找到「添加到主屏幕」。','如有「作为 Web App 打开」，保持开启，再点右上角「添加」。','回到手机桌面，点击「通语」图标，使用企业账号登录。'];
  for(const line of lines){const item=document.createElement('li');item.textContent=line;steps.append(item);}
  const note=document.createElement('p');note.className='pwa-install-note';note.textContent='已经添加过？直接从桌面打开通语，不用重复操作。';
  const actions=document.createElement('div');actions.className='pwa-install-actions';
  const close=document.createElement('button');close.type='button';close.textContent='知道了';close.onclick=()=>dialog.close();
  if(standalone||ios&&!embedded){const next=document.createElement('a');next.className='button apple-button';next.href=standalone?'/console/?surface=agent':link.href;next.textContent=standalone?'打开工作台':'打开通语工作台';actions.append(next);}
  if(embedded){const copy=document.createElement('button');copy.type='button';copy.textContent='复制工作台网址';copy.onclick=async()=>{
    try{await navigator.clipboard.writeText(new URL('/console/?surface=agent&install=1',location.origin).href);copy.textContent='已复制，请粘贴到 Safari 打开';}
    catch(_){const address=document.createElement('p');address.textContent=new URL('/console/?surface=agent&install=1',location.origin).href;address.style.userSelect='all';actions.before(address);copy.textContent='长按上方网址复制';}
   };actions.append(copy);}
  actions.append(close);dialog.append(steps,note,actions);document.body.append(dialog);
  dialog.addEventListener('close',()=>dialog.remove(),{once:true});dialog.showModal();
 });
})();
