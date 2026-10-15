/* Behavioral checks for the mobile transport and rendering boundary. */
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=__dirname+'/../apps/agent_console/web/mobile/';
const data={};const store={getItem:k=>data[k]??null,setItem:(k,v)=>data[k]=v,removeItem:k=>delete data[k]};
const localStorage=new Proxy(store,{ownKeys:()=>Object.keys(data),getOwnPropertyDescriptor:()=>({enumerable:true,configurable:true})});
const nodes=new Map();const element=()=>({hidden:true,innerHTML:'',textContent:'',value:'',style:{setProperty(){}},classList:{toggle(){}},remove(){},scrollHeight:42,selectionStart:0,selectionEnd:0,setSelectionRange(){}});
const document={getElementById:k=>{if(!nodes.has(k))nodes.set(k,element());return nodes.get(k)},documentElement:{style:{setProperty(){}},dataset:{}},body:{style:{}},querySelector:()=>({content:''}),addEventListener(){},visibilityState:'visible'};
let response={ok:true,status:200,json:async()=>({items:[]})},lastRequest;
const c=vm.createContext({console,document,localStorage,navigator:{onLine:true},location:{origin:'https://test.invalid',href:'https://test.invalid/console/mobile.html',pathname:'/console/mobile.html',search:'',hash:''},history:{pushState(){},replaceState(){}},window:{addEventListener(){}},matchMedia:()=>({matches:false}),innerHeight:844,URL,URLSearchParams,FormData,AbortSignal,crypto:require('node:crypto').webcrypto,setTimeout:()=>0,clearTimeout(){},setInterval:()=>0,clearInterval(){},WebSocket:{CLOSED:3},fetch:async(path,options)=>{lastRequest={path,options};return response}});
const run=s=>vm.runInContext(s,c);
for(const f of ['visual.js','core.js','messaging.js','message-actions.js'])run(fs.readFileSync(root+f,'utf8'));
run(fs.readFileSync(root+'app.js','utf8').replace('runAction(async()=>{try{await bootstrap()}finally', 'void(async()=>{try{}finally'));
run(`state.me={id:'agent-a',role:'AGENT',displayName:'<img onerror=alert(1)>',tenant:{id:'t'}};state.session={token:'private-token',tenant:{id:'t'}};state.current={id:'c',assigneeId:'other',acceptedAt:'today'};state.page='chat';state.draft='秘密';`);
assert.equal(run('writable()'),false,'foreign conversations cannot be sent to');
assert.equal(run('sessionScope()'),'t.agent-a');
assert.equal(run("customerName({visitorName:'访客',visitorId:'f60058-rest'})"),'访客 f60058');
assert.equal(run("customerName({visitorName:'陈女士',visitorId:'f60058-rest'})"),'陈女士');
run(`cache('example',{text:'a'});state.me.id='agent-b'`);
assert.equal(run(`cached('example')`),null,'snapshots must be account scoped');
run(`state.me.id='agent-a';purgeCache()`);assert.equal(run(`cached('example')`),null);
assert.equal(run(`canCache('/api/v1/files/x?token=abc')`),false);
assert.equal(run(`canCache('/api/v1/console/visitors/x/notes')`),false);
assert.equal(run(`canCache('/api/v1/console/conversations/c/messages?before=20')`),true);
run(`state.current={id:'c',assigneeId:'agent-a',acceptedAt:null}`);assert.equal(run('writable()'),false,'assigned is not accepted');
run(`state.current.acceptedAt='today'`);assert.equal(run('writable()'),true);
const rendered=run(`Object.fromEntries(Object.keys(views).map(k=>{state.page=k;return [k,views[k]()] }))`);
for(const [name,html] of Object.entries(rendered)){
 assert(!html.includes('<img onerror=alert(1)>'),name+' must escape server text');
 for(const m of html.matchAll(/on(?:click|submit|input|change|focus|contextmenu|dblclick)="([^"]*)"/g)){
  const decoded=m[1].replace(/&quot;/g,'"').replace(/&#39;/g,"'").replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&amp;/g,'&');
  assert.doesNotThrow(()=>new Function('event',decoded),name+' has invalid event handler: '+decoded);
 }
 assert(!/演示|未实际呼叫|设计预览/.test(html),name+' contains prototype copy');
}
assert.equal(Object.keys(rendered).length,20);
run('navigator.standalone=true');assert(!run('views.login()').includes('添加到主屏幕'),'installed login hides install guidance');run('navigator.standalone=false');
const emojis=run(`new Set(Object.values(emojiSets).join(' ').split(' ')).size`);assert(emojis>=328);
assert.equal(run('stickerLabels.length'),8);assert(run('sticker(0)').includes('xmlns="http://www.w3.org/2000/svg"'));
(async()=>{
 run(`state.me={id:'agent-a',tenant:{id:'t'}};state.session={token:'private-token',tenant:{id:'t'}};state.page='messages'`);
 await run(`api('/api/v1/console/conversations')`);
 assert.equal(lastRequest.options.headers.Authorization,'Bearer private-token');assert.equal(lastRequest.options.cache,'no-store');
 run(`navigator.onLine=false`);assert.equal((await run(`api('/api/v1/console/conversations')`)).items.length,0);
 run(`navigator.onLine=true`);response={ok:false,status:403,json:async()=>({message:'无权访问'})};
 await assert.rejects(run(`api('/api/v1/console/conversations/c')`));assert.equal(run(`cached('/api/v1/console/conversations')`),null,'403 purges revoked snapshots');
 run(`forgetSession()`);assert.equal(run('state.messages.length'),0);assert.equal(run('state.current'),null);assert.equal(run('state.session'),null);
 console.log('PASS mobile: 20 production page renderings, escaped server text, valid handlers, real emoji/sticker assets, account-scoped cache, ownership/acceptance, network fallback and revocation');
})().catch(e=>{console.error(e);process.exitCode=1});
