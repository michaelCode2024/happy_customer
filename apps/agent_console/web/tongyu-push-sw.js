// 安装、离线与推送共用同一个 worker；业务 API 和带令牌附件永不进入 Cache Storage。
const SHELL_VERSION = 'development';
const SHELL_CACHE = 'tongyu-shell-' + SHELL_VERSION;
let shellPaths = null;
async function paths() {
  if (shellPaths) return shellPaths;
  const cache = await caches.open(SHELL_CACHE);
  const response = await cache.match('/console/pwa-assets.json');
  shellPaths = new Set(response ? (await response.json()).assets : []);
  return shellPaths;
}
self.addEventListener('install', event => event.waitUntil((async () => {
  const response = await fetch('/console/pwa-assets.json', {cache:'no-store'});
  if (!response.ok) throw new Error('离线资源清单下载失败');
  const manifest = await response.clone().json();
  if (manifest.version !== SHELL_VERSION) throw new Error('发布版本不一致');
  const cache = await caches.open(SHELL_CACHE);
  // 完整下载成功才完成安装，避免页面半更新、离线时缺少主脚本或字体。
  await cache.addAll(manifest.assets.map(url => new Request(url, {cache:'reload'})));
  await cache.put('/console/pwa-assets.json',response);
})()));
self.addEventListener('activate', event => event.waitUntil((async () => {
  for (const name of await caches.keys()) {
    if (name.startsWith('tongyu-shell-') && name !== SHELL_CACHE) await caches.delete(name);
  }
  await self.clients.claim();
})()));
self.addEventListener('message', event => {
  if (event.data?.type === 'ACTIVATE_UPDATE') self.skipWaiting();
  if (event.data?.type === 'SHELL_STATUS' && event.ports[0]) {
    event.waitUntil(caches.open(SHELL_CACHE).then(cache=>cache.match('/console/pwa-assets.json')).then(async marker=>{const manifest=marker?await marker.json():null;event.ports[0].postMessage({ready:!!marker,version:SHELL_VERSION,release:manifest?.release||{}});}));
  }
});
self.addEventListener('fetch', event => {
  const request=event.request, url=new URL(request.url);
  if (request.method!=='GET' || url.origin!==self.location.origin || !url.pathname.startsWith('/console/') || url.pathname==='/console/mobile-call.html' || url.searchParams.has('token')) return;
  event.respondWith((async () => {
    const cache=await caches.open(SHELL_CACHE);
    if (request.mode==='navigate') {
      // 固定入口由当前完整版本提供；查询参数仍由客户端解释，不缓存登录/API响应。
      const entry=await cache.match(url.pathname==='/console/mobile.html'?'/console/mobile.html':url.pathname==='/console/desktop.html'?'/console/desktop.html':'/console/index.html');
      // Go 静态服务会把 index.html 重定向到目录；缓存响应携带 redirected
      // 标记时不能直接用于 manual 导航，重建同源正文响应以兼容线上入口。
      if (entry) return new Response(entry.body, {status:entry.status,statusText:entry.statusText,headers:entry.headers});
      return fetch(request);
    }
    const allowed=await paths();
    if (allowed.has(url.pathname+url.search)) {
      const saved=await cache.match(request);
      if (saved) return saved;
    }
    return fetch(request);
  })());
});
self.addEventListener('push', event => {
  let data={};
  try {data=event.data.json();}catch(_){}
  self.navigator.setAppBadge?.().catch(()=>{});
  event.waitUntil(self.registration.showNotification('通语 · 新消息', {
    body:'有客户消息待处理，请打开工作台查看。',
    icon:'/console/icons/Icon-192.png', badge:'/console/icons/Icon-192.png',
    tag:typeof data.tag==='string'?data.tag:'tongyu-message',
    data:{url:typeof data.url==='string'&&data.url.startsWith('/console/')?data.url:'/console/?surface=agent'}
  }));
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const destination=new URL(event.notification.data?.url||'/console/?surface=agent',self.location.origin);
  if(destination.origin!==self.location.origin||!destination.pathname.startsWith('/console/'))return;
  event.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(async windows=>{
    const existing=windows.find(w=>new URL(w.url).pathname.startsWith('/console/'));
    if(existing){existing.postMessage({type:'OPEN_CONVERSATION',id:destination.searchParams.get('conversation')});return existing.focus();}
    return self.clients.openWindow(destination.href);
  }));
});
