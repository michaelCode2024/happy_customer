"""生成本机发布签名，私钥和口令仅存放在已忽略目录，重复运行保留原签名。"""
from pathlib import Path
import os, secrets, subprocess

root=Path(__file__).resolve().parents[1]
key=root/'.local-deploy/tongyu-release.jks'
properties=root/'apps/agent_console/android/key.properties'
if key.exists() and properties.exists():
    print('Release signing already configured')
elif key.exists() or properties.exists():
    raise SystemExit('Signing files incomplete; restore the existing pair before proceeding')
else:
    key.parent.mkdir(parents=True,exist_ok=True)
    password=secrets.token_urlsafe(32)
    env=dict(os.environ,TONGYU_SIGNING_PASSWORD=password)
    keytool=Path(os.environ.get('JAVA_HOME','D:/system/android/jbr'))/'bin/keytool.exe'
    subprocess.run([str(keytool),'-genkeypair','-keystore',str(key),'-alias','tongyu',
        '-keyalg','RSA','-keysize','3072','-validity','10000','-dname','CN=TongYu',
        '-storepass:env','TONGYU_SIGNING_PASSWORD','-keypass:env','TONGYU_SIGNING_PASSWORD'],
        env=env,check=True,capture_output=True)
    properties.write_text(f'storeFile={key.as_posix()}\nstorePassword={password}\nkeyAlias=tongyu\nkeyPassword={password}\n',encoding='utf-8')
    print('Release signing configured; keep both ignored signing files for future updates')
