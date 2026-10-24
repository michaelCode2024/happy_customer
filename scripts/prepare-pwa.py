"""为 Flutter 发布物生成完整离线清单与版本化 worker。"""
from pathlib import Path
import hashlib
import json
import re
import time

root = Path(__file__).resolve().parents[1]
import argparse

parser = argparse.ArgumentParser()
parser.add_argument(
    '--web-dir', type=Path, default=root / 'apps/agent_console/build/web'
)
args = parser.parse_args()
web = args.web_dir.resolve()
boot_path = web / 'flutter_bootstrap.js'
boot = boot_path.read_text(encoding='utf-8')
# Flutter 3.41+ 可能把 service worker 版本替换成 null；改用 main.dart.js 哈希作缓存键。
main_bytes = (web / 'main.dart.js').read_bytes()
release = str(int(hashlib.sha256(main_bytes).hexdigest()[:10], 16))
if re.search(r'const releaseVersion = "([0-9]+)";', boot):
    release = re.search(r'const releaseVersion = "([0-9]+)";', boot).group(1)
else:
    # 覆盖模板变量或已编译出的 null，保证 ?release= 能命中 Nginx 版本化静态文件。
    boot2, n = re.subn(
        r'var tongyuReleaseVersion = [^;]+;',
        f'var tongyuReleaseVersion = "{release}";',
        boot,
        count=1,
    )
    if n == 0:
        raise SystemExit('flutter_bootstrap.js 缺少 tongyuReleaseVersion 赋值')
    boot_path.write_text(boot2, encoding='utf-8')
    boot = boot2

release_info = json.loads((web / 'pwa-release.json').read_text(encoding='utf-8'))
assert isinstance(release_info.get('version'), str) and release_info['version'].strip(), '缺少发布版本号'
assert (
    isinstance(release_info.get('notes'), list)
    and release_info['notes']
    and all(isinstance(n, str) and n.strip() for n in release_info['notes'])
), '缺少更新说明'
files = [
    'pwa-release.json',
    'index.html',
    'flutter_bootstrap.js',
    'manifest.json',
    'favicon.svg',
    'pwa-client.js',
    'push-client.js',
]
# 仅保留 Flutter 入口与群通话页；禁止再把 desktop/mobile HTML 壳打进离线清单。
files += [
    name
    for name in ['mobile-call.html']
    if (web / name).is_file()
]
files += [
    p.relative_to(web).as_posix()
    for folder in ['assets', 'icons']
    for p in sorted((web / folder).rglob('*'))
    if p.is_file()
]
version = hashlib.sha256(
    b''.join((web / f).read_bytes() for f in files)
    + main_bytes
    + (root / 'apps/agent_console/web/tongyu-push-sw.js').read_bytes()
).hexdigest()[:16]
assets = ['/console/' + f for f in files] + [
    '/console/main.dart.js?release=' + release
]
(web / 'pwa-assets.json').write_text(
    json.dumps(
        {'version': version, 'assets': assets, 'release': release_info},
        ensure_ascii=False,
    ),
    encoding='utf-8',
)
worker = (
    root / 'apps/agent_console/web/tongyu-push-sw.js'
).read_text(encoding='utf-8').replace(
    "const SHELL_VERSION = 'development';",
    "const SHELL_VERSION = '" + version + "';",
)
(web / 'tongyu-push-sw.js').write_text(worker, encoding='utf-8')
# 给运维脚本用的纯数字发布戳（与 Nginx main.<release>.js 对齐）
(web / 'tongyu-release-stamp.txt').write_text(release + '\n', encoding='utf-8')
print('PWA shell:', version, 'release:', release, 'assets:', len(assets), 'at', time.strftime('%Y-%m-%d %H:%M:%S'))
