{{flutter_js}}
{{flutter_build_config}}

// 编译版本进入主脚本地址，避免长开的后台一直命中旧 main.dart.js。
const releaseVersion = {{flutter_service_worker_version}};
for (const build of _flutter.buildConfig.builds) {
  if (build.mainJsPath) {
    build.mainJsPath += '?release=' + releaseVersion;
  }
}
// CanvasKit 会向 Google Fonts 拉 Noto Sans SC；国内网络常失败，中文就会变成方框。
// 固定 HTML 渲染器，用系统 CJK 字体（微软雅黑等），与 index.html 的 font-family 一致。
_flutter.loader.load({
  serviceWorkerSettings: { serviceWorkerVersion: releaseVersion },
  config: { renderer: 'html' },
});
