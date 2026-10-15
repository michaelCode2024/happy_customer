"""为已签名 APK 生成独立下载目录、版本清单和仅含桌面书签的苹果配置包。"""
from pathlib import Path
import argparse,hashlib,json,plistlib,shutil,uuid
from datetime import datetime

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--origin',default='https://chat.lookfunny.xyz')
args=parser.parse_args()
origin=args.origin.rstrip('/')
assert origin.startswith('https://')
out=root/'.local-deploy/client-downloads'
out.mkdir(parents=True,exist_ok=True)
apk=root/'apps/agent_console/build/app/outputs/flutter-apk/app-release.apk'
if not apk.exists():raise SystemExit('Build the signed release APK first')
stamp=datetime.now().strftime('%Y%m%d%H%M')
name='tongyu-android-'+stamp+'.apk'
shutil.copy2(apk,out/name)
shutil.copy2(root/'apps/website/downloads.html',out/'index.html')
identifier='xyz.lookfunny.chat.webclip'
profile={'PayloadType':'Configuration','PayloadVersion':1,'PayloadIdentifier':identifier,
 'PayloadUUID':str(uuid.uuid5(uuid.NAMESPACE_DNS,identifier)), 'PayloadDisplayName':'通语客服桌面书签',
 'PayloadDescription':'在主屏幕添加通语客服入口，可在系统设置中移除。',
 'PayloadRemovalDisallowed':False,'PayloadContent':[{'PayloadType':'com.apple.webClip.managed',
 'PayloadVersion':1,'PayloadIdentifier':identifier+'.shortcut','PayloadUUID':str(uuid.uuid5(uuid.NAMESPACE_DNS,identifier+'.shortcut')),
 'PayloadDisplayName':'通语客服','Label':'通语客服','URL':origin+'/console/?surface=agent',
 'FullScreen':True,'IsRemovable':True,'Icon':(root/'apps/agent_console/web/icons/Icon-192.png').read_bytes()}]}
(out/'tongyu-ios.mobileconfig').write_bytes(plistlib.dumps(profile))
release={'android':{'url':'/downloads/'+name,'version':'0.1.0','updatedAt':datetime.now().strftime('%Y-%m-%d'),'sha256':hashlib.sha256(apk.read_bytes()).hexdigest()},
 'ios':{'url':'/downloads/tongyu-ios.mobileconfig','webAppUrl':origin+'/console/?surface=agent'}}
(out/'release.json').write_text(json.dumps(release,ensure_ascii=False,indent=2),encoding='utf-8')
print('Client download directory ready:',out)
print('APK SHA256:',release['android']['sha256'])
