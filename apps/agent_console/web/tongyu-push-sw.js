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
  // 已有旧 worker 时停在 waiting，登录页和工作台才能弹出更新。
  // 首次安装没有 active worker，直接接管，避免第一打开一直等用户点更新。
  if (!self.registration.active) await self.skipWaiting();
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
  // canvaskit.wasm 约 6MB。经 worker 转发会失去流式编译，每次打开都要等整包下完再编译。
  if (url.pathname.startsWith('/console/canvaskit/')) return;
  event.respondWith((async () => {
    const cache=await caches.open(SHELL_CACHE);
    if (request.mode==='navigate') {
      // 工作台唯一入口是 Flutter index；旧 desktop/mobile HTML 书签也回落到这里。
      const entryPath='/console/index.html';
      // 导航网络优先：避免旧壳长期挡住 Flutter 登录入口。
      try {
        const fresh=await fetch(entryPath, {cache:'no-store'});
        if (fresh.ok) {
          const copy=fresh.clone();
          cache.put(entryPath, copy).catch(()=>{});
          return fresh;
        }
      } catch (_) {}
      const entry=await cache.match(entryPath);
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
// 锁屏按发送者和正文展示。控制符和双向文字符先清掉，避免把通知方向改掉或截断。
function noticeText(value, limit, fallback) {
  const clean = String(value || '').replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, ' ').replace(/\s+/g, ' ').trim();
  const chars = Array.from(clean);
  if (!chars.length) return fallback;
  if (chars.length <= limit) return clean;
  return chars.slice(0, limit).join('') + '…';
}
self.addEventListener('push', event => {
  let data={};
  try {data=event.data.json();}catch(_){}
  self.navigator.setAppBadge?.().catch(()=>{});
  event.waitUntil(self.registration.showNotification(noticeText(data.title, 48, '客户'), {
    body:noticeText(data.body, 120, '发来一条消息'),
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
