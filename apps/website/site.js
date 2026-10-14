'use strict';
// 场景只切换静态产品说明；官网不收集联系方式，不伪造预约或开通结果。
const scenes = [
  {title:'从第一次咨询，接住每一份意向。',description:'客户在产品页面发起咨询，客服在同一个工作台接待。结合客户资料和快捷回复，让服务衔接更顺畅。',steps:['网站嵌入客服入口','客服集中接待咨询','查看客户资料并跟进'],question:'我们的网站怎么接入在线客服？',answer:'您好，可以通过网站嵌入代码接入，也可以使用独立 H5 客服链接。'},
  {title:'客户在哪里，服务就跟到哪里。',description:'用 H5 客服入口承接移动端咨询，保留会话上下文，让客户继续提问时，团队能够接着处理。',steps:['配置 H5 咨询入口','接收移动端客户消息','在工作台持续跟进'],question:'我在手机上可以继续咨询吗？',answer:'可以，您可以通过 H5 客服页面继续发送消息，我们在工作台接待。'},
  {title:'一个团队，共同完成一次好服务。',description:'按团队组织接待，将需要进一步处理的问题转给合适的同事。主管管理成员与配置，客服专注沟通。',steps:['创建团队并添加成员','按接待规则分配会话','转接同事继续处理'],question:'这个问题需要技术同事协助。',answer:'我会为您转接相关同事，当前会话记录将保留，方便继续沟通。'},
];
const tabs = [...document.querySelectorAll('[data-scene]')];
function selectScene(index,focus=false) {
  const scene=scenes[index];
  tabs.forEach((tab,i)=>{tab.setAttribute('aria-selected',String(i===index));tab.tabIndex=i===index?0:-1;});
  document.getElementById('scene-panel').setAttribute('aria-labelledby',tabs[index].id);
  for(const [id,text] of Object.entries({'scene-title':scene.title,'scene-description':scene.description,'scene-question':scene.question,'scene-answer':scene.answer,'scene-name':tabs[index].textContent})) document.getElementById(id).textContent=text;
  document.getElementById('scene-steps').replaceChildren(...scene.steps.map(text=>{const li=document.createElement('li');li.textContent=text;return li;}));
  if(focus)tabs[index].focus();
}
tabs.forEach((tab,index)=>{
  tab.addEventListener('click',()=>selectScene(index));
  tab.addEventListener('keydown',event=>{
    let next;
    if(event.key==='ArrowRight')next=(index+1)%tabs.length;
    if(event.key==='ArrowLeft')next=(index+tabs.length-1)%tabs.length;
    if(event.key==='Home')next=0;
    if(event.key==='End')next=tabs.length-1;
    if(next!==undefined){event.preventDefault();selectScene(next,true);}
  });
});
