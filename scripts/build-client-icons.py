"""从官网 SVG 导出统一客户端图标（依赖 resvg-py）。"""
from pathlib import Path
import re,resvg_py
root=Path(__file__).resolve().parents[1]
source=(root/'apps/website/logo.svg').read_text(encoding='utf-8')
paths=re.sub(r'^<svg[^>]*>|</svg>\s*$','',source)
svg=f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512"><rect width="512" height="512" rx="96" fill="white"/><g transform="translate(48 48) scale(11.55)">{paths}</g></svg>'
for size in (192,512):
    (root/f'apps/agent_console/web/icons/Icon-{size}.png').write_bytes(resvg_py.svg_to_bytes(svg_string=svg,width=size,height=size))
for density,size in {'mdpi':48,'hdpi':72,'xhdpi':96,'xxhdpi':144,'xxxhdpi':192}.items():
    dest=root/f'apps/agent_console/android/app/src/main/res/mipmap-{density}/ic_launcher.png'
    dest.parent.mkdir(parents=True,exist_ok=True)
    dest.write_bytes(resvg_py.svg_to_bytes(svg_string=svg,width=size,height=size))
print('TongYu client icons generated')
