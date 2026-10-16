"""服务器隔离验收：同一正式镜像和 AI 配置，独立临时数据库，不触碰客户会话。"""
from pathlib import Path
import json,os,secrets,subprocess,time,urllib.request,uuid

os.umask(0o077)
def run(*args):return subprocess.check_output(args,text=True,stderr=subprocess.PIPE).strip()
live=json.loads(run('docker','inspect','isolated-server-1'))[0]
env=dict(value.split('=',1) for value in live['Config']['Env'])
assert env.get('PUBLIC_BASE_URL')=='https://chat.lookfunny.xyz'
assert env.get('AI_PROVIDER')=='compatible' and env.get('AI_API_KEY')
stamp=time.strftime('%Y%m%d%H%M%S')
network='tongyu-ai-check-'+stamp
db=network+'-db';server=network+'-api'
work=Path('/tmp')/network;work.mkdir(mode=0o700)
password=secrets.token_urlsafe(28)
test=dict(env)
test.update({'DATABASE_URL':'postgres://tongyu:'+password+'@'+db+':5432/tongyu?sslmode=disable',
 'PUBLIC_BASE_URL':'http://127.0.0.1','PLATFORM_ADMIN_EMAIL':'ai-config-verifier',
 'PLATFORM_ADMIN_PASSWORD':secrets.token_urlsafe(28),'WIDGET_TOKEN_SECRET':secrets.token_urlsafe(48),'DEMO_ENABLED':'false'})
(work/'server.env').write_text(''.join(key+'='+value+'\n' for key,value in test.items()))
(work/'postgres.env').write_text('POSTGRES_USER=tongyu\nPOSTGRES_DB=tongyu\nPOSTGRES_PASSWORD='+password+'\n')
report=[]
def passed(check,**details):report.append({'check':check,**details});print('PASS '+check,flush=True)
try:
    run('docker','network','create',network)
    run('docker','run','-d','--name',db,'--network',network,'--env-file',str(work/'postgres.env'),'postgres:18.6-alpine')
    for attempt in range(30):
        if subprocess.run(['docker','exec',db,'pg_isready','-U','tongyu'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:break
        time.sleep(1)
    run('docker','run','-d','--name',server,'--network',network,'--env-file',str(work/'server.env'),'-p','127.0.0.1::8080',live['Image'])
    instance=json.loads(run('docker','inspect',server))[0]
    port=instance['NetworkSettings']['Ports']['8080/tcp'][0]['HostPort']
    base='http://127.0.0.1:'+port
    def request(method,path,body=None,token=None):
        headers={'Content-Type':'application/json'}
        if token:headers['Authorization']='Bearer '+token
        data=None if body is None else json.dumps(body,ensure_ascii=False).encode()
        req=urllib.request.Request(base+path,method=method,headers=headers,data=data)
        with urllib.request.urlopen(req,timeout=100) as response:return json.load(response)
    for attempt in range(40):
        try:
            ready=request('GET','/ready');assert ready['ai']=='openai-compatible:'+env['AI_MODEL'];break
        except Exception:
            if attempt==39:raise
            time.sleep(1)
    passed('same-production-image-and-model',image=live['Image'],model=env['AI_MODEL'])
    platform=request('POST','/api/v1/platform/login',{'email':test['PLATFORM_ADMIN_EMAIL'],'password':test['PLATFORM_ADMIN_PASSWORD']})['token']
    slug='ai-verify-'+stamp;ownerPassword=secrets.token_urlsafe(24)
    created=request('POST','/api/v1/platform/tenants',{'name':'AI隔离验收','slug':slug,'ownerEmail':'verify-owner','ownerName':'验收客服','ownerPassword':ownerPassword,'inboxName':'验收入口','publicKey':slug+'-web','plan':'GROWTH','trialDays':1},platform)
    agent=request('POST','/api/v1/console/login',{'tenantSlug':slug,'email':'verify-owner','password':ownerPassword})['token']
    request('PATCH','/api/v1/admin/inboxes/'+created['inboxId']+'/ai',{'enabled':False},agent)
    request('POST','/api/v1/console/knowledge',{'title':'发送者语音播报设置','content':'在通语工作台点击喇叭，打开声音设置，选择语音：播报发送者名称，再点击测试提示音。第一次使用需先点击页面以启用声音。','questionExamples':'如何开启发送者语音播报\n怎么知道谁发来消息','status':'ACTIVE'},agent)
    visitor=request('POST','/api/v1/widget/bootstrap',{'inboxKey':slug+'-web','displayName':'AI隔离验收访客'})['token']
    cid=request('POST','/api/v1/widget/conversations',{'subject':'发送者播报咨询'},visitor)['conversation']['id']
    for text in ['我们的项目代号是青松。','如何开启发送者语音播报？']:
        request('POST',f'/api/v1/widget/conversations/{cid}/messages',{'content':text,'messageType':'TEXT','clientMessageId':str(uuid.uuid4())},visitor)
    before=request('GET',f'/api/v1/widget/conversations/{cid}/messages',token=visitor)['items']
    for task in ['SUMMARIZE','SUGGEST']:
        start=time.monotonic()
        result=request('POST','/api/v1/console/assist',{'task':task,'conversationId':cid,'question':'如何开启发送者语音播报？' if task=='SUGGEST' else '请总结客户诉求，并包含项目代号'},agent)
        assert result['available'] and result['text'].strip() and result['provider']=='openai-compatible:'+env['AI_MODEL']
        assert result.get('usage',{}).get('totalTokens',0)>0,'Expected a real model completion'
        if task=='SUMMARIZE':assert '青松' in result['text'],'Summary did not read full history'
        else:
            assert result.get('sourceDetails'),'Suggestion did not retrieve knowledge'
            assert '播报' in result['text']
        passed(task,seconds=round(time.monotonic()-start,2),usage=result['usage'],knowledgeSources=len(result.get('sourceDetails') or []))
    after=request('GET',f'/api/v1/widget/conversations/{cid}/messages',token=visitor)['items']
    # 接待队列异步追加 SYSTEM 通知属于正常流程，只比较真实会话消息。
    def substantive(messages):return {m['id'] for m in messages if m.get('messageType') not in ('SYSTEM','EVENT') and m.get('senderType')!='SYSTEM'}
    assert substantive(before)==substantive(after),'Assistant unexpectedly sent a substantive message'
    passed('assistant-remains-draft-no-visitor-message-sent')
    output=Path('/opt/tongyu-backups')/('ai-verification-'+stamp+'.json')
    output.write_text(json.dumps({'productionModel':env['AI_MODEL'],'verificationScope':'isolated database on production host, same deployed image and AI configuration','checks':report},ensure_ascii=False,indent=2))
    print('Report: '+str(output),flush=True)
finally:
    subprocess.run(['docker','rm','-f','-v',server,db],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['docker','network','rm',network],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    for file in [work/'server.env',work/'postgres.env']:
        if file.exists():file.unlink()
    if work.exists():work.rmdir()
    print('Temporary verification containers, database and credentials cleaned up',flush=True)
