"""在已核对的通语服务器执行：备份、替换客服服务、发布独立下载目录、健康检查；失败回滚。

由 SSH 以 sudo python3 执行，stage 参数只能是本次上传目录。不输出运行时凭据。
"""
import argparse,gzip,hashlib,json,os,re,shutil,subprocess,time,urllib.request
from pathlib import Path

parser=argparse.ArgumentParser();parser.add_argument('stage');args=parser.parse_args()
stage=Path(args.stage).resolve()
assert str(stage).startswith('/tmp/tongyu-client-release-') and (stage/'server').is_file()
stamp=time.strftime('%Y%m%d%H%M%S')
app=Path('/opt/relaydesk-isolated')
compose=app/'deploy/isolated/docker-compose.yml'
nginx=Path('/www/server/panel/vhost/nginx/chat.lookfunny.xyz.conf')
downloads=Path('/opt/relaydesk-downloads')
backup=Path('/opt/relaydesk-backups')/('client-notifications-'+stamp)
backup.mkdir(mode=0o700,parents=True)
os.umask(0o077)
def run(*cmd):return subprocess.check_output(cmd,text=True,stderr=subprocess.STDOUT)
live=json.loads(run('docker','inspect','isolated-server-1'))[0]
assert live['Config']['Labels']['com.docker.compose.project']=='isolated'
assert live['Config']['Labels']['com.docker.compose.service']=='server'
env=dict(value.split('=',1) for value in live['Config']['Env'])
assert env.get('PUBLIC_BASE_URL','').rstrip('/')=='https://chat.lookfunny.xyz','Live public origin mismatch'
assert (app/'internal').is_dir() and nginx.is_file()
tag='relaydesk-isolated:client-notifications-'+stamp
oldtag='relaydesk-isolated:before-client-notifications-'+stamp
run('docker','tag',live['Image'],oldtag)
shutil.copy2(nginx,backup/'nginx.conf')
(backup/'image-tag').write_text(oldtag)
with (backup/'database.sql').open('wb') as output:
    subprocess.run(['docker','exec','isolated-postgres-1','pg_dump','-U','relaydesk','-d','relaydesk'],stdout=output,check=True)
for name,image in [('rollback',oldtag),('release',tag)]:
    (backup/(name+'.json')).write_text(json.dumps({'services':{'server':{'image':image,'environment':env}}}))
    (backup/(name+'.json')).chmod(0o600)
for folder in [stage/'console',stage/'website']:
    folder.chmod(0o755)
    for item in folder.rglob('*'):item.chmod(0o755 if item.is_dir() else 0o644)
(stage/'Dockerfile').write_text('FROM '+oldtag+'\nCOPY --chmod=0755 server /relaydesk\nCOPY console/ /static/console/\nCOPY website/ /static/website/\n')
run('docker','build','--pull=false','-t',tag,'-f',str(stage/'Dockerfile'),str(stage))
def recreate(name):
    run('docker','compose','-p','isolated','-f',str(compose),'-f',str(backup/(name+'.json')),'up','-d','--no-deps','--force-recreate','server')
def ready():
    for _ in range(40):
        try:
            with urllib.request.urlopen('http://127.0.0.1:18080/ready',timeout=3) as response:
                if json.load(response).get('status')=='READY':return
        except Exception:pass
        time.sleep(1)
    raise RuntimeError('Readiness check failed')
