"""在已核对的通语服务器执行：同步既有 AI 配置并持久化，不选择其他模型。"""
from pathlib import Path
import json,os,re,shutil,subprocess,sys,time,urllib.request

os.umask(0o077)
payload=Path(sys.argv[1]).resolve()
assert str(payload).startswith('/tmp/tongyu-ai-sync-') and payload.name=='config.json'
ai=json.loads(payload.read_text())
assert ai and all(re.fullmatch(r'AI_[A-Z0-9_]+',key) for key in ai)
assert ai.get('AI_PROVIDER')=='compatible' and all(ai.get(key) for key in ['AI_BASE_URL','AI_MODEL','AI_API_KEY'])
assert all('\n' not in value and '\r' not in value for value in ai.values())
def run(*args):return subprocess.check_output(args,text=True,stderr=subprocess.PIPE)
live=json.loads(run('docker','inspect','isolated-server-1'))[0]
env=dict(value.split('=',1) for value in live['Config']['Env'])
assert env.get('PUBLIC_BASE_URL','').rstrip('/')=='https://chat.lookfunny.xyz'
assert live['Config']['Labels']['com.docker.compose.project']=='isolated'
folder=Path('/opt/relaydesk-isolated/deploy/isolated')
compose=folder/'docker-compose.yml'
backup=Path('/opt/relaydesk-backups')/('ai-config-'+time.strftime('%Y%m%d%H%M%S'))
backup.mkdir(parents=True,mode=0o700)
files=[compose,folder/'.env',folder/'client-release.override.json',folder/'ai.runtime.override.json']
existed={str(file):file.exists() for file in files}
for file in files:
    if file.exists():shutil.copy2(file,backup/(file.name+'.before'))
def override(values):
    return {'services':{'server':{'image':live['Config']['Image'],'environment':{key:value.replace('$','$$') for key,value in values.items()}}}}
(backup/'runtime-before.json').write_text(json.dumps(override(env)))
updated=dict(env);updated.update(ai)
(backup/'runtime-after.json').write_text(json.dumps(override(updated)))
try:
    # .env 只覆盖本次 AI 项，其余现有环境约定保持原值。
    dotenv=folder/'.env'
    lines=dotenv.read_text().splitlines() if dotenv.exists() else []
    lines=[line for line in lines if not any(re.match(r'^\s*'+re.escape(key)+r'\s*=',line) for key in ai)]
    lines += [key+"='"+value.replace("'","\\'")+"'" for key,value in sorted(ai.items())]
    dotenv.write_text('\n'.join(lines)+'\n');dotenv.chmod(0o600)
    content=compose.read_text()
    marker=re.search(r'^(\s*)STORAGE_DRIVER:',content,re.M);assert marker,'Unexpected compose layout'
    indent=marker.group(1)
    missing=[key for key in sorted(ai) if not re.search(r'^\s*'+re.escape(key)+r':',content,re.M)]
    block=''.join(indent+key+': "${'+key+':-}"\n' for key in missing)
    content=content[:marker.start()]+block+content[marker.start():]
    compose.write_text(content)
    (folder/'ai.runtime.override.json').write_text(json.dumps({'services':{'server':{'environment':{key:value.replace('$','$$') for key,value in ai.items()}}}}))
    (folder/'ai.runtime.override.json').chmod(0o600)
    release=folder/'client-release.override.json'
    if release.exists():
        data=json.loads(release.read_text());data['services']['server'].setdefault('environment',{}).update({key:value.replace('$','$$') for key,value in ai.items()})
        release.write_text(json.dumps(data));release.chmod(0o600)
    run('docker','compose','-p','isolated','-f',str(compose),'-f',str(backup/'runtime-after.json'),'up','-d','--no-deps','--force-recreate','server')
    for attempt in range(35):
        try:
            with urllib.request.urlopen('http://127.0.0.1:18080/ready',timeout=3) as response:ready=json.load(response)
            assert ready['status']=='READY' and ready['ai']=='openai-compatible:'+ai['AI_MODEL']
            break
        except Exception:
            if attempt==34:raise
            time.sleep(1)
    current=json.loads(run('docker','inspect','isolated-server-1'))[0]
    actual=dict(value.split('=',1) for value in current['Config']['Env'])
    assert all(actual.get(key)==value for key,value in ai.items()),'Runtime AI configuration differs'
    assert all(actual.get(key)==value for key,value in env.items() if key not in ai),'Non-AI environment changed'
    # 验证常规 Compose 入口也能解析出相同 AI 配置，防止仅本次启动生效。
    normal=json.loads(run('docker','compose','-p','isolated','-f',str(compose),'config','--format','json'))
    planned=normal['services']['server']['environment']
    assert all(str(planned.get(key,''))==value for key,value in ai.items()),'Persistent compose config differs'
    print(json.dumps({'status':'READY','model':ai['AI_MODEL'],'provider':ai['AI_PROVIDER'],'runtimeMatchesLocal':True,'persistentConfigVerified':True,'backup':str(backup)}))
except Exception:
    for file in files:
        if existed[str(file)]:shutil.copy2(backup/(file.name+'.before'),file)
        elif file.exists():file.unlink()
    run('docker','compose','-p','isolated','-f',str(compose),'-f',str(backup/'runtime-before.json'),'up','-d','--no-deps','--force-recreate','server')
    raise
