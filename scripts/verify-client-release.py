"""只读验证通语公开发布物，不写入客户业务数据。"""
from pathlib import Path
import hashlib,json,plistlib,re,urllib.request,urllib.error
root=Path(__file__).resolve().parents[1]
base='https://chat.lookfunny.xyz'
report=[]
def fetch(path,method='GET',headers=None):
    request=urllib.request.Request(base+path,method=method,headers=headers or {})
    with urllib.request.urlopen(request,timeout=60) as response:return response.status,dict(response.headers),response.read()
def passed(check,**details):
    report.append({'check':check,**details});print('PASS',check,flush=True)
for path in ['/health','/ready']:
    status,headers,data=fetch(path);assert status==200
    passed(path,status=status,state=json.loads(data)['status'])
status,headers,data=fetch('/downloads/release.json');release=json.loads(data)
local=json.loads((root/'.local-deploy/client-downloads/release.json').read_text(encoding='utf-8'))
assert release==local
apk=root/'.local-deploy/client-downloads'/Path(release['android']['url']).name
status,headers,_=fetch(release['android']['url'],method='HEAD')
assert status==200 and int(headers['Content-Length'])==apk.stat().st_size
assert 'android.package-archive' in headers['Content-Type']
status,headers,data=fetch(release['android']['url'],headers={'Range':'bytes=0-16383'})
assert status==206 and data==apk.read_bytes()[:16384]
passed('public-signed-apk',status=200,rangeStatus=206,size=apk.stat().st_size,sha256=release['android']['sha256'])
status,headers,data=fetch(release['ios']['url']);assert 'apple-aspen-config' in headers['Content-Type']
assert 'attachment' in headers.get('Content-Disposition','')
profile=plistlib.loads(data)
assert len(profile['PayloadContent'])==1 and profile['PayloadContent'][0]['URL']==base+'/console/?surface=agent'
passed('public-apple-webclip',status=status,removable=profile['PayloadContent'][0]['IsRemovable'])
for path,needle in [('/','客户端下载'),('/downloads/','下载苹果桌面书签包'),('/console/','push-client.js'),('/console/push-client.js','tongyuEnablePush'),('/console/tongyu-push-sw.js','notificationclick')]:
    status,headers,data=fetch(path);assert needle.encode() in data
    passed(path,status=status)
boot=(root/'apps/agent_console/build/web/flutter_bootstrap.js').read_text(encoding='utf-8')
version=re.search(r'const releaseVersion = "?([0-9]+)"?;',boot).group(1)
status,headers,data=fetch('/console/main.dart.js?release='+version)
assert hashlib.sha256(data).digest()==hashlib.sha256((root/'apps/agent_console/build/web/main.dart.js').read_bytes()).digest()
passed('published-console-matches-local-build',status=status,sha256=hashlib.sha256(data).hexdigest())
for path in ['/api/v1/console/notifications','/api/v1/console/push/key']:
    try:fetch(path);raise AssertionError('Authentication missing')
    except urllib.error.HTTPError as error:assert error.code==401
    passed(path,unauthenticatedStatus=401)
output=root/'.local-deploy/notification-proof/production-verification.json'
output.parent.mkdir(parents=True,exist_ok=True)
output.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