changed=False
try:
    changed=True;recreate('release');ready()
    # 版本化 JS 保持现有缓存策略，新发布版本使用独立文件名。
    boot=(stage/'console/flutter_bootstrap.js').read_text()
    match=re.search(r'const releaseVersion = "?([0-9]+)"?;',boot)
    assert match,'Missing Flutter release version'
    assetdir=Path('/opt/relaydesk-console-assets');assetdir.mkdir(mode=0o755,exist_ok=True)
    main=(stage/'console/main.dart.js').read_bytes()
    asset=assetdir/('main.'+match.group(1)+'.js')
    if asset.exists():assert asset.read_bytes()==main,'Immutable script version collision'
    asset.write_bytes(main);asset.chmod(0o644)
    packed=Path(str(asset)+'.gz');packed.write_bytes(gzip.compress(main,compresslevel=9,mtime=0));packed.chmod(0o644)
    downloads.mkdir(mode=0o755,exist_ok=True)
    downloads.chmod(0o755)
    for file in (stage/'downloads').iterdir():
        assert file.is_file() and file.suffix in ('.apk','.json','.html','.mobileconfig')
        destination=downloads/file.name
        if destination.exists() and file.suffix=='.apk':assert destination.read_bytes()==file.read_bytes(),'APK version collision'
        temporary=downloads/(file.name+'.new');shutil.copyfile(file,temporary);temporary.chmod(0o644);temporary.replace(destination)
    # 下载页独立发布时也必须带上专属样式，避免 HTML 更新后仍显示旧布局。
    shutil.copyfile(stage/'website/downloads.css',downloads/'downloads.css')
    (downloads/'downloads.css').chmod(0o644)
    config=nginx.read_text()
    if 'alias /opt/relaydesk-downloads/;' not in config:
        needle=' location / {\n  proxy_pass http://127.0.0.1:18080;'
        assert config.count(needle)==1,'Unexpected nginx configuration'
        block=''' location = /downloads { return 301 /downloads/; }
 location ^~ /downloads/ {
  alias /opt/relaydesk-downloads/;
  index index.html;
  autoindex off;
  types { text/html html; application/json json; application/vnd.android.package-archive apk; application/x-apple-aspen-config mobileconfig; }
  add_header Cache-Control "no-cache";
 }
'''
        nginx.write_text(config.replace(needle,block+needle))
    # 独立下载目录由 Nginx 直接提供，需同步修复已有站点的下载响应。
    config=nginx.read_text()
    if 'location = /downloads/tongyu-ios.mobileconfig' not in config:
        needle=' location ^~ /downloads/ {'
        assert config.count(needle)==1,'Unexpected downloads location'
        block=''' location = /downloads/tongyu-ios.mobileconfig {
  alias /opt/relaydesk-downloads/tongyu-ios.mobileconfig;
  default_type application/x-apple-aspen-config;
  add_header Content-Disposition 'attachment; filename="tongyu-ios.mobileconfig"';
  add_header Cache-Control "no-cache";
 }
'''
        nginx.write_text(config.replace(needle,block+needle))
    config=nginx.read_text()
    if 'location = /website/downloads.css' not in config:
        needle=' location ^~ /downloads/ {'
        assert config.count(needle)==1,'Unexpected downloads location'
        block=' location = /website/downloads.css {\n  alias /opt/relaydesk-downloads/downloads.css;\n  default_type text/css;\n  add_header Cache-Control "no-cache";\n }\n'
        nginx.write_text(config.replace(needle,block+needle))
    run('/www/server/nginx/sbin/nginx','-t')
    run('/www/server/nginx/sbin/nginx','-s','reload')
    release=None
    # reload 平滑切换 worker，需要等新配置接管连接后再判定公开入口。
    for attempt in range(15):
        try:
            with urllib.request.urlopen('https://chat.lookfunny.xyz/downloads/release.json',timeout=5) as response:release=json.load(response)
            break
        except Exception:
            if attempt==14:raise
            time.sleep(1)
    assert release is not None
    for path in ['/','/console/','/console/push-client.js','/console/tongyu-push-sw.js','/website/downloads.js']:
        with urllib.request.urlopen('https://chat.lookfunny.xyz'+path,timeout=10) as response:
            assert response.status==200 and response.read(16),'Static asset unavailable: '+path
    published=downloads/Path(release['android']['url']).name
    assert hashlib.sha256(published.read_bytes()).hexdigest()==release['android']['sha256']
    # 核对容器读到的二进制、部署清单，避免重启后恢复旧镜像。
    expected=hashlib.sha256((stage/'server').read_bytes()).hexdigest()
    run('docker','cp','isolated-server-1:/relaydesk',str(backup/'deployed-server'))
    assert hashlib.sha256((backup/'deployed-server').read_bytes()).hexdigest()==expected
    (backup/'release-info.json').write_text(json.dumps({'image':tag,'serverSha256':expected,'apkSha256':release['android']['sha256'],'downloadDir':str(downloads)}))
    shutil.copyfile(backup/'release.json',compose.parent/'client-release.override.json')
    (compose.parent/'client-release.override.json').chmod(0o600)
    run('docker','tag',tag,'relaydesk-isolated:local')
    print(json.dumps({'status':'READY','image':tag,'backup':str(backup),'downloads':str(downloads),'apkSha256':release['android']['sha256']}))
except Exception:
    shutil.copy2(backup/'nginx.conf',nginx)
    subprocess.run(['/www/server/nginx/sbin/nginx','-t'],capture_output=True)
    subprocess.run(['/www/server/nginx/sbin/nginx','-s','reload'],capture_output=True)
    if changed:recreate('rollback');ready()
    raise
