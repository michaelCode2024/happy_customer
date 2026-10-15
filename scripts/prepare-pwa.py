"""为 Flutter 发布物生成完整离线清单与版本化 worker。"""
from pathlib import Path
import hashlib,json,re
root=Path(__file__).resolve().parents[1]
import argparse
parser=argparse.ArgumentParser();parser.add_argument('--web-dir',type=Path,default=root/'apps/agent_console/build/web');args=parser.parse_args()
web=args.web_dir.resolve()
boot=(web/'flutter_bootstrap.js').read_text(encoding='utf-8')
release=re.search(r'const releaseVersion = "([0-9]+)";',boot).group(1)
# 同时覆盖页面、运行时代码、字体和资源清单；不包含源码映射或构建工具目录。
release_info=json.loads((web/'pwa-release.json').read_text(encoding='utf-8'))
assert isinstance(release_info.get('version'),str) and release_info['version'].strip(), '缺少发布版本号'
assert isinstance(release_info.get('notes'),list) and release_info['notes'] and all(isinstance(n,str) and n.strip() for n in release_info['notes']), '缺少更新说明'
files=['pwa-release.json','index.html','flutter_bootstrap.js','manifest.json','favicon.svg','pwa-client.js','push-client.js']
files += [name for name in ['mobile.html','mobile-call.html','desktop.html'] if (web/name).is_file()]
# Call UI is versioned and verified, but the worker never uses it as an offline navigation shell.
files += [p.relative_to(web).as_posix() for folder in ['assets','icons','mobile','desktop'] for p in sorted((web/folder).rglob('*')) if p.is_file()]
version=hashlib.sha256(b''.join((web/f).read_bytes() for f in files)+(web/'main.dart.js').read_bytes()+(root/'apps/agent_console/web/tongyu-push-sw.js').read_bytes()).hexdigest()[:16]
assets=['/console/'+f for f in files]+['/console/main.dart.js?release='+release]
(web/'pwa-assets.json').write_text(json.dumps({'version':version,'assets':assets,'release':release_info},ensure_ascii=False),encoding='utf-8')
worker=(root/'apps/agent_console/web/tongyu-push-sw.js').read_text(encoding='utf-8').replace("const SHELL_VERSION = 'development';", "const SHELL_VERSION = '"+version+"';")
(web/'tongyu-push-sw.js').write_text(worker,encoding='utf-8')
print('PWA shell:',version,'assets:',len(assets))
