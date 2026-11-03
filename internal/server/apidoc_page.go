package server

import "html/template"

// openAPIPage is the reader-facing shell around the rendered Markdown. It is a
// single self-contained document: no CDN, no external CSS or JS, so an instance
// behind an air gap renders the same as a public one.
var openAPIPage = template.Must(template.New("openapi").Parse(`<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<title>{{.Title}}</title>
<style>
:root{
  --bg:#f4f6fb; --panel:#fff; --ink:#101828; --ink2:#344054; --muted:#667085;
  --line:#e4e9f2; --line2:#d3dbe8; --brand:#2f5cf6; --brand-soft:#eef3ff;
  --code-bg:#0f1a2b; --code-bar:#132135;
  --shadow:0 1px 2px rgba(16,24,40,.04),0 8px 24px -12px rgba(16,24,40,.12);
}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--ink);
  font:15px/1.75 -apple-system,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;
  -webkit-font-smoothing:antialiased}
a{color:var(--brand);text-decoration:none}
a:hover{text-decoration:underline}
::selection{background:#dbe6ff}

/* ---------- top bar ---------- */
header.top{position:sticky;top:0;z-index:40;background:rgba(255,255,255,.88);
  backdrop-filter:saturate(180%) blur(12px);border-bottom:1px solid var(--line)}
.bar{max-width:1400px;margin:0 auto;padding:0 24px;height:62px;display:flex;align-items:center;gap:18px}
.brand{display:flex;align-items:center;gap:11px;color:inherit;min-width:0}
.brand:hover{text-decoration:none}
.mark{width:32px;height:32px;flex:none;display:block}
.brand-name{font-size:16px;font-weight:700;letter-spacing:.4px;white-space:nowrap}
.doc-pick{position:relative;display:flex;align-items:center}
.doc-pick select{appearance:none;-webkit-appearance:none;height:32px;padding:0 30px 0 11px;
  border:1px solid var(--line2);border-radius:8px;background:#fbfcfe;color:var(--ink);
  font:600 13.5px/1 inherit;cursor:pointer;outline:none;max-width:220px}
.doc-pick select:hover{border-color:#b9c6da;background:#fff}
.doc-pick select:focus{border-color:#a9c0ff;box-shadow:0 0 0 3px #eaf0ff}
.pick-arrow{position:absolute;right:9px;width:12px;height:12px;stroke:#667085;fill:none;
  stroke-width:2;pointer-events:none}
.top-meta{display:flex;align-items:center;gap:8px;margin-left:4px}
.pill{display:inline-block;font:600 11px/1 ui-monospace,Consolas,monospace;letter-spacing:.06em;
  padding:5px 8px;border-radius:6px;background:var(--brand-soft);color:var(--brand);border:1px solid #d8e3ff}
.upd{font-size:12px;color:var(--muted);white-space:nowrap}
.top-links{margin-left:auto;display:flex;align-items:center;gap:6px;font-size:13.5px}
.top-links a{padding:6px 10px;border-radius:7px;color:var(--ink2)}
.top-links a:hover{background:#f1f4fa;text-decoration:none;color:var(--ink)}
.top-links a.ghost{border:1px solid var(--line2);color:var(--ink2)}
.top-links a.ghost:hover{border-color:#b9c6da;background:#fff}

/* ---------- layout ---------- */
.wrap{max-width:1400px;margin:0 auto;padding:22px 24px 80px;
  display:grid;grid-template-columns:296px minmax(0,1fr);gap:26px;align-items:start}

/* ---------- sidebar ---------- */
.side{position:sticky;top:84px;display:flex;flex-direction:column;max-height:calc(100vh - 108px);
  background:var(--panel);border:1px solid var(--line);border-radius:14px;box-shadow:var(--shadow)}
.search{position:relative;padding:12px 12px 10px;border-bottom:1px solid var(--line);flex:none}
.search svg{position:absolute;left:22px;top:22px;width:15px;height:15px;stroke:#98a2b3;fill:none;stroke-width:2}
#doc-search{width:100%;height:36px;padding:0 30px 0 32px;border:1px solid var(--line2);border-radius:9px;
  background:#fbfcfe;font:inherit;font-size:13.5px;color:var(--ink);outline:none}
#doc-search:focus{border-color:#a9c0ff;background:#fff;box-shadow:0 0 0 3px #eaf0ff}
#doc-search::-webkit-search-cancel-button{display:none}
.kbd{position:absolute;right:22px;top:23px;font:600 10px/1 ui-monospace,monospace;color:#98a2b3;
  border:1px solid var(--line2);border-radius:4px;padding:3px 5px;background:#fff;pointer-events:none}
#doc-search:focus ~ .kbd{opacity:0}
.results{position:absolute;left:12px;top:60px;z-index:30;width:404px;max-width:calc(100vw - 44px);
  background:#fff;border:1px solid var(--line2);
  border-radius:11px;box-shadow:0 12px 32px -8px rgba(16,24,40,.22);max-height:min(58vh,460px);overflow:auto;padding:5px}
.hit{display:block;padding:8px 10px;border-radius:8px;color:inherit}
.hit:hover,.hit.is-cursor{background:#f4f7ff;text-decoration:none}
.hit-top{display:flex;align-items:center;gap:7px;margin-bottom:2px}
.hit-sec{font-size:11.5px;color:var(--brand);font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.hit-kind{font-size:10px;color:var(--muted);border:1px solid var(--line);border-radius:4px;padding:1px 4px;flex:none}
.hit-text{display:block;font-size:12.5px;line-height:1.55;color:var(--ink2);
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.hit-text mark{background:#fff2c2;color:inherit;border-radius:2px;padding:0 1px}
.no-hit{padding:14px 12px;color:var(--muted);font-size:13px;text-align:center}
.toc{overflow:auto;padding:10px 8px 12px;min-height:0;overscroll-behavior:contain}
.nav-group{margin-bottom:1px}
.nav-row{display:flex;align-items:center;border-radius:7px}
.nav-row:hover{background:#f6f8fc}
.nav-row a.lv2{flex:1;min-width:0;display:block;padding:5px 6px 5px 9px;font-size:13.5px;font-weight:600;
  color:#25324a;border-radius:7px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.nav-row a.lv2:hover{text-decoration:none;color:var(--brand)}
.nav-fold{flex:none;width:22px;height:24px;margin-right:2px;display:grid;place-items:center;border:0;
  background:transparent;cursor:pointer;border-radius:5px;color:#98a2b3;padding:0}
.nav-fold:hover{background:#e9eefa;color:#475467}
.nav-fold svg{width:12px;height:12px;stroke:currentColor;fill:none;stroke-width:2;transition:transform .16s}
.nav-group.is-collapsed .nav-fold svg{transform:rotate(-90deg)}
.nav-sub{display:block;padding:0 0 4px}
.nav-group.is-collapsed .nav-sub{display:none}
.nav-sub a.lv3{display:block;padding:4px 8px 4px 24px;font-size:12.8px;color:#5b6b85;border-radius:6px;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap;border-left:2px solid transparent}
.nav-sub a.lv3:hover{background:#f6f8fc;color:var(--brand);text-decoration:none}
.nav-sub a.lv3.is-active{color:var(--brand);background:var(--brand-soft);border-left-color:var(--brand);font-weight:600}
a.lv2.is-active{color:var(--brand);background:var(--brand-soft)}
.side-foot{flex:none;border-top:1px solid var(--line);padding:9px 14px;font-size:12.5px}
.side-foot a{color:var(--muted)}
.side-foot a:hover{color:var(--brand)}

/* ---------- article ---------- */
article{background:var(--panel);border:1px solid var(--line);border-radius:16px;
  padding:8px 44px 52px;min-width:0;box-shadow:var(--shadow)}
article > :first-child{margin-top:30px}
.doc-meta{color:var(--muted);font-size:13px;margin:0 0 18px;padding-bottom:14px;
  border-bottom:1px solid var(--line);line-height:1.9}
.doc-meta strong{color:#475467;font-weight:600}
h1{font-size:29px;line-height:1.34;letter-spacing:-.2px;margin:26px 0 14px;font-weight:700}
h2{font-size:20.5px;margin:46px 0 14px;padding-bottom:10px;border-bottom:1px solid var(--line);
  scroll-margin-top:80px;position:relative;font-weight:650}
h3{font-size:16px;margin:30px 0 10px;color:#16233a;scroll-margin-top:80px;position:relative;font-weight:650}
h4{font-size:14.5px;margin:22px 0 8px;color:#2a3550}
.hlink{margin-left:8px;color:#c3cddd;font-weight:400;opacity:0;transition:opacity .12s;font-size:.9em}
h2:hover .hlink,h3:hover .hlink,.hlink:focus{opacity:1}
.hlink:hover{color:var(--brand);text-decoration:none}
p{margin:11px 0;color:#232f45}
p.label{margin:20px 0 8px;font-size:14px;color:#16233a}
ul,ol{margin:10px 0 14px;padding-left:22px}
li{margin:5px 0;color:#232f45}
li::marker{color:#98a2b3}
code{font-family:ui-monospace,SFMono-Regular,Consolas,"Liberation Mono",monospace;font-size:.875em;
  background:#f0f4fb;padding:1.5px 5px;border-radius:5px;color:#1c2b45;border:1px solid #e6ecf6}
a code{color:var(--brand)}
.note{background:#f5f8fe;border:1px solid #dbe5f9;border-left:3px solid var(--brand);border-radius:10px;
  padding:11px 15px;margin:16px 0 20px;color:#22314c;font-size:14px}
.note code{background:#e7eefc;border-color:#d6e2f8}
.note a{text-decoration:underline}

/* ---------- tables ---------- */
.table-wrap{overflow-x:auto;margin:14px 0 22px;border:1px solid var(--line2);border-radius:10px;background:#fff}
table{width:100%;border-collapse:collapse;font-size:13.5px}
th{background:#f7f9fd;color:#1a2434;font-weight:600;text-align:left;padding:10px 14px;
  border-bottom:1px solid var(--line2);white-space:nowrap}
td{padding:10px 14px;border-bottom:1px solid #eff3f9;vertical-align:top;color:#2b3648;line-height:1.65}
.nb{white-space:nowrap}
tbody tr:last-child td{border-bottom:0}
tbody tr:hover{background:#fbfcff}
td code,th code{white-space:nowrap}

/* ---------- code ---------- */
.code{margin:16px 0 22px;border-radius:12px;overflow:hidden;background:var(--code-bg);
  border:1px solid #0a1421;box-shadow:0 6px 20px -12px rgba(15,26,43,.6)}
.code-bar{display:flex;align-items:center;justify-content:space-between;gap:10px;
  padding:7px 10px 7px 14px;background:var(--code-bar);border-bottom:1px solid #1c2c46}
.code-lang{font:600 10.5px/1 ui-monospace,Consolas,monospace;letter-spacing:.1em;color:#7e95b8;text-transform:uppercase}
.code-actions{display:flex;gap:6px;flex:none}
.code-tabs{display:flex;gap:2px;flex:1;min-width:0;overflow-x:auto;scrollbar-width:none}
.code-tabs::-webkit-scrollbar{display:none}
.code-tab{appearance:none;border:0;background:transparent;color:#7e95b8;
  font:600 11.5px/1 inherit;padding:6px 9px;border-radius:6px;cursor:pointer;white-space:nowrap;
  transition:background .12s,color .12s}
.code-tab:hover{color:#cfe0f7;background:#1a2a41}
.code-tab.is-on{color:#eaf2ff;background:#22354f}
.code-tab:focus-visible{outline:2px solid #3f63a0;outline-offset:-2px}
pre[hidden]{display:none}
.code-btn{appearance:none;border:1px solid #29394f;background:#1a2a41;color:#b6c8e0;
  font:500 12px/1 inherit;padding:5px 9px;border-radius:6px;cursor:pointer;transition:background .12s,color .12s}
.code-btn:hover{background:#243650;color:#eaf1fc;border-color:#3a5075}
.code-btn:active{transform:translateY(.5px)}
.code-btn.is-done{color:#7ee2a8;border-color:#2b6247;background:#16301f}
.code-try{color:#a9c6ff;border-color:#314d79}
pre{margin:0;padding:14px 16px;overflow:auto;background:var(--code-bg)}
pre code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:12.8px;line-height:1.72;
  color:#dbe6f5;background:none;border:0;padding:0;white-space:pre}
.j-key{color:#8fb6ff}
.j-str{color:#a8e6b4}
.j-num{color:#f3c88a}
.j-lit{color:#d6a8ff}
.j-kw{color:#7fb6ff}
.j-pun{color:#7d90ac}
.c-cmt{color:#6a7f9c;font-style:italic}
.h-path{color:#cfe1ff}
.h-ver{color:#5f7699}
.h-key{color:#8fb6ff}
.h-val{color:#a8e6b4}
.code .m{min-width:auto;padding:2px 7px;font-size:10.5px;vertical-align:1px}
.code .m-get{background:#12351f;color:#7ee2a8}
.code .m-post{background:#12294d;color:#8fb6ff}
.code .m-put{background:#2a1f45;color:#c9a8ff}
.code .m-patch{background:#3a2a12;color:#f0c07a}
.code .m-delete{background:#3a1a1a;color:#f19a96}

/* ---------- method pills ---------- */
.m{display:inline-block;min-width:56px;text-align:center;font:700 11px/1 ui-monospace,Consolas,monospace;
  padding:5px 7px;border-radius:6px;letter-spacing:.04em}
.m-get{background:#e4f6ea;color:#137a3c}
.m-post{background:#e6efff;color:#1a4fc4}
.m-patch{background:#fdf1e2;color:#9a5b12}
.m-put{background:#f0e9fb;color:#6334ad}
.m-delete{background:#fdeaea;color:#b3261e}

/* ---------- try panel ---------- */
.try-panel{border-top:1px solid #1c2c46;background:#111d2e;padding:12px 14px 14px;
  display:flex;flex-direction:column;gap:9px}
.try-row{display:grid;grid-template-columns:1fr 1fr;gap:9px}
.try-field{display:flex;flex-direction:column;gap:4px;min-width:0}
.try-field span{font:600 10.5px/1 ui-monospace,monospace;letter-spacing:.08em;color:#7e95b8;text-transform:uppercase}
.try-in{width:100%;height:30px;padding:0 9px;border-radius:6px;border:1px solid #2a3c55;
  background:#0c1725;color:#dbe6f5;font:12.5px ui-monospace,Consolas,monospace;outline:none}
.try-in:focus{border-color:#3f63a0;box-shadow:0 0 0 2px #1b2c45}
.try-req{width:100%;min-height:132px;resize:vertical;padding:9px;border-radius:6px;border:1px solid #2a3c55;
  background:#0c1725;color:#dbe6f5;font:12.5px/1.6 ui-monospace,Consolas,monospace;outline:none}
.try-req:focus{border-color:#3f63a0;box-shadow:0 0 0 2px #1b2c45}
.try-params{display:flex;flex-direction:column;gap:6px}
.try-params-head{display:flex;align-items:center;justify-content:space-between;gap:8px}
.try-params-head > span{font:600 10.5px/1 ui-monospace,monospace;letter-spacing:.08em;color:#7e95b8;text-transform:uppercase}
.try-add{padding:4px 8px;font-size:11.5px}
.try-param-rows{display:flex;flex-direction:column;gap:6px}
.try-param{display:grid;grid-template-columns:1fr 1fr 26px;gap:6px;align-items:center}
.try-del{appearance:none;width:26px;height:30px;padding:0;border-radius:6px;border:1px solid #2a3c55;
  background:#1a2a41;color:#93a7c2;font:14px/1 inherit;cursor:pointer}
.try-del:hover{background:#3a1a1a;border-color:#5c2a2a;color:#f19a96}
.try-foot{display:flex;align-items:center;gap:10px}
.try-send{background:#22406b;border-color:#2f578f;color:#dce9ff}
.try-send:hover{background:#2a4d80}
.try-send[disabled]{opacity:.6;cursor:progress}
.try-hint{font-size:11.5px;color:#7189a8}
.try-out{font-size:12.5px}
.try-status{display:flex;align-items:center;gap:9px;margin:2px 0 7px}
.st{font:600 11px/1 ui-monospace,monospace;padding:4px 8px;border-radius:5px}
.st-ok{background:#12351f;color:#7ee2a8}
.st-err{background:#3a1a1a;color:#f19a96}
.try-ms{color:#7189a8;font-size:11.5px}
pre.try-body{margin:0;background:#0c1725;border:1px solid #22324a;border-radius:7px;max-height:340px}

/* ---------- footer + to top ---------- */
footer{max-width:1400px;margin:0 auto;padding:0 24px 40px;color:var(--muted);font-size:12.5px;
  display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}
footer a{color:var(--muted)}
#to-top{position:fixed;right:22px;bottom:22px;width:38px;height:38px;border-radius:10px;border:1px solid var(--line2);
  background:#fff;color:#475467;display:grid;place-items:center;cursor:pointer;opacity:0;pointer-events:none;
  transition:opacity .18s,transform .18s;box-shadow:var(--shadow);z-index:35}
#to-top.show{opacity:1;pointer-events:auto}
#to-top:hover{color:var(--brand);border-color:#b9c6da}
#to-top svg{width:16px;height:16px;stroke:currentColor;fill:none;stroke-width:2}

/* ---------- responsive ---------- */
@media (max-width:1080px){
  .wrap{grid-template-columns:1fr;padding:16px 16px 64px}
  .side{position:static;max-height:none}
  .toc{max-height:264px}
  article{padding:6px 26px 40px}
}
@media (max-width:820px){
  .bar{padding:0 14px;gap:10px}
  .top-meta,.top-links a:not(.ghost){display:none}
  article{padding:4px 18px 32px}
  h1{font-size:24px}
  h2{font-size:18.5px}
  /* Five sample tabs plus two buttons have to share a phone-width bar. */
  .code-bar{padding:6px 8px 6px 6px;gap:6px}
  .code-tab{padding:6px 7px;font-size:11px}
  .code-btn{padding:5px 7px;font-size:11.5px}
  .try-row{grid-template-columns:1fr}
  .table-wrap{border:0;background:transparent;overflow:visible}
  .table-wrap table,.table-wrap thead,.table-wrap tbody,.table-wrap tr,.table-wrap td{display:block;width:100%}
  .table-wrap thead{display:none}
  .table-wrap tr{border:1px solid var(--line2);border-radius:10px;margin-bottom:10px;background:#fff;overflow:hidden}
  .table-wrap td{border:0;padding:7px 12px;display:grid;grid-template-columns:92px 1fr;gap:10px;align-items:baseline}
  .table-wrap td+td{border-top:1px solid #f1f5fa}
  .table-wrap td::before{content:attr(data-label);color:var(--muted);font-size:11.5px;font-weight:600;
    letter-spacing:.02em;overflow-wrap:anywhere}
  .table-wrap td code{white-space:normal;overflow-wrap:anywhere}
}
@media print{
  header.top,.side,#to-top,footer{display:none}
  .wrap{display:block;padding:0}
  article{border:0;box-shadow:none;padding:0}
  .code{break-inside:avoid}
  .table-wrap{break-inside:avoid}
}
</style>
</head>
<body>
<header class="top"><div class="bar">
  <a class="brand" href="/docs">
    <svg class="mark" viewBox="0 0 32 32" aria-hidden="true">
      <defs><linearGradient id="mk" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="#3f6bff"/><stop offset="1" stop-color="#1f3fd0"/>
      </linearGradient></defs>
      <rect width="32" height="32" rx="9" fill="url(#mk)"/>
      <path d="M9 10.6h14v8.6h-7.1L11.6 22v-2.8H9z" fill="#fff"/>
    </svg>
    <span class="brand-name">通语</span>
  </a>
  <div class="doc-pick">
    <select id="doc-switch" aria-label="切换文档">
      {{range .Docs}}<option value="/docs/{{.Slug}}"{{if .Active}} selected{{end}}>{{.Label}}</option>{{end}}
    </select>
    <svg class="pick-arrow" viewBox="0 0 16 16" aria-hidden="true"><path d="M4 6l4 4 4-4"/></svg>
  </div>
  {{if .Version}}<div class="top-meta"><span class="pill">{{.Version}}</span>{{if .Updated}}<span class="upd">更新 {{.Updated}}</span>{{end}}</div>{{end}}
  <div class="top-links">
    {{if .HasIndex}}<a href="#s-接口目录">接口目录</a>{{end}}
    {{if .HasCodes}}<a href="#s-错误码">错误码</a>{{end}}
    <a href="{{.Markdown}}">Markdown</a>
    <a class="ghost" href="{{.Spec}}" title="OpenAPI 3.1 规范，可导入 Postman / Apifox">OpenAPI</a>
  </div>
</div></header>

<div class="wrap">
  <aside class="side">
    <div class="search">
      <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.6-3.6"/></svg>
      <input id="doc-search" type="search" placeholder="搜索接口、字段、错误码" autocomplete="off" spellcheck="false" aria-label="搜索文档">
      <span class="kbd">/</span>
      <div id="search-results" class="results" hidden></div>
    </div>
    <nav class="toc" id="toc" aria-label="目录">{{.Nav}}</nav>
    <div class="side-foot"><a href="{{.Markdown}}">下载 Markdown 原文</a> · <a href="{{.Spec}}">OpenAPI JSON</a></div>
  </aside>
  <article>{{.Body}}</article>
</div>

<footer>
  <span>通语 · 开放接口文档{{if .Version}} {{.Version}}{{end}}{{if .Updated}} · 更新于 {{.Updated}}{{end}}</span>
  <span>本页随服务端二进制发布 · <a href="{{.Markdown}}">Markdown</a> · <a href="{{.Spec}}">OpenAPI 3.1</a></span>
</footer>

<button id="to-top" type="button" aria-label="回到顶部"><svg viewBox="0 0 24 24"><path d="M12 19V5M5 12l7-7 7 7"/></svg></button>

<script type="application/json" id="doc-index">{{.Index}}</script>
<script>
(function () {
  'use strict';
  var doc = document;
  var nav = doc.getElementById('toc');
  var article = doc.querySelector('article');
  var input = doc.getElementById('doc-search');
  var results = doc.getElementById('search-results');
  var toTop = doc.getElementById('to-top');

  var switcher = doc.getElementById('doc-switch');
  if (switcher) {
    switcher.addEventListener('change', function () {
      if (switcher.value) location.href = switcher.value;
    });
  }

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  /* ----- reading position: highlight the section the reader is in ----- */
  var navLinks = nav ? Array.prototype.slice.call(nav.querySelectorAll('a[href^="#"]')) : [];
  var linkById = {};
  navLinks.forEach(function (a) { linkById[a.getAttribute('href').slice(1)] = a; });
  var heads = article ? Array.prototype.slice.call(article.querySelectorAll('h2[id],h3[id]')) : [];
  var activeId = '', ticking = false;

  function setActive(id) {
    if (id === activeId || !nav) return;
    activeId = id;
    navLinks.forEach(function (a) {
      a.classList.toggle('is-active', a.getAttribute('href') === '#' + id);
    });
    var link = linkById[id];
    if (!link) return;
    // On narrow screens the sidebar is a static block, so following the
    // reading position would scroll it under the reader's finger.
    if (window.innerWidth < 1081) return;
    var nr = nav.getBoundingClientRect(), ar = link.getBoundingClientRect();
    if (ar.top < nr.top + 4 || ar.bottom > nr.bottom - 4) {
      nav.scrollTop += (ar.top - nr.top) - nav.clientHeight / 2 + ar.height / 2;
    }
  }

  function spy() {
    ticking = false;
    if (!heads.length) return;
    var current = heads[0];
    for (var i = 0; i < heads.length; i++) {
      if (heads[i].getBoundingClientRect().top <= 92) current = heads[i]; else break;
    }
    setActive(current.id);
  }

  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(spy);
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll);
  spy();

  if (toTop) {
    window.addEventListener('scroll', function () {
      toTop.classList.toggle('show', window.scrollY > 640);
    }, { passive: true });
    toTop.addEventListener('click', function () {
      window.scrollTo({ top: 0, behavior: 'smooth' });
    });
  }

  /* ----- collapsible nav groups ----- */
  if (nav) {
    nav.addEventListener('click', function (e) {
      var btn = e.target.closest ? e.target.closest('.nav-fold') : null;
      if (!btn) return;
      var group = btn.closest('.nav-group');
      var collapsed = group.classList.toggle('is-collapsed');
      btn.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
    });
  }

  /* ----- language tabs inside a sample block ----- */
  // The cURL / JavaScript / Python / Go snippets are generated from the same
  // parsed request, so switching a tab never changes what is being called.
  doc.addEventListener('click', function (e) {
    var tab = e.target.closest ? e.target.closest('.code-tab') : null;
    if (!tab) return;
    var block = tab.closest('.code');
    if (!block) return;
    var key = tab.getAttribute('data-tab');
    var tabs = block.querySelectorAll('.code-tab');
    for (var i = 0; i < tabs.length; i++) {
      var on = tabs[i] === tab;
      tabs[i].classList.toggle('is-on', on);
      tabs[i].setAttribute('aria-selected', on ? 'true' : 'false');
    }
    var panels = block.querySelectorAll('pre[data-panel]');
    for (var j = 0; j < panels.length; j++) {
      panels[j].hidden = panels[j].getAttribute('data-panel') !== key;
    }
  });

  /* ----- copy buttons ----- */
  function legacyCopy(text) {
    var ta = doc.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.top = '-2000px';
    doc.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = doc.execCommand('copy'); } catch (err) { ok = false; }
    doc.body.removeChild(ta);
    return ok;
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).then(function () { return true; },
        function () { return legacyCopy(text); });
    }
    return Promise.resolve(legacyCopy(text));
  }

  doc.addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('.code-copy') : null;
    if (!btn) return;
    var block = btn.closest('.code');
    // Copy what the reader is looking at, not whichever panel happens to be first.
    var code = block ? (block.querySelector('pre[data-panel]:not([hidden]) code') || block.querySelector('code')) : null;
    copyText(code ? code.textContent : '').then(function (ok) {
      btn.textContent = ok ? '已复制' : '复制失败';
      btn.classList.toggle('is-done', ok);
      setTimeout(function () {
        btn.textContent = '复制';
        btn.classList.remove('is-done');
      }, 1400);
    });
  });

  /* ----- search over the rendered blocks ----- */
  var INDEX = [];
  try {
    var raw = doc.getElementById('doc-index');
    INDEX = raw ? JSON.parse(raw.textContent || '[]') : [];
  } catch (err) { INDEX = []; }

  function mark(text, q) {
    var lower = text.toLowerCase(), out = '', at = 0, idx;
    while ((idx = lower.indexOf(q, at)) >= 0) {
      out += esc(text.slice(at, idx)) + '<mark>' + esc(text.slice(idx, idx + q.length)) + '</mark>';
      at = idx + q.length;
    }
    return out + esc(text.slice(at));
  }

  function runSearch(q) {
    if (!results) return;
    q = q.trim().toLowerCase();
    if (!q) { results.hidden = true; results.innerHTML = ''; return; }
    var hits = [], seen = {};
    for (var i = 0; i < INDEX.length && hits.length < 40; i++) {
      var item = INDEX[i];
      if (!item || !item.t) continue;
      var pos = item.t.toLowerCase().indexOf(q);
      if (pos < 0) continue;
      var key = item.id + '|' + item.t.slice(0, 32);
      if (seen[key]) continue;
      seen[key] = 1;
      hits.push(item);
    }
    if (!hits.length) {
      results.innerHTML = '<div class="no-hit">没有匹配「' + esc(q) + '」的内容</div>';
      results.hidden = false;
      return;
    }
    results.innerHTML = hits.map(function (item) {
      var sec = item.s ? '<span class="hit-sec">' + esc(item.s) + '</span>' : '';
      var kind = item.k ? '<span class="hit-kind">' + esc(item.k) + '</span>' : '';
      return '<a class="hit" href="#' + esc(item.id) + '"><span class="hit-top">' + sec + kind +
        '</span><span class="hit-text">' + mark(item.t, q) + '</span></a>';
    }).join('');
    results.hidden = false;
  }

  if (input) {
    var timer = 0;
    input.addEventListener('input', function () {
      clearTimeout(timer);
      timer = setTimeout(function () { runSearch(input.value); }, 70);
    });
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        var first = results ? results.querySelector('.hit') : null;
        if (first) {
          e.preventDefault();
          location.hash = first.getAttribute('href');
          results.hidden = true;
          input.blur();
        }
      } else if (e.key === 'Escape') {
        input.value = '';
        runSearch('');
        input.blur();
      }
    });
    input.addEventListener('focus', function () {
      if (input.value.trim()) runSearch(input.value);
    });
  }

  doc.addEventListener('click', function (e) {
    if (!results || results.hidden) return;
    if (results.contains(e.target) || (input && input.contains(e.target))) return;
    results.hidden = true;
  });

  doc.addEventListener('keydown', function (e) {
    if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return;
    var el = doc.activeElement;
    var typing = el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);
    if (typing) return;
    e.preventDefault();
    if (input) { input.focus(); input.select(); }
  });

  /* ----- request runner for HTTP samples ----- */
  function field(label, el) {
    var wrap = doc.createElement('div');
    wrap.className = 'try-field';
    var span = doc.createElement('span');
    span.textContent = label;
    wrap.appendChild(span);
    wrap.appendChild(el);
    return wrap;
  }

  function parseRequest(text) {
    var lines = text.replace(/\r/g, '').split('\n');
    var req = { method: 'GET', path: '', headers: {}, body: null };
    var i = 0, m;
    for (; i < lines.length; i++) {
      var t = lines[i].trim();
      if (!t) continue;
      m = t.match(/^(GET|POST|PUT|PATCH|DELETE)\s+(\S+)/);
      if (m) { req.method = m[1]; req.path = m[2]; i++; break; }
    }
    for (; i < lines.length; i++) {
      var line = lines[i], tr = line.trim();
      if (!tr) {
        if (lines.slice(i + 1).join('').trim()) { req.body = lines.slice(i + 1).join('\n').trim(); }
        break;
      }
      if (tr.charAt(0) === '{' || tr.charAt(0) === '[') { req.body = lines.slice(i).join('\n').trim(); break; }
      var ci = tr.indexOf(':');
      if (ci > 0) { req.headers[tr.slice(0, ci).trim()] = tr.slice(ci + 1).trim(); }
    }
    return req;
  }

  /* ----- query string helpers ----- */
  function decodeSafe(s) {
    try { return decodeURIComponent(s.replace(/\+/g, ' ')); } catch (err) { return s; }
  }

  // Keep angle brackets and braces intact so "<conversationId>" style
  // placeholders stay readable while the request is being assembled.
  function encParam(s) {
    return String(s).replace(/&/g, '%26').replace(/#/g, '%23').replace(/\s/g, '%20');
  }

  function firstPath(text) {
    var lines = String(text).replace(/\r/g, '').split('\n');
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].trim().match(/^(GET|POST|PUT|PATCH|DELETE)\s+(\S+)/);
      if (m) return m[2];
    }
    return '';
  }

  function splitQuery(path) {
    var qi = path.indexOf('?');
    if (qi < 0) return { base: path, params: [] };
    var params = [];
    path.slice(qi + 1).split('&').forEach(function (pair) {
      if (!pair) return;
      var eq = pair.indexOf('=');
      if (eq < 0) { params.push({ name: decodeSafe(pair), value: '' }); return; }
      params.push({ name: decodeSafe(pair.slice(0, eq)), value: decodeSafe(pair.slice(eq + 1)) });
    });
    return { base: path.slice(0, qi), params: params };
  }

  function buildPath(base, params) {
    var parts = [];
    params.forEach(function (p) {
      if (!p.name) return;
      parts.push(encParam(p.name) + (p.value === '' ? '' : '=' + encParam(p.value)));
    });
    return parts.length ? base + '?' + parts.join('&') : base;
  }

  // buildParams is a key/value editor bound to the request text: editing a row
  // rewrites the request line, and editing the request text rebuilds the rows.
  // Both views therefore describe the same request.
  function buildParams(reqEl) {
    var box = doc.createElement('div');
    box.className = 'try-params';

    var head = doc.createElement('div');
    head.className = 'try-params-head';
    var label = doc.createElement('span');
    label.textContent = '查询参数';
    var add = doc.createElement('button');
    add.type = 'button';
    add.className = 'code-btn try-add';
    add.textContent = '添加参数';
    head.appendChild(label);
    head.appendChild(add);

    var rows = doc.createElement('div');
    rows.className = 'try-param-rows';
    box.appendChild(head);
    box.appendChild(rows);

    var syncing = false;

    function currentParams() {
      var out = [];
      var nodes = rows.querySelectorAll('.try-param');
      for (var i = 0; i < nodes.length; i++) {
        var inputs = nodes[i].querySelectorAll('input');
        out.push({ name: inputs[0].value.trim(), value: inputs[1].value.trim() });
      }
      return out;
    }

    function syncToText() {
      if (syncing) return;
      syncing = true;
      var lines = reqEl.value.replace(/\r/g, '').split('\n');
      for (var i = 0; i < lines.length; i++) {
        var m = lines[i].match(/^(\s*)(GET|POST|PUT|PATCH|DELETE)\s+(\S+)(.*)$/);
        if (!m) continue;
        lines[i] = m[1] + m[2] + ' ' + buildPath(splitQuery(m[3]).base, currentParams()) + m[4];
        break;
      }
      reqEl.value = lines.join('\n');
      syncing = false;
    }

    function rowFor(param) {
      var row = doc.createElement('div');
      row.className = 'try-param';

      var name = doc.createElement('input');
      name.className = 'try-in';
      name.placeholder = '名称';
      name.value = param.name;

      var value = doc.createElement('input');
      value.className = 'try-in';
      value.placeholder = '值';
      value.value = param.value;

      var del = doc.createElement('button');
      del.type = 'button';
      del.className = 'try-del';
      del.setAttribute('aria-label', '删除该参数');
      del.textContent = '×';

      name.addEventListener('input', syncToText);
      value.addEventListener('input', syncToText);
      del.addEventListener('click', function () {
        rows.removeChild(row);
        syncToText();
      });

      row.appendChild(name);
      row.appendChild(value);
      row.appendChild(del);
      return row;
    }

    function rebuild() {
      var parsed = splitQuery(firstPath(reqEl.value));
      rows.innerHTML = '';
      parsed.params.forEach(function (p) { rows.appendChild(rowFor(p)); });
    }

    add.addEventListener('click', function () {
      var row = rowFor({ name: '', value: '' });
      rows.appendChild(row);
      row.querySelector('input').focus();
    });

    var timer = 0;
    reqEl.addEventListener('input', function () {
      if (syncing) return;
      clearTimeout(timer);
      timer = setTimeout(rebuild, 160);
    });

    rebuild();
    return box;
  }

  function showResponse(out, res, text, ms) {
    out.innerHTML = '';
    var head = doc.createElement('div');
    head.className = 'try-status';
    var pill = doc.createElement('span');
    pill.className = 'st ' + (res.ok ? 'st-ok' : 'st-err');
    pill.textContent = res.status + ' ' + (res.statusText || '');
    var meta = doc.createElement('span');
    meta.className = 'try-ms';
    meta.textContent = ms + ' ms';
    head.appendChild(pill);
    head.appendChild(meta);
    out.appendChild(head);

    var pre = doc.createElement('pre');
    pre.className = 'try-body';
    var code = doc.createElement('code');
    var pretty = text;
    try { pretty = JSON.stringify(JSON.parse(text), null, 2); } catch (err) { pretty = text; }
    code.textContent = pretty || '(空响应)';
    pre.appendChild(code);
    out.appendChild(pre);
  }

  function runTry(base, key, text, out, btn) {
    var req = parseRequest(text);
    if (!req.path) { out.textContent = '没有找到请求行，请保留形如 GET /api/v1/open/me 的首行。'; return; }
    var headers = {};
    Object.keys(req.headers).forEach(function (name) {
      var value = req.headers[name];
      if (value.indexOf('<') >= 0) {
        if (/^x-tongyu-key$/i.test(name) && key) value = key;
        else if (/^authorization$/i.test(name) && key) value = 'Bearer ' + key;
        else return;
      }
      headers[name] = value;
    });
    var init = { method: req.method, headers: headers };
    if (req.body && req.method !== 'GET') init.body = req.body;
    var url = (base || location.origin).replace(/\/+$/, '') + req.path;

    btn.disabled = true;
    btn.textContent = '请求中…';
    out.textContent = '';
    var started = performance.now();
    fetch(url, init).then(function (res) {
      return res.text().then(function (body) {
        return { res: res, body: body };
      });
    }).then(function (r) {
      showResponse(out, r.res, r.body, Math.round(performance.now() - started));
    }).catch(function (err) {
      out.textContent = '请求失败：' + err.message + '（检查地址、网络或跨域限制）';
    }).then(function () {
      btn.disabled = false;
      btn.textContent = '发送请求';
    });
  }

  function buildTryPanel(block) {
    var panel = doc.createElement('div');
    panel.className = 'try-panel';

    var base = doc.createElement('input');
    base.className = 'try-in';
    // A copy opened straight from disk has no origin worth calling.
    base.value = location.protocol === 'file:' ? '' : location.origin;
    base.placeholder = 'https://chat.example.com';
    base.setAttribute('aria-label', '基础地址');

    var key = doc.createElement('input');
    key.className = 'try-in';
    key.placeholder = 'X-TongYu-Key 或 Bearer 令牌';
    key.setAttribute('aria-label', '密钥');

    var row = doc.createElement('div');
    row.className = 'try-row';
    row.appendChild(field('基础地址', base));
    row.appendChild(field('密钥', key));

    var req = doc.createElement('textarea');
    req.className = 'try-req';
    req.spellcheck = false;
    // Always seed the runner from the raw HTTP panel, even when the reader has
    // switched the block to a generated snippet.
    var code = block.querySelector('pre[data-panel="http"] code') || block.querySelector('code');
    req.value = code ? code.textContent : '';

    var params = buildParams(req);

    var out = doc.createElement('div');
    out.className = 'try-out';

    var send = doc.createElement('button');
    send.type = 'button';
    send.className = 'code-btn try-send';
    send.textContent = '发送请求';
    send.addEventListener('click', function () { runTry(base.value, key.value, req.value, out, send); });

    var hint = doc.createElement('span');
    hint.className = 'try-hint';
    hint.textContent = '请求发往当前实例，写操作会真实生效';

    var foot = doc.createElement('div');
    foot.className = 'try-foot';
    foot.appendChild(send);
    foot.appendChild(hint);

    panel.appendChild(row);
    panel.appendChild(params);
    panel.appendChild(field('请求', req));
    panel.appendChild(foot);
    panel.appendChild(out);
    return panel;
  }

  doc.addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('.code-try') : null;
    if (!btn) return;
    var block = btn.closest('.code');
    if (!block) return;
    var panel = block.querySelector('.try-panel');
    if (panel) { panel.hidden = !panel.hidden; return; }
    block.appendChild(buildTryPanel(block));
  });
})();
</script>
</body>
</html>`))
