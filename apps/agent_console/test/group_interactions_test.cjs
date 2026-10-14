const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../web/group-interactions.js'), 'utf8');

function setup(getUserMedia) {
  const elements = new Map(), timers = new Map(); let timerID = 0;
  function element(id) {
    if (!elements.has(id)) elements.set(id, {id,dataset:{}, hidden:true, textContent:'',value:'',disabled:false,children:[],scrollHeight:0,scrollTop:0,clientHeight:0,
      append(...children){this.children.push(...children);},replaceChildren(){this.children=[];},
      addEventListener(){},showModal(){this.open=true;},close(){this.open=false;},querySelectorAll(){return [];},querySelector(){return element('heading');},play:async()=>{}});
    return elements.get(id);
  }
  const context = vm.createContext({console,URLSearchParams,AbortController,crypto:require('node:crypto').webcrypto,
    location:{search:'',origin:'http://localhost'},navigator:{mediaDevices:{getUserMedia}},
    document:{addEventListener(){},visibilityState:"visible",hasFocus:()=>true,getElementById:element,createElement:tag=>element('new-'+Math.random()),querySelectorAll:()=>[]},
    window:{addEventListener(){}},sessionStorage:{getItem:()=>null},
    setTimeout:(fn)=>{timers.set(++timerID,fn);return timerID;},clearTimeout:id=>timers.delete(id),
    setInterval:()=>0,clearInterval(){}});
  vm.runInContext(source,context);
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../web/group-conference.js'),'utf8'),context);
  return {context,elements,element,timers,run:code=>vm.runInContext(code,context)};
}

test('公告模式下普通成员不能点击发送，保留草稿',async()=>{
 const env=setup();
 env.run(`group={canSend:false};el('draft').value='买家消息';api=async()=>{throw new Error('不应调用发送接口')}`);
 await env.element('send').onclick();
 assert.equal(env.element('draft').value,'买家消息');
 assert.equal(env.run('sending'),false);
});

test('非法福利群容量不发起请求，并保留设置',async()=>{
 const env=setup();
 env.element('maxMembers').value='5001';
 env.run(`api=async()=>{throw new Error('不应调用设置接口')}`);
 await env.element('saveGroupRules').onclick();
 assert.match(env.element('dialogError').textContent,/2至5000/);
 assert.equal(env.element('maxMembers').value,'5001');
});

test('取消麦克风请求后，延迟返回的音轨必须停止',async()=>{
  let resolve, stopped=0;
  const env=setup(()=>new Promise(r=>resolve=r));
  const request=env.run('microphone()');
  env.run('stopMedia()');
  resolve({getTracks:()=>[{stop:()=>stopped++}]});
  await assert.rejects(request,/通话已取消/);
  assert.ok(stopped>=1);
  assert.equal(env.run('media'),null);
});

test('麦克风超时后，迟到的授权同样释放设备',async()=>{
  let resolve,stopped=0;
  const env=setup(()=>new Promise(r=>resolve=r));
  const request=env.run('microphone()');
  [...env.timers.values()].at(-1)();
  await assert.rejects(request,/麦克风授权未完成/);
  resolve({getTracks:()=>[{stop:()=>stopped++}]});
  await Promise.resolve();
  assert.equal(stopped,1);
  assert.equal(env.run('media'),null);
});

test('撤回消息只渲染提示，不渲染正文或撤回按钮',()=>{
  const env=setup();
  env.run(`actorId='me';items=[{id:'one',actorId:'me',kind:'widget',name:'我',createdAt:new Date().toISOString(),content:'不得显示',recalled:true}];render()`);
  const row=env.element('messages').children[0];
  assert.equal(row.children[1].textContent,'该消息已被撤回');
  assert.equal(row.children.length,2);
});

