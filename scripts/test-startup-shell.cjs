const vm=require('node:vm'),fs=require('node:fs'),assert=require('node:assert/strict');
const html=fs.readFileSync('apps/agent_console/web/index.html','utf8');
const scripts=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]).filter(s=>s.includes('function dismissTongyuSplash')||s.includes('window.relaydeskLoadingFailed'));
function fixture(){
 const events={},timers=[],nodes={};let removed=false,reloads=0,leaving=false;
 const status={textContent:'',setAttribute(){},appendChild(node){nodes[node.id]=node;}};
 const splash={classList:{add(name){leaving=name==='leaving';}},remove(){removed=true;delete nodes['relaydesk-loading'];},querySelector(){return{remove(){}};}};
 nodes['relaydesk-loading']=splash;nodes['tongyu-start-status']=status;
 const window={addEventListener:(name,fn)=>events[name]=fn};
 const context={window,document:{getElementById:id=>nodes[id],createElement:()=>({}),body:{appendChild(){}}},setTimeout:(fn,ms)=>timers.push({fn,ms}),matchMedia:()=>({matches:false}),location:{reload(){reloads++;}}};
 scripts.forEach(s=>vm.runInNewContext(s,context));
 return{window,events,timers,status,nodes,get leaving(){return leaving;},get removed(){return removed;},get reloads(){return reloads;}};
}
const early=fixture();early.events['flutter-first-frame']();assert(!early.leaving,'框架首帧不能提前暴露启动校验界面');early.events['tongyu-app-ready']();assert(early.leaving);early.timers.find(t=>t.ms===220).fn();assert(early.removed);
const reverse=fixture();reverse.events['tongyu-app-ready']();assert(!reverse.leaving);reverse.events['flutter-first-frame']();assert(reverse.leaving);reverse.window.relaydeskLoadingFailed();assert(!reverse.nodes['relaydesk-load-retry'],'就绪后的延迟错误不能重新显示启动页');
const failure=fixture();failure.window.relaydeskLoadingFailed();assert(failure.nodes['relaydesk-load-retry']);failure.nodes['relaydesk-load-retry'].onclick();assert.equal(failure.reloads,1);
const slow=fixture();slow.timers.find(t=>t.ms===8000).fn();assert.match(slow.status.textContent,/连接时间较长/);
assert(html.includes('prefers-reduced-motion'));assert(html.includes('safe-area-inset-bottom'));
console.log('PASS startup: meaningful first frame, both event orders, automatic fade, failure retry, slow network, reduced motion and safe-area styles');
