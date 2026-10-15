"""本机 AI 知识补充和草稿反馈验收。凭据只保存在被忽略的验收目录。"""
import json, os, time, uuid, urllib.request, urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.local-deploy/ai-productivity'
BASE = 'http://127.0.0.1:18776'

def req(method, path, body=None, token=None, expected=200):
    headers = {'Content-Type':'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(BASE+path, method=method, headers=headers,
        data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            assert response.status == expected, (path,response.status)
            return json.load(response)
    except urllib.error.HTTPError as error:
        assert error.code == expected, (path,error.code,error.read().decode()[:200])
        return {}

def seed():
    env = dict(line.split('=',1) for line in (OUT/'runtime.env').read_text().splitlines() if '=' in line)
    platform = req('POST','/api/v1/platform/login', {'email':env['PLATFORM_ADMIN_EMAIL'],'password':env['PLATFORM_ADMIN_PASSWORD']})['token']
    password = os.environ['AI_LOOP_TEST_PASSWORD']
    slug = 'ai-loop-' + time.strftime('%m%d%H%M%S')
    created = req('POST','/api/v1/platform/tenants', {'name':'AI 提效验收空间','slug':slug,
        'ownerEmail':'owner','ownerName':'验收主管','ownerPassword':password,'inboxName':'网站咨询',
        'publicKey':slug+'-web','plan':'GROWTH','trialDays':14}, platform,201)
    login = req('POST','/api/v1/console/login',{'tenantSlug':slug,'email':'owner','password':password})
    agent = login['token']
    req('POST','/api/v1/console/me/presence',{'status':'ONLINE'},agent)
    inbox = req('GET','/api/v1/admin/inboxes',token=agent)['items'][0]['id']
    req('PATCH',f'/api/v1/admin/inboxes/{inbox}/ai',{'enabled':True},agent)
    visitor = req('POST','/api/v1/widget/bootstrap',{'inboxKey':slug+'-web','displayName':'陈女士 · 知识闭环验收'})['token']
    cid = req('POST','/api/v1/widget/conversations',{'subject':'网站接入资料咨询'},visitor,201)['conversation']['id']
    question = '网站嵌入客服窗口，接入需要准备哪些资料？'
    req('POST',f'/api/v1/widget/conversations/{cid}/messages',{'content':question,'clientMessageId':str(uuid.uuid4())},visitor,201)
    fixture={'base':BASE,'slug':slug,'email':'owner','password':password,'agentToken':agent,'visitorToken':visitor,'conversationId':cid,'question':question}
    (OUT/'fixture.json').write_text(json.dumps(fixture,ensure_ascii=False,indent=2),encoding='utf-8')
    for _ in range(30):
        gaps = req('GET','/api/v1/admin/knowledge-gaps',token=agent)['items']
        if any(g['question']==question for g in gaps): break
        time.sleep(1)
    else: raise AssertionError('真实访客问题未形成知识缺口')
    fixture={'base':BASE,'slug':slug,'email':'owner','password':password,'agentToken':agent,'visitorToken':visitor,'conversationId':cid,'question':question}
    (OUT/'fixture.json').write_text(json.dumps(fixture,ensure_ascii=False,indent=2),encoding='utf-8')
    print('PASS 真实访客问题形成知识缺口；浏览器验收企业：'+slug)

def check():
    f=json.loads((OUT/'fixture.json').read_text(encoding='utf-8'));agent=f['agentToken'];cid=f['conversationId']
    open_gaps=req('GET','/api/v1/admin/knowledge-gaps',token=agent)['items']
    resolved=req('GET','/api/v1/admin/knowledge-gaps?status=RESOLVED',token=agent)['items']
    assert not any(g['question']==f['question'] for g in open_gaps)
    assert any(g['question']==f['question'] and g['knowledgeId'] for g in resolved)
    summary=req('GET','/api/v1/console/assist/feedback-summary',token=agent)
    assert summary['adopted']>=1 and summary['sent']>=1 and summary['edited']>=1 and summary['helpful']>=1,summary
    messages=req('GET',f'/api/v1/widget/conversations/{cid}/messages',token=f['visitorToken'])['items']
    assert any(m['senderType']=='AGENT' and '我可以继续协助您确认接入步骤' in m['content'] for m in messages)
    sent=next(m for m in messages if m.get('metadata',{}).get('assistInteractionId'))
    interaction=sent['metadata']['assistInteractionId']
    # 重复采纳不会重复计数；更正评价不会新增一条反馈。
    req('POST',f'/api/v1/console/assist/{interaction}/feedback',{'action':'ADOPT'},agent)
    assert req('GET','/api/v1/console/assist/feedback-summary',token=agent)['adopted']==summary['adopted']
    req('POST',f'/api/v1/console/assist/{interaction}/feedback',{'action':'INVALID'},agent,400)
    before_ids={m['id'] for m in messages}
    req('POST',f'/api/v1/console/conversations/{cid}/messages',{'content':'不得再次使用已发送草稿','clientMessageId':str(uuid.uuid4()),'metadata':{'assistInteractionId':interaction}},agent,403)
    assert {m['id'] for m in req('GET',f'/api/v1/widget/conversations/{cid}/messages',token=f['visitorToken'])['items']}==before_ids
    # 真实停用知识应让缺口重新出现，恢复知识后回到已补充列表。
    knowledge=next(g['knowledgeId'] for g in resolved if g['question']==f['question'])
    req('PATCH',f'/api/v1/console/knowledge/{knowledge}',{'status':'DISABLED'},agent)
    assert any(g['question']==f['question'] for g in req('GET','/api/v1/admin/knowledge-gaps',token=agent)['items'])
    req('PATCH',f'/api/v1/console/knowledge/{knowledge}',{'status':'ACTIVE'},agent)
    # 跨企业不能评价另一企业的草稿，也不能把别人的问题标成已补充。
    env=dict(line.split('=',1) for line in (OUT/'runtime.env').read_text().splitlines() if '=' in line)
    platform=req('POST','/api/v1/platform/login',{'email':env['PLATFORM_ADMIN_EMAIL'],'password':env['PLATFORM_ADMIN_PASSWORD']})['token']
    other_slug=f['slug']+'-isolation'
    req('POST','/api/v1/platform/tenants',{'name':'隔离验收','slug':other_slug,'ownerEmail':'owner','ownerName':'另一企业','ownerPassword':f['password'],'inboxName':'隔离入口','publicKey':other_slug,'plan':'GROWTH'},platform,201)
    other=req('POST','/api/v1/console/login',{'tenantSlug':other_slug,'email':'owner','password':f['password']})['token']
    req('POST',f'/api/v1/console/assist/{interaction}/feedback',{'action':'HELPFUL'},other,404)
    req('POST','/api/v1/console/knowledge',{'title':'不应保存','content':'越界知识','sourceQuestion':f['question']},other,400)
    assert req('GET','/api/v1/console/knowledge',token=other)['items']==[]
    (OUT/'browser-api-verification.json').write_text(json.dumps({'knowledgeGapResolved':True,'summary':summary,'visitorReceived':True},ensure_ascii=False,indent=2),encoding='utf-8')
    print('PASS 浏览器补充知识后已关联原问题；采纳、修改发送、有用反馈已持久化；访客收到正文')
    print(json.dumps(summary,ensure_ascii=False))
    print('PASS 重复采纳不重复计数；重复发送回滚；知识停用重新打开缺口；跨企业反馈与知识关联被拒绝')

if __name__=='__main__':
    if os.environ.get('AI_LOOP_CHECK')=='1': check()
    else: seed()