test('昵称提交失败保留弹窗和输入，可再次保存',async()=>{
  const env=setup();env.element('nickname').value='原昵称';env.element('preferences').open=true;
  env.run(`api=async()=>{throw new Error('保存失败')};group={dissolved:false}`);
  await env.element('saveNickname').onclick();
  assert.equal(env.element('preferences').open,true);
  assert.equal(env.element('nickname').value,'原昵称');
  assert.equal(env.element('saveNickname').disabled,false);
  assert.equal(env.element('dialogError').textContent,'保存失败');
});

test('成员移出或登录失效立即释放正在使用的麦克风',async()=>{
  let stopped=0;
  const env=setup(async()=>({getTracks:()=>[{stop:()=>stopped++}]}));
  await env.run('microphone()');
  env.run(`call={id:'one'};const denied=new Error('已移出群');denied.status=404;error(denied)`);
  assert.equal(stopped,1);
  assert.equal(env.run('call'),null);
  assert.match(env.element('callState').textContent,/通话结束/);
});

test('群语音不请求摄像头，群视频请求受限分辨率',async()=>{
  const seen=[];const env=setup(async config=>{seen.push(config);return {getTracks:()=>[]};});
  await env.run("acquireRoomMedia('AUDIO',roomEpoch)");
  await env.run("acquireRoomMedia('VIDEO',roomEpoch)");
  assert.equal(seen[0].video,false);assert.equal(seen[1].video.width.ideal,640);
  await env.run("acquireRoomMedia('VIDEO',roomEpoch,false)");assert.equal(seen[2].video,false);
});
test('群通话取消后迟到的设备授权释放音视频轨',async()=>{
  let resolve,stopped=0;const env=setup(()=>new Promise(r=>resolve=r));
  const promise=env.run("acquireRoomMedia('VIDEO',roomEpoch)");env.run('++roomEpoch');
  resolve({getTracks:()=>[{stop:()=>stopped++},{stop:()=>stopped++}]});
  await assert.rejects(promise,/已取消通话/);assert.ok(stopped>=2);
});

test('仅语音加入视频房间后启用画面，先替换轨道再解除禁用',async()=>{
  const tracks=[];const video={kind:'video',enabled:true,stop(){}};
  const env=setup(async()=>({getTracks:()=>[video],getAudioTracks:()=>[],getVideoTracks:()=>[video]}));
  env.context.qaVideo=video;env.context.qaTracks=tracks;
  env.run(`room={id:'test',mediaKind:'VIDEO'};roomStream={getVideoTracks:()=>qaTracks,addTrack:t=>qaTracks.push(t)};pollRooms=async()=>{};roomPeers.set('peer',{pc:{getTransceivers:()=>[{receiver:{track:{kind:'video'}},sender:{replaceTrack:async t=>{if(t.enabled)throw new Error('轨道提前发送');}}}]}})`);
  await env.element('roomCamera').onclick();
  assert.equal(env.run('roomCamera'),true);assert.equal(video.enabled,true);assert.equal(env.element('roomCamera').textContent,'关闭摄像头');
});

test('结束群通话会释放所有媒体轨道及所有成员连接',()=>{
  let stopped=0,closed=0;const env=setup();env.context.qaStop=()=>stopped++;env.context.qaClose=()=>closed++;
  env.run(`roomStream={getTracks:()=>[{stop:qaStop},{stop:qaStop}]};roomPeers.set('a',{pc:{close:qaClose}});roomPeers.set('b',{pc:{close:qaClose}});disposeRoomMedia()`);
  assert.equal(stopped,2);assert.equal(closed,2);assert.equal(env.run('roomPeers.size'),0);assert.equal(env.run('roomStream'),null);
});

test('通话请求网络恢复后清除旧错误，结束时不保留连接错误',async()=>{
  const env=setup();env.run(`token='test';groupId='group';roomNetworkFailure=true;el('roomError').textContent='Failed to fetch';api=async()=>({room:null,iceServers:[]})`);
  await env.run('pollRooms()');assert.equal(env.element('roomError').textContent,'');
  env.run(`el('roomError').textContent='旧错误';roomTerminal('已结束')`);
  assert.equal(env.element('roomError').textContent,'');assert.equal(env.element('roomStatus').textContent,'已结束');
});
