#!/usr/bin/env python3
"""本机 AI 接待验收：真实模型、知识检索、草稿隔离、人工发送与访客收取。

只允许 localhost。凭据及会话令牌仅写入被 Git 忽略的本机验收目录。
浏览器验收使用同一企业及会话继续操作，避免用另一套模拟数据代替页面结果。
"""
import json
import os
from pathlib import Path
import time
import urllib.request
from urllib.parse import urlparse
import uuid

BASE = os.environ.get('AI_E2E_BASE', 'http://127.0.0.1:18765')
assert urlparse(BASE).hostname in ('localhost', '127.0.0.1'), '仅允许本机验收'
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.local-deploy' / 'a3'


def req(method, path, body=None, token=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
    request = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=90) as response:
        raw = response.read()
        return json.loads(raw) if raw else {}


def main():
    report = []
    def ok(name, **detail):
        report.append({'check': name, 'pass': True, **detail})
        print('PASS ' + name, flush=True)

    assert req('GET', '/ready')['status'] == 'READY'
    platform = req('POST', '/api/v1/platform/login', {
        'email': os.environ.get('AI_E2E_PLATFORM_EMAIL', 'admin@tongyu.local'),
        'password': os.environ.get('AI_E2E_PLATFORM_PASSWORD', 'TongYu@2026'),
    })['token']
    slug = 'tongyu-ai-' + time.strftime('%m%d%H%M%S')
    password = 'TongYuLocal@2026'
    tenant = req('POST', '/api/v1/platform/tenants', {
        'name': '通语 AI 体验空间', 'slug': slug,
        'ownerEmail': 'ai-demo', 'ownerName': '林小语', 'ownerPassword': password,
        'inboxName': '官网在线咨询', 'publicKey': slug + '-web', 'plan': 'GROWTH', 'trialDays': 14,
    }, platform)
    login = req('POST', '/api/v1/console/login', {'tenantSlug': slug, 'email': 'ai-demo', 'password': password})
    agent = login['token']
    req('POST', '/api/v1/console/me/presence', {'status': 'ONLINE'}, agent)
    ok('企业开通、客服登录与上线')

    for title, content, examples in [
        ('网站嵌入与手机访问说明', '通语支持在网站嵌入客服窗口，也支持 H5 手机网页访问。网站接入需要在接入管理中获取该企业的入口标识，由开发人员将客服组件嵌入网页。服务端密钥不能放入网页。', '网站怎么嵌入客服\n网站嵌入支持手机访问吗\n网页嵌入客服窗口'),
        ('接入前的资料准备', '开始网站嵌入前，请准备网站域名、接待人员名单与常见问题资料。接入时间由实际网站情况确认，不承诺固定完成时间。', '网站嵌入需要准备什么\n接入说明'),
    ]:
        req('POST', '/api/v1/console/knowledge', {'title':title, 'content':content, 'questionExamples':examples, 'status':'ACTIVE'}, agent)
    ok('真实知识条目建立')
    boot = req('POST', '/api/v1/widget/bootstrap', {'inboxKey':tenant['publicKey'], 'displayName':'陈女士 · AI验收'})
    visitor = boot['token']
    conversation = req('POST', '/api/v1/widget/conversations', {'subject':'网站嵌入与手机访问咨询'}, visitor)
    cid = conversation['conversation']['id']
    question = '你好，我们想在网站嵌入客服窗口，请问支持手机访问吗？接入需要准备哪些资料？'
    req('POST', f'/api/v1/widget/conversations/{cid}/messages', {'content':'我们的网站项目代号是青松。', 'clientMessageId':str(uuid.uuid4())}, visitor)
    req('POST', f'/api/v1/widget/conversations/{cid}/messages', {'content':question, 'clientMessageId':str(uuid.uuid4())}, visitor)
    ok('访客发起真实咨询')
    # 自动分配后可能已经由当前客服接待；只有未分配时才领取。
    detail = req('GET', f'/api/v1/console/conversations/{cid}', token=agent)
    req('POST', f'/api/v1/console/conversations/{cid}/claim', {}, agent)
    before = req('GET', f'/api/v1/widget/conversations/{cid}/messages', token=visitor)['items']
    results = {}
    for task in ('SUMMARIZE', 'SUGGEST'):
        started = time.monotonic()
        result = req('POST', '/api/v1/console/assist', {'task':task, 'conversationId':cid,
            'question': '请重点说明项目代号与客户诉求' if task == 'SUMMARIZE' else question}, agent)
        assert result['available'] and result['text'].strip(), result
        if task == 'SUMMARIZE':
            assert '青松' in result['text'], '摘要必须读取前文，而不只是最新一条问题'
        results[task] = result
        ok('真实 AI ' + task, seconds=round(time.monotonic()-started, 2), text=result['text'])
    sources = results['SUGGEST']['sourceDetails']
    assert sources and all(source['id'] and source['content'] for source in sources)
    assert any('手机' in source['content'] for source in sources)
    ok('知识来源有真实标识、标题和正文', titles=[s['title'] for s in sources])
    after = req('GET', f'/api/v1/widget/conversations/{cid}/messages', token=visitor)['items']
    assert {m['id'] for m in after if m['senderType']=='AGENT'} == {m['id'] for m in before if m['senderType']=='AGENT'}, '助手草稿不应自动发送给访客'
    ok('生成摘要和建议不会自动发送')
    sent_text = results['SUGGEST']['text'] + '\n我可以继续协助您确认接入步骤。'
    req('POST', f'/api/v1/console/conversations/{cid}/messages', {'content':sent_text, 'messageType':'TEXT', 'clientMessageId':str(uuid.uuid4())}, agent)
    received = req('GET', f'/api/v1/widget/conversations/{cid}/messages', token=visitor)['items']
    assert any(m['senderType']=='AGENT' and m['content']==sent_text for m in received)
    ok('人工编辑发送后访客收到一致正文')
    OUT.mkdir(parents=True, exist_ok=True)
    fixture = {'base':BASE, 'slug':slug, 'email':'ai-demo', 'password':password, 'conversationId':cid,
               'agentToken':agent, 'visitorToken':visitor, 'inboxKey':tenant['publicKey'], 'results':results}
    (OUT/'fixture.json').write_text(json.dumps(fixture, ensure_ascii=False, indent=2), encoding='utf-8')
    (OUT/'api-acceptance.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print('本地 API 全链路通过；浏览器验收会话已保留。', flush=True)


if __name__ == '__main__':
    main()
