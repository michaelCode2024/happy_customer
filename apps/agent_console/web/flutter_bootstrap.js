{{flutter_js}}
{{flutter_build_config}}

// 编译版本进入主脚本地址，避免长开的后台一直命中旧 main.dart.js。
const releaseVersion = {{flutter_service_worker_version}};
for (const build of _flutter.buildConfig.builds) {
  if (build.mainJsPath) {
    build.mainJsPath += '?release=' + releaseVersion;
  }
}
// 当前 Flutter 只提供 CanvasKit 构建。继续指定 html 渲染器时加载会直接失败，页面停在开屏。
// 中文仍走主题里的系统字体回退，不依赖页面去拉一套网页字体。
_flutter.loader.load({
  config: { renderer: 'canvaskit' },
}).catch(function () {
  window.tongyuLoadingFailed?.();
});
