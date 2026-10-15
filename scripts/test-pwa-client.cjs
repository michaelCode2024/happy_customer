const vm=require('node:vm'),fs=require('node:fs'),assert=require('node:assert/strict');
function fixture({installed=false,ios=false,waiting=false}={}){
 const events={},docEvents={},intervals=[],session=new Map();let version="v2";let updates=0,prompts=0,reloads=0,rewritten='';
 const worker={postMessage(message,ports){if(message.type==='SHELL_STATUS'){ports[0].postMessage({version,release:{version,notes:["release notes for "+version]}});return;}assert.equal(message.type,'ACTIVATE_UPDATE');}};
 const registration={waiting:waiting?worker:null,installing:null,update:async()=>{updates++;},addEventListener(){}};
 const window={addEventListener:(name,fn)=>events[name]=fn};
 const navigator={onLine:true,userAgent:ios?'iPhone':'Chrome',platform:ios?'iPhone':'Win32',standalone:installed,maxTouchPoints:ios?1:0,
  serviceWorker:{getRegistration:async()=>registration,register:async()=>registration,addEventListener:(name,fn)=>events[name]=fn}};
 const context={window,navigator,isSecureContext:true,matchMedia:()=>({matches:installed}),URL,MessageChannel:class{constructor(){this.port1={close(){}};this.port2={postMessage:data=>this.port1.onmessage?.({data})};}},sessionStorage:{getItem:k=>session.get(k),setItem:(k,v)=>session.set(k,v)},
  location:{href:'https://test.example/console/?surface=agent&install=1',reload(){reloads++;}},
  history:{state:null,replaceState(state,title,url){rewritten=url.toString();}},
  document:{visibilityState:'visible',addEventListener:(name,fn)=>docEvents[name]=fn},setTimeout(){},setInterval(fn){intervals.push(fn);}};
 vm.runInNewContext(fs.readFileSync('apps/agent_console/web/pwa-client.js','utf8'),context);
 return {window,events,docEvents,registration,intervals,nextVersion(){version="v3";},get updates(){return updates;},get rewritten(){return rewritten;},get reloads(){return reloads;},
  prompt(outcome){events.beforeinstallprompt({preventDefault(){},prompt:async()=>{prompts++;},userChoice:Promise.resolve({outcome})});},get prompts(){return prompts;}};
}
(async()=>{
 const f=fixture();await f.window.tongyuPwaReady;
 f.prompt('accepted');assert(JSON.parse(f.window.tongyuPwaStatus()).canInstall);
 assert.match(await f.window.tongyuPwaAction('install'),/完成浏览器/);assert.equal(f.prompts,1);
 assert(!JSON.parse(f.window.tongyuPwaStatus()).installed,'接受安装请求不能冒充安装完成');
 f.prompt('dismissed');assert.match(await f.window.tongyuPwaAction('install'),/已取消/);
 assert.match(await f.window.tongyuPwaAction('install'),/浏览器菜单/);
 await f.window.tongyuPwaAction('consumeInstallRequest');assert.equal(f.rewritten,'https://test.example/console/?surface=agent');
 const app=fixture({installed:true});await app.window.tongyuPwaReady;app.prompt('accepted');
 assert.equal(await app.window.tongyuPwaAction('install'),'已作为应用打开');assert.equal(app.prompts,0);
 const iphone=fixture({ios:true});await iphone.window.tongyuPwaReady;assert(JSON.parse(iphone.window.tongyuPwaStatus()).ios);
 assert.match(await iphone.window.tongyuPwaAction('install'),/添加到主屏幕/);
 const before=f.updates;f.events.online();f.docEvents.visibilitychange();assert.equal(f.updates,before+2);
 assert.match(await f.window.tongyuPwaAction('checkUpdate'),/没有可用更新/);
 const update=fixture({waiting:true});await update.window.tongyuPwaReady;
 assert.match(await update.window.tongyuPwaAction('checkUpdate'),/新版本已下载/);
 update.intervals[0]();
 assert.equal(JSON.parse(update.window.tongyuPwaStatus()).updateRelease.version,'v2');
 assert.equal(JSON.parse(update.window.tongyuPwaStatus()).updateRelease.notes[0],'release notes for v2');
 assert.equal(await update.window.tongyuPwaAction('claimUpdatePrompt'),'show');
 assert.equal(await update.window.tongyuPwaAction('claimUpdatePrompt'),'','同一版本稍后后不重复提示');
 update.nextVersion();update.intervals[0]();
 assert.equal(await update.window.tongyuPwaAction('claimUpdatePrompt'),'show','下一个版本可以再次提醒');
 update.events.controllerchange();assert.equal(update.reloads,0,'后台发现版本不能刷新正在编辑的会话');
 await update.window.tongyuPwaAction('update');update.events.controllerchange();assert.equal(update.reloads,1);
 console.log('PASS PWA client: native prompt, cancellation, fallback, standalone, iPhone, consumed guide URL, online/foreground update checks, explicit reload');
})().catch(error=>{console.error(error);process.exitCode=1;});
