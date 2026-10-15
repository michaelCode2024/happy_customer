"""仅本机：验证真实访客消息、收件人隔离、已读持久化与推送订阅权限。"""
import base64,json,time,uuid,urllib.request,urllib.error
from pathlib import Path
BASE='http://127.0.0.1:18774'
def req(method,path,body=None,token=None,expected=200):
    headers={'Content-Type':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    request=urllib.request.Request(BASE+path,method=method,headers=headers,data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(request,timeout=25) as response:
            assert response.status==expected,(path,response.status)
            return json.load(response)
    except urllib.error.HTTPError as e:
        assert e.code==expected,(path,e.code,e.read().decode()[:200])
        return {}
def main():
    platform=req('POST','/api/v1/platform/login',{'email':'notifications-local','password':'LocalNotify2026!'})['token']
    stamp=str(int(time.time()))
    accounts=[]
    for index in range(2):
        slug='notice-'+stamp+'-'+str(index)
        created=req('POST','/api/v1/platform/tenants',{'name':'消息验收'+str(index),'slug':slug,'ownerEmail':'owner','ownerName':'验收客服','ownerPassword':'NotifyLocal@2026','inboxName':'网站咨询','publicKey':slug+'-web','plan':'GROWTH','trialDays':14},platform,201)
        login=req('POST','/api/v1/console/login',{'tenantSlug':slug,'email':'owner','password':'NotifyLocal@2026'})
        accounts.append((slug,login,created))
    slug,login,created=accounts[0];agent=login['token'];other=accounts[1][1]['token']
    req('POST','/api/v1/console/me/presence',{'status':'ONLINE'},agent)
    visitor=req('POST','/api/v1/widget/bootstrap',{'inboxKey':slug+'-web','displayName':'张先生'})['token']
    cid=req('POST','/api/v1/widget/conversations',{'subject':'通知验收'},visitor,201)['conversation']['id']
    sent=req('POST',f'/api/v1/widget/conversations/{cid}/messages',{'content':'测试发送者语音播报','messageType':'TEXT','clientMessageId':str(uuid.uuid4())},visitor,201)
    notices=req('GET','/api/v1/console/notifications',token=agent)
    match=[n for n in notices['items'] if n['kind']=='MESSAGE' and n['conversationId']==cid]
    assert len(match)==1 and '张先生' in match[0]['title']
    assert req('GET','/api/v1/console/notifications',token=other)['unread']==0
    print('PASS 真实访客消息产生通知，包含发送者，跨企业隔离')
    req('POST','/api/v1/console/notifications/read',{'id':match[0]['id']},other)
    assert any(n['id']==match[0]['id'] and n['readAt'] is None for n in req('GET','/api/v1/console/notifications',token=agent)['items'])
    req('POST','/api/v1/console/notifications/read',{'all':True},agent)
    assert req('GET','/api/v1/console/notifications',token=agent)['unread']==0
    print('PASS 他人不能标记通知，全部已读重新请求仍生效')
    req('POST','/api/v1/console/notifications/quiet',{'minutes':60},agent)
    assert req('GET','/api/v1/console/notifications',token=agent)['quietUntil'] is not None
    assert req('GET','/api/v1/console/notifications',token=other)['quietUntil'] is None
    req('POST','/api/v1/console/notifications/quiet',{'minutes':0},agent)
    print('PASS 免打扰保存与恢复，按企业和客服隔离')
    read_message=req('POST',f'/api/v1/widget/conversations/{cid}/messages',{'content':'阅读回执联动测试','messageType':'TEXT','clientMessageId':str(uuid.uuid4())},visitor,201)
    req('POST',f'/api/v1/console/conversations/{cid}/read',{'sequence':read_message['sequence']},agent)
    assert req('GET','/api/v1/console/notifications',token=agent)['unread']==0
    print('PASS 阅读会话同步清除对应站内通知')
    key=req('GET','/api/v1/console/push/key',token=agent)['publicKey']
    assert len(base64.urlsafe_b64decode(key+'='*((-len(key))%4)))==65
    req('PUT','/api/v1/console/push/subscription',{'endpoint':'http://127.0.0.1/private','keys':{'p256dh':'x','auth':'x'}},agent,400)
    req('GET','/api/v1/console/notifications',expected=401)
    print('PASS VAPID 公钥，推送端点校验，未登录拒绝访问')
    # 留下第二条真实未读消息，用于浏览器验收；令牌仅写本机已忽略目录。
    req('POST',f'/api/v1/widget/conversations/{cid}/messages',{'content':'浏览器验收消息','messageType':'TEXT','clientMessageId':str(uuid.uuid4())},visitor,201)
    output=Path(__file__).resolve().parents[1]/'.local-deploy/notifications-fixture.json'
    output.write_text(json.dumps({'base':BASE,'slug':slug,'email':'owner','password':'NotifyLocal@2026','conversationId':cid,'token':agent,'visitor':visitor}),encoding='utf-8')
    print('PASS 浏览器验收数据已保留于本机')
if __name__=='__main__':main()
