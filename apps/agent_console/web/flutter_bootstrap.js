{{flutter_js}}
{{flutter_build_config}}

// 主脚本带上编译版本，避免长开的页面一直命中旧 main.dart.js。
// 软重试可能再次执行本文件，用标记挡住重复声明。
(function () {
  if (window.__tongyuBootstrapApplied) {
    return;
  }
  window.__tongyuBootstrapApplied = true;
  var tongyuReleaseVersion = {{flutter_service_worker_version}};
  if (_flutter.buildConfig && Array.isArray(_flutter.buildConfig.builds)) {
    for (var i = 0; i < _flutter.buildConfig.builds.length; i++) {
      var build = _flutter.buildConfig.builds[i];
      if (build.mainJsPath && String(build.mainJsPath).indexOf('?release=') < 0) {
        build.mainJsPath += '?release=' + tongyuReleaseVersion;
      }
    }
  }
  // 当前 Flutter 只提供 CanvasKit。指定 html 渲染器会停在开屏。
  _flutter.loader.load({
    config: { renderer: 'canvaskit' },
  }).catch(function () {
    window.tongyuLoadingFailed && window.tongyuLoadingFailed();
  });
})();
