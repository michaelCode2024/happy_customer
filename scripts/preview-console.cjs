// 本机验收：官网与最新 Flutter 构建同源，API/实时连接转发至已有本地服务。
// 不启动业务后端、不执行迁移、不记录请求内容或鉴权信息。
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const root = path.resolve(__dirname, '..');
const port = Number(process.env.PREVIEW_PORT || 18765);
const upstream = new URL(process.env.PREVIEW_API || 'http://127.0.0.1:8080');
if (upstream.protocol !== 'http:' || !['localhost', '127.0.0.1', '[::1]'].includes(upstream.hostname)) {
  throw new Error('预览只允许连接本机 HTTP 服务');
}
const mime = {'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.svg':'image/svg+xml','.json':'application/json','.png':'image/png','.woff2':'font/woff2','.wasm':'application/wasm'};
function serve(req,res,dir,relative,fallback=false) {
  const target=path.resolve(dir,relative||'index.html');
  if(target!==dir&&!target.startsWith(dir+path.sep)){res.writeHead(404).end();return;}
  let file=target;
  if(!fs.existsSync(file)||!fs.statSync(file).isFile()) {
    if(fallback&&!path.extname(relative))file=path.join(dir,'index.html');
    else {res.writeHead(404).end();return;}
  }
  res.writeHead(200,{'Content-Type':mime[path.extname(file)]||'application/octet-stream','Cache-Control':'no-store'});
  if(req.method==='HEAD'){res.end();return;}
  const stream=fs.createReadStream(file);stream.on('error',()=>res.destroy());stream.pipe(res);
}
const server=http.createServer((req,res)=>{
  let pathname;
  try{pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);}catch{res.writeHead(400).end();return;}
  if(pathname==='/')return serve(req,res,path.join(root,'apps/website'),'index.html');
  if(pathname.startsWith('/website/'))return serve(req,res,path.join(root,'apps/website'),pathname.slice(9));
  if(pathname==='/console'){res.writeHead(308,{Location:'/console/'}).end();return;}
  if(pathname.startsWith('/console/'))return serve(req,res,path.join(root,'apps/agent_console/build/web'),pathname.slice(9),true);
  const proxy=http.request(upstream.origin+req.url,{method:req.method,headers:{...req.headers,host:upstream.host}},response=>{
    res.writeHead(response.statusCode,response.headers);response.pipe(res);
  });
  proxy.on('error',()=>{if(!res.headersSent)res.writeHead(502);res.end('本地 API 暂不可用');});
  req.pipe(proxy);
});
server.on('upgrade',(req,socket,head)=>{
  const remote=net.connect(Number(upstream.port||80),upstream.hostname,()=>{
    const headers={...req.headers,host:upstream.host};
    remote.write(`${req.method} ${req.url} HTTP/1.1\r\n`+Object.entries(headers).map(([k,v])=>`${k}: ${v}`).join('\r\n')+'\r\n\r\n');
    if(head.length)remote.write(head);
    socket.pipe(remote);remote.pipe(socket);
  });
  remote.on('error',()=>socket.destroy());socket.on('error',()=>remote.destroy());
  socket.on('close',()=>remote.destroy());remote.on('close',()=>socket.destroy());
});
server.listen(port,'127.0.0.1',()=>console.log(`通语本地验收：http://127.0.0.1:${port}/`));
