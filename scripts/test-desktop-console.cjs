/* Behavioral checks for the mobile transport and rendering boundary. */
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=__dirname+'/../apps/agent_console/web/mobile/';
const data={};const store={getItem:k=>data[k]??null,setItem:(k,v)=>data[k]=v,removeItem:k=>delete data[k]};
const localStorage=new Proxy(store,{ownKeys:()=>Object.keys(data),getOwnPropertyDescriptor:()=>({enumerable:true,configurable:true})});
const nodes=new Map();const element=()=>({hidden:true,dataset:{},innerHTML:'',textContent:'',value:'',style:{setProperty(){}},classList:{toggle(){}},remove(){},scrollHeight:42,selectionStart:0,selectionEnd:0,setSelectionRange(){}});
const document={getElementById:k=>{if(k==='notification-preferences')return null;if(!nodes.has(k))nodes.set(k,element());return nodes.get(k)},documentElement:{style:{setProperty(){}},dataset:{}},body:{style:{},dataset:{}},querySelector:()=>({content:''}),addEventListener(){},visibilityState:'visible'};
let response={ok:true,status:200,json:async()=>({items:[]})},lastRequest;
const c=vm.createContext({console,document,localStorage,navigator:{onLine:true},location:{origin:'https://test.invalid',href:'https://test.invalid/console/mobile.html',pathname:'/console/mobile.html',search:'',hash:''},history:{pushState(){},replaceState(){}},window:{addEventListener(){}},matchMedia:()=>({matches:false}),innerHeight:844,URL,URLSearchParams,FormData,AbortSignal,crypto:require('node:crypto').webcrypto,setTimeout:()=>0,clearTimeout(){},setInterval:()=>0,clearInterval(){},WebSocket:{CLOSED:3},fetch:async(path,options)=>{lastRequest={path,options};return response}});
const run=s=>vm.runInContext(s,c);
for(const f of ['visual.js','core.js','messaging.js','message-actions.js'])run(fs.readFileSync(root+f,'utf8'));
run(fs.readFileSync(root+'app.js','utf8').replace('runAction(async()=>{try{await bootstrap()}finally', 'void(async()=>{try{}finally'));

for(const f of ['desktop.js','pages.js','platform.js'])run(fs.readFileSync(__dirname+'/../apps/agent_console/web/desktop/'+f,'utf8').replace("runAction(async()=>{state.side='profile';", "void(async()=>{return;state.side='profile';"));
run(`state.me={id:'agent-a',role:'SUPERVISOR',displayName:'<img onerror=alert(1)>',tenant:{id:'t'}};state.session={token:'private-token',tenant:{id:'t',name:'Test'}};state.current={id:'c',visitorId:'v',assigneeId:'agent-a',acceptedAt:'today',visitorName:'Customer'};state.group={id:'g',name:'Group'};state.ent={features:{ai:true,groups:true,automation:true}};state.article={id:'k',title:'Title',content:'Content'};state.stats={series:[]};`);
const pages=run(`Object.fromEntries(Object.keys(pageNames).filter(k=>views[k]).map(k=>{state.page=k;return[k,views[k]()] }))`);
for(const [name,html] of Object.entries(pages)){
 assert(!html.includes('<img onerror=alert(1)>'),name+' unescaped text');
 for(const m of html.matchAll(/on(?:click|submit|input|change|keydown|focus|contextmenu|dblclick)="([^"]*)"/g)){
 const decoded=m[1].replace(/&quot;/g,'"').replace(/&#39;/g,"'").replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&amp;/g,'&');assert.doesNotThrow(()=>new Function('event',decoded),name+' handler '+decoded);
 }
 assert(!/演示|设计预览|林女士|星河服务|需要人工确认后回复。/.test(html),name+' contains fixture content');
}
assert.equal(Object.keys(pages).length,35);
run(`state.page='settings';state.settingsSection=1`);assert(run('views.settings()').includes('aria-selected="true"'));assert(run('views.settings()').includes('外观模式'));assert(!run('views.settings()').includes('后台消息与免打扰'));
run(`state.settingsSection=2`);assert(run('views.settings()').includes('离线数据'));assert(!run('views.settings()').includes('外观模式'));
run(`location.assign=url=>{location.assigned=url};state.platform=false;switchSurface()`);assert.equal(run('location.assigned'),'https://test.invalid/console/desktop.html?surface=platform#platformLogin');
run(`state.platform=true;switchSurface()`);assert.equal(run('location.assigned'),'https://test.invalid/console/desktop.html?surface=agent#login');run('state.platform=false');

run(`state.page='chat';state.me.role='AGENT';state.current.assigneeId='other'`);assert.equal(run('writable()'),false);assert(!run('inboxHTML()').includes("setQueue('team')"));
run(`state.me.role='SUPERVISOR';state.queue='team';state.current.assigneeId='agent-a'`);
(async()=>{run(`location.hash='#platformLogin';state.me={role:'SUPERVISOR'}`);await run('bootstrapPlatform()');assert.equal(run('state.me'),null);assert.equal(run('state.page'),'platformLogin');run(`location.hash='';state.platform=false;state.page='messages';state.me={id:'agent-a',role:'SUPERVISOR'};state.session={token:'private-token',tenant:{id:'t'}}`);await run('loadConversations(false)');assert(lastRequest.path.includes('filter=team'));run(`state.me.role='AGENT'`);await run('loadConversations(false)');assert(lastRequest.path.includes('filter=mine'));console.log('PASS desktop: 35 production views, valid handlers, escaped server content, no fixture data, role-aware team scope and write ownership');})().catch(e=>{console.error(e);process.exitCode=1});
