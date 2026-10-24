// 对真实 worker 源码执行安装、断网回退与更新边界测试，无浏览器和业务数据。
const vm=require('node:vm'),fs=require('node:fs'),assert=require('node:assert/strict');
(async()=>{
 const listeners={},storage=new Map();let network=true,skipped=false,claimed=false;
 const origin='https://test.example';
 const key=r=>new URL(typeof r==='string'?r:r.url,origin).href;
 const manifest={version:'development',assets:['/console/index.html','/console/main.dart.js?release=42']};
 async function fetcher(request){
  if(!network)throw Error('offline');
  const u=new URL(key(request));
  return new Response(u.pathname.endsWith('pwa-assets.json')?JSON.stringify(manifest):u.pathname.endsWith('index.html')?'APP SHELL':'MAIN SCRIPT',{status:200});
 }
 const caches={keys:async()=>[...storage.keys()],delete:async n=>storage.delete(n),open:async n=>{
  if(!storage.has(n))storage.set(n,new Map());const rows=storage.get(n);
  return {match:async r=>{const response=rows.get(key(r))?.clone();if(response&&key(r).endsWith('/index.html'))Object.defineProperty(response,'redirected',{value:true});return response;},put:async(r,v)=>rows.set(key(r),v.clone()),addAll:async urls=>{
   const responses=await Promise.all(urls.map(fetcher));responses.forEach((r,i)=>rows.set(key(urls[i]),r));
  }};
 }};
 const self={location:{origin},navigator:{},addEventListener:(name,fn)=>listeners[name]=fn,
  skipWaiting:()=>{skipped=true;},clients:{claim:async()=>{claimed=true;}},registration:{showNotification:async()=>{}}};
 vm.runInNewContext(fs.readFileSync('apps/agent_console/web/tongyu-push-sw.js','utf8'),{self,caches,fetch:fetcher,Request:class{constructor(url){this.url=key(url);}},Response,URL,Set});
 async function lifecycle(name){let promise;listeners[name]({waitUntil:p=>promise=p});await promise;}
 await lifecycle('install');assert(skipped,'入口更新必须 skipWaiting 尽快生效');await lifecycle('activate');assert(claimed);
 network=false;
 async function read(url,mode='cors') {let response;listeners.fetch({request:{method:'GET',url:origin+url,mode},respondWith:p=>response=p});return response;}
 const navigation=await read('/console/?surface=agent','navigate');
 assert.equal(navigation.redirected,false,'线上 index 重定向响应必须规范化后再交给导航');
 assert.equal(await navigation.text(),'APP SHELL');
 assert.equal(await (await read('/console/desktop.html?surface=platform','navigate')).text(),'APP SHELL','旧 HTML 桌面壳书签必须回到 Flutter 入口');
 assert.equal(await (await read('/console/mobile.html#chat','navigate')).text(),'APP SHELL','旧 HTML 手机壳书签必须回到 Flutter 入口');
 assert.equal(await read('/console/mobile-call.html','navigate'),undefined,'通话身份与信令页不能回退到离线首页');
 assert.equal(await (await read('/console/main.dart.js?release=42')).text(),'MAIN SCRIPT');
 assert.equal(await read('/api/v1/console/conversations'),undefined,'不能缓存 API');
 assert.equal(await read('/console/file?token=secret'),undefined,'不能缓存带令牌附件');
 await assert.rejects(()=>read('/console/unknown.js'));
 listeners.message({data:{type:'ACTIVATE_UPDATE'}});assert(skipped);
 let status;let ready;listeners.message({data:{type:'SHELL_STATUS'},ports:[{postMessage:s=>status=s}],waitUntil:p=>ready=p});await ready;assert(status.ready);
 console.log('PASS worker: complete install, offline navigation/scripts, API/token exclusions, explicit update, readiness');
})().catch(e=>{console.error(e);process.exit(1);});
