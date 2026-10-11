'use strict';
// A bounded mesh: each participant has one peer connection per other member.
// Browser session IDs fence late answers when a member leaves and rejoins.
let room = null, availableRoom = null, roomStream = null, roomBusy = false;
let roomNetworkFailure = false;
let roomPolling = false, roomAfter = 0, roomEpoch = 0, roomSession = '';
let roomHeartbeat = 0, roomIce = [], roomMuted = false, roomCamera = false;
const roomPeers = new Map();
const roomAPI = body => api('POST', path('/rooms'), {roomId: room?.id, sessionId: roomSession, ...body});
const roomIsMe = m => m.kind === actorKind && m.id === actorId;
function disposeRoomMedia() {
  ++roomEpoch;
  roomStream?.getTracks().forEach(t => t.stop()); roomStream = null;
  for (const entry of roomPeers.values()) { clearTimeout(entry.timer); entry.pc.onconnectionstatechange = null; entry.pc.close(); }
  roomPeers.clear();
  for (const video of el('roomGrid').querySelectorAll('video')) video.srcObject = null;
}
function roomTerminal(message) {
  disposeRoomMedia(); room = null;roomNetworkFailure=false;el('roomError').textContent=''; el('roomGrid').replaceChildren();el('roomGrid').dataset.connected='0';el('roomGrid').dataset.participants='0';el('roomStatus').textContent = message;
  for (const id of ['roomMute','roomCamera','roomLeave','roomEnd']) el(id).hidden = true;
  el('roomClose').hidden = false;
}
async function acquireRoomMedia(kind, epoch, camera = true) {
  if (!navigator.mediaDevices?.getUserMedia) throw new Error('浏览器不支持通话，请使用 HTTPS 或本机地址');
  let timer, settled = false;
  const request = navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true},video:kind==='VIDEO'&&camera?{width:{ideal:640},height:{ideal:360},frameRate:{ideal:20,max:24}}:false});
  request.then(s => { if (settled || epoch !== roomEpoch) s.getTracks().forEach(t => t.stop()); }, () => {});
  try {
    const stream = await Promise.race([request,new Promise((_,reject)=>{timer=setTimeout(()=>{settled=true;reject(new Error('设备授权未完成，请允许麦克风'+(kind==='VIDEO'?'和摄像头':'')+'后重试'));},12000);})]);
    if(epoch!==roomEpoch){stream.getTracks().forEach(t=>t.stop());throw new Error('已取消通话');} return stream;
  } catch(e) {
    if(e.name==='NotAllowedError') throw new Error('麦克风或摄像头权限被拒绝，请在浏览器中允许后重试');
    if(e.name==='NotFoundError') throw new Error('未检测到所需麦克风或摄像头，请连接设备后重试');
    if(e.name==='NotReadableError') throw new Error('设备被其他应用占用，请关闭占用后重试');
    throw e;
  } finally {clearTimeout(timer);}
}
function roomTile(member, stream, local=false) {
  const tile=document.createElement('div');tile.className='tile';tile.dataset.session=member.sessionId;
  const video=document.createElement('video');video.autoplay=true;video.playsInline=true;video.muted=local;
  video.srcObject=stream; video.hidden=room?.mediaKind!=='VIDEO'; tile.append(video);
  const avatar=document.createElement('div');avatar.className='roomAvatar';avatar.textContent=member.name.slice(-1);tile.append(avatar);
  const label=document.createElement('div');label.className='tileLabel';tile.append(label);
  const status=document.createElement('div');status.className='tileStatus';tile.append(status);
  el('roomGrid').append(tile);video.play().catch(()=>{status.textContent='点击静音按钮恢复播放';});return tile;
}
function updateRoomTile(tile, member, state) {
  tile.querySelector('.tileLabel').textContent=member.name+(roomIsMe(member)?' · 我':'');
  tile.querySelector('.tileStatus').textContent=(member.muted?'已静音':'麦克风开启')+(room?.mediaKind==='VIDEO'?(member.camera?' · 摄像头开启':' · 摄像头关闭'):'')+' · '+state;
  tile.querySelector('video').hidden=room?.mediaKind!=='VIDEO'||!member.camera;tile.querySelector('.roomAvatar').hidden=room?.mediaKind==='VIDEO'&&member.camera;
}
function peerFor(member) {
  let entry=roomPeers.get(member.sessionId);if(entry)return entry;
  const epoch=roomEpoch,pc=new RTCPeerConnection({iceServers:roomIce});
  roomStream.getTracks().forEach(t=>pc.addTrack(t,roomStream));
  if(room?.mediaKind==='VIDEO'&&!roomStream.getVideoTracks().length)pc.addTransceiver('video',{direction:'sendrecv'});
  const tile=roomTile(member,null),video=tile.querySelector('video');
  entry={pc,tile,member,timer:null};roomPeers.set(member.sessionId,entry);
  pc.ontrack=e=>{if(epoch!==roomEpoch)return;video.srcObject=e.streams[0]||new MediaStream([e.track]);video.play().catch(()=>{});};
  pc.onconnectionstatechange=()=>{if(epoch!==roomEpoch)return;tile.dataset.connection=pc.connectionState;updateRoomTile(tile,entry.member,pc.connectionState==='connected'?'已连接':pc.connectionState==='failed'?'连接失败':'连接中');if(pc.connectionState==='connected')clearTimeout(entry.timer);};
  entry.timer=setTimeout(()=>{if(epoch===roomEpoch&&pc.connectionState!=='connected'){el('roomError').textContent='部分成员连接超时，请检查网络或配置 TURN 中继服务。';updateRoomTile(tile,entry.member,'连接超时');}},30000);
  return entry;
}
async function enterRoom(kind, existing=null, camera=el('videoWithCamera').checked) {
  if(roomBusy||room||call||callBusy){error(new Error('已有通话，请先退出或挂断'));return;}
  roomBusy=true;const epoch=++roomEpoch;roomSession=crypto.randomUUID();roomAfter=0;roomHeartbeat=0;roomMuted=false;roomCamera=kind==='VIDEO'&&camera;
  for(const dialog of document.querySelectorAll('dialog[open]'))dialog.close();
  el('conference').showModal();el('roomTitle').textContent=kind==='VIDEO'?'群视频通话':'群语音通话';el('roomStatus').textContent='正在请求'+(kind==='VIDEO'&&camera?'麦克风和摄像头':'麦克风')+'权限…';el('roomError').textContent='';el('roomGrid').replaceChildren();
  for(const id of ['roomMute','roomCamera','roomEnd'])el(id).hidden=true;el('roomLeave').hidden=false;el('roomClose').hidden=true;
  try {
    roomStream=await acquireRoomMedia(kind,epoch,camera);
    const result=await api('POST',path('/rooms'),{action:existing?'join':'create',roomId:existing?.id,sessionId:roomSession,mediaKind:kind,camera:roomCamera});
    if(epoch!==roomEpoch){await api('POST',path('/rooms'),{action:'leave',roomId:result.id,sessionId:roomSession});return;}
    room={id:result.id,mediaKind:kind,members:[]};el('roomMute').hidden=false;el('roomCamera').hidden=kind!=='VIDEO';el('roomMute').textContent='静音';el('roomCamera').textContent=roomCamera?'关闭摄像头':'开启摄像头';
    await pollRooms();
  } catch(e) {if(epoch===roomEpoch)roomTerminal(e.message);} finally {roomBusy=false;}
}
async function exitRoom(all=false) {
  const current=room,session=roomSession;roomTerminal(all?'通话已结束':'已退出通话');
  if(current)await api('POST',path('/rooms'),{action:all?'end':'leave',roomId:current.id,sessionId:session});
  await pollRooms();
}
async function pollRooms() {
  if(!token||!groupId||ended||roomPolling)return;roomPolling=true;
  const epoch=roomEpoch;
  try {
    if(room&&Date.now()-roomHeartbeat>8000){await roomAPI({action:'heartbeat',muted:roomMuted,camera:roomCamera});roomHeartbeat=Date.now();}
    const data=await api('GET',path('/rooms?after='+roomAfter+'&session='+encodeURIComponent(roomSession)));
    if(epoch!==roomEpoch)return;
    if(roomNetworkFailure){el('roomError').textContent='';roomNetworkFailure=false;}
    availableRoom=data.room;roomIce=data.iceServers||[];
    el('roomBanner').hidden=!data.room||!!room;el('roomBannerText').textContent=data.room?(data.room.mediaKind==='VIDEO'?'群视频':'群语音')+'通话进行中 · '+data.room.members.length+'/6 人':'';
    if(!room)return;
    const me=data.room?.members.find(roomIsMe);
    if(!data.room||data.room.id!==room.id||!me||me.sessionId!==roomSession){roomTerminal('通话已结束，或你已离开群聊');return;}
    room=data.room;el('roomEnd').hidden=!(room.creatorKind===actorKind&&room.creatorId===actorId)&&!(actorKind==='agent'&&group?.ownerId===actorId);
    let localTile=el('roomGrid').querySelector('[data-session="'+roomSession+'"]');if(!localTile)localTile=roomTile(me,roomStream,true);updateRoomTile(localTile,me,'本地');
    const live=new Set(room.members.map(m=>m.sessionId));
    for(const [sid,entry] of roomPeers)if(!live.has(sid)){clearTimeout(entry.timer);entry.pc.close();entry.tile.querySelector('video').srcObject=null;entry.tile.remove();roomPeers.delete(sid);}
    for(const member of room.members){
      if(roomIsMe(member))continue;
      const existing=roomPeers.get(member.sessionId);
      if(existing){existing.member=member;updateRoomTile(existing.tile,member,existing.pc.connectionState==='connected'?'已连接':'连接中');}
      // Exactly one side offers, preventing simultaneous renegotiation glare.
      if(!existing&&roomSession<member.sessionId){const entry=peerFor(member);const offer=await localSDP(entry.pc,'offer');if(epoch!==roomEpoch)return;await roomAPI({action:'signal',recipientSession:member.sessionId,payload:offer});}
    }
    for(const signal of data.signals||[]){
      const member=room.members.find(m=>m.sessionId===signal.senderSession);if(!member){roomAfter=Math.max(roomAfter,signal.id);continue;}
      const entry=peerFor(member),pc=entry.pc;
      if(signal.payload.type==='offer'&&!pc.remoteDescription){await pc.setRemoteDescription(signal.payload);const answer=await localSDP(pc,'answer');if(epoch!==roomEpoch)return;await roomAPI({action:'signal',recipientSession:member.sessionId,payload:answer});}
      else if(signal.payload.type==='answer'&&!pc.remoteDescription)await pc.setRemoteDescription(signal.payload);
      roomAfter=Math.max(roomAfter,signal.id);
    }
    let connected=0;
    for(const entry of roomPeers.values())if(entry.pc.connectionState==='connected'){
      connected++;const stats=await entry.pc.getStats();let audio=0,video=0,sentAudio=0,sentVideo=0;
      for(const s of stats.values()){if(s.type==='inbound-rtp'){if(s.kind==='audio')audio+=s.bytesReceived||0;if(s.kind==='video')video+=s.bytesReceived||0;}if(s.type==='outbound-rtp'){if(s.kind==='audio')sentAudio+=s.bytesSent||0;if(s.kind==='video')sentVideo+=s.bytesSent||0;}}
      Object.assign(entry.tile.dataset,{receivedAudio:String(audio),receivedVideo:String(video),sentAudio:String(sentAudio),sentVideo:String(sentVideo)});
    }
    el('roomGrid').dataset.connected=String(connected);el('roomGrid').dataset.participants=String(room.members.length);
    el('roomStatus').textContent=room.members.length+' 人参会 · 已连接 '+connected+' 位成员'+(room.members.length===1?' · 等待其他成员加入':'');
  } catch(e) {if(epoch===roomEpoch){if(room&&[401,403,404,409].includes(e.status))roomTerminal(e.message);else if(room){roomNetworkFailure=true;el('roomError').textContent=e.message;}}} finally {roomPolling=false;}
}
el('callButton').onclick=()=>{el('startAudioRoom').hidden=false;el('startVideoRoom').textContent='群视频通话';el('callOptions').showModal();};
el('closeOptions').onclick=()=>el('callOptions').close();
el('privateCall').onclick=()=>{el('callOptions').close();members(true).catch(error);};
el('startAudioRoom').onclick=()=>enterRoom('AUDIO');
el('startVideoRoom').onclick=()=>enterRoom('VIDEO',el('startVideoRoom').textContent==='加入群视频通话'?availableRoom:null);
el('joinRoom').onclick=()=>{if(!availableRoom)return;if(availableRoom.mediaKind==='VIDEO'){el('callOptions').showModal();el('startVideoRoom').textContent='加入群视频通话';el('startAudioRoom').hidden=true;}else enterRoom('AUDIO',availableRoom);};
el('roomLeave').onclick=()=>exitRoom().catch(error);
el('roomEnd').onclick=()=>exitRoom(true).catch(error);
el('roomClose').onclick=()=>el('conference').close();
el('roomMute').onclick=()=>{roomMuted=!roomMuted;roomStream?.getAudioTracks().forEach(t=>t.enabled=!roomMuted);el('roomMute').textContent=roomMuted?'取消静音':'静音';roomHeartbeat=0;for(const v of el('roomGrid').querySelectorAll('video'))v.play().catch(()=>{});pollRooms();};
el('roomCamera').onclick=async()=>{
  if(!room||room.mediaKind!=='VIDEO')return;
  el('roomCamera').disabled=true;const epoch=roomEpoch;
  try {
    if(!roomStream.getVideoTracks().length){
      const extra=await acquireRoomMedia('VIDEO',epoch,true);
      extra.getAudioTracks().forEach(t=>t.stop());
      const track=extra.getVideoTracks()[0];if(!track)throw new Error('未检测到摄像头');
      track.enabled=false;roomStream.addTrack(track);
      for(const entry of roomPeers.values()){
        const transceiver=entry.pc.getTransceivers().find(t=>t.receiver.track.kind==='video');
        if(transceiver)await transceiver.sender.replaceTrack(track);
      }
      roomCamera=false;
    }
    if(epoch!==roomEpoch)return;
    roomCamera=!roomCamera;roomStream.getVideoTracks().forEach(t=>t.enabled=roomCamera);
    el('roomCamera').textContent=roomCamera?'关闭摄像头':'开启摄像头';el('roomError').textContent='';roomHeartbeat=0;await pollRooms();
  } catch(e){if(epoch===roomEpoch)el('roomError').textContent=e.message;}
  finally {el('roomCamera').disabled=false;}
};
el('conference').addEventListener('cancel',e=>{if(room||roomBusy)e.preventDefault();});
setInterval(pollRooms,1500);
window.addEventListener('pagehide',()=>{if(room&&token)fetch(path('/rooms'),{method:'POST',keepalive:true,headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify({action:'leave',roomId:room.id,sessionId:roomSession})}).catch(()=>{});disposeRoomMedia();});
