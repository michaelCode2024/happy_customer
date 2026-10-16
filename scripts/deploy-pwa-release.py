"""在已授权的通语服务器发布 PWA 和下载页，保留业务数据并支持失败回滚。"""
from pathlib import Path
import argparse, fcntl, gzip, hashlib, json, os, re, shutil, subprocess, time, urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('stage')
parser.add_argument('--expected-image', required=True)
args = parser.parse_args()
stage = Path(args.stage).resolve()
assert str(stage).startswith('/tmp/tongyu-pwa-') and (stage/'console/pwa-assets.json').is_file()
os.umask(0o077)
lock = open('/opt/tongyu-release.lock', 'w')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

def run(*cmd):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)

live = json.loads(run('docker', 'inspect', 'isolated-server-1'))[0]
assert live['Config']['Labels']['com.docker.compose.project'] == 'isolated'
assert live['Config']['Image'] == args.expected_image, 'Live release changed; check before publishing'
env = dict(x.split('=', 1) for x in live['Config']['Env'])
assert env['PUBLIC_BASE_URL'].rstrip('/') == 'https://chat.lookfunny.xyz'
manifest = json.loads((stage/'console/pwa-assets.json').read_text())
assert manifest['version'] in (stage/'console/tongyu-push-sw.js').read_text()
assert 'development' != manifest['version']
for url in manifest['assets']:
    path = url.split('?', 1)[0].removeprefix('/console/')
    file = (stage/'console'/path).resolve()
    assert file.is_relative_to(stage/'console') and file.is_file()
downloads = Path('/opt/tongyu-downloads')
assert downloads.is_dir()
compose = Path('/opt/tongyu-isolated/deploy/isolated/docker-compose.yml')
override = compose.parent/'client-release.override.json'
assert override.is_file()
stamp = time.strftime('%Y%m%d%H%M%S')
backup = Path('/opt/tongyu-backups')/('pwa-'+stamp)
backup.mkdir(parents=True, mode=0o700)
shutil.copy2(override, backup/'previous-override.json')
for name in ['index.html', 'downloads.css']:
    shutil.copy2(downloads/name, backup/name)
tag = 'tongyu-isolated:pwa-'+stamp
oldtag = 'tongyu-isolated:before-pwa-'+stamp
run('docker', 'tag', live['Image'], oldtag)
for name, image in [('rollback', oldtag), ('release', tag)]:
    (backup/(name+'.json')).write_text(json.dumps({'services': {'server': {'image': image, 'environment': {k:v.replace('$','$$') for k,v in env.items()}}}}))
for file in (stage/'console').rglob('*'):
    file.chmod(0o755 if file.is_dir() else 0o644)
(stage/'console').chmod(0o755)
(stage/'Dockerfile').write_text('FROM '+oldtag+'\nCOPY console/ /static/console/\nCOPY website/ /static/website/\n')
run('docker', 'build', '--pull=false', '-t', tag, str(stage))
boot = (stage/'console/flutter_bootstrap.js').read_text()
release = re.search(r'const releaseVersion = "([0-9]+)";', boot).group(1)
assets = Path('/opt/tongyu-console-assets')
main = (stage/'console/main.dart.js').read_bytes()
asset = assets/('main.'+release+'.js')
assert not asset.exists() or asset.read_bytes() == main, 'Immutable version collision'
asset.write_bytes(main); asset.chmod(0o644)
packed = Path(str(asset)+'.gz')
packed.write_bytes(gzip.compress(main, compresslevel=9, mtime=0)); packed.chmod(0o644)

def recreate(name):
    run('docker', 'compose', '-p', 'isolated', '-f', str(compose), '-f', str(backup/(name+'.json')),
        'up', '-d', '--no-deps', '--no-build', '--force-recreate', 'server')

def ready():
    for _ in range(40):
        try:
            with urllib.request.urlopen('http://127.0.0.1:18080/ready', timeout=3) as response:
                if json.load(response)['status'] == 'READY': return
        except Exception: pass
        time.sleep(1)
    raise RuntimeError('Readiness check failed')

def verify(url, file):
    with urllib.request.urlopen('https://chat.lookfunny.xyz'+url, timeout=20) as response:
        assert hashlib.sha256(response.read()).digest() == hashlib.sha256(file.read_bytes()).digest(), 'Published artifact mismatch: '+url

try:
    recreate('release'); ready()
    # 先核对完整离线清单，再让下载页推荐新能力。
    for url in manifest['assets']:
        verify(url, stage/'console'/url.split('?', 1)[0].removeprefix('/console/'))
    for name in ['pwa-assets.json', 'tongyu-push-sw.js']:
        verify('/console/'+name, stage/'console'/name)
    for source, name in [('downloads.html', 'index.html'), ('downloads.css', 'downloads.css')]:
        temporary = downloads/(name+'.new')
        shutil.copyfile(stage/'website'/source, temporary); temporary.chmod(0o644)
        temporary.replace(downloads/name)
    verify('/website/downloads.js', stage/'website/downloads.js')
    verify('/downloads/', stage/'website/downloads.html')
    verify('/website/downloads.css', stage/'website/downloads.css')
    now = json.loads(run('docker', 'inspect', 'isolated-server-1'))[0]
    assert now['Mounts'] == live['Mounts'], 'Persistent mounts changed'
    assert dict(x.split('=',1) for x in now['Config']['Env']) == env, 'Runtime environment changed'
    shutil.copy2(backup/'release.json', override)
    run('docker', 'tag', tag, 'tongyu-isolated:local')
    print(json.dumps({'status': 'READY', 'version': manifest['version'], 'image': tag, 'assetsVerified': len(manifest['assets'])}))
except Exception:
    for name in ['index.html', 'downloads.css']: shutil.copy2(backup/name, downloads/name)
    recreate('rollback'); ready()
    shutil.copy2(backup/'previous-override.json', override)
    raise
