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
        if (tongyuReleaseVersion != null && String(tongyuReleaseVersion) !== '' && String(tongyuReleaseVersion) !== 'null') {
        build.mainJsPath += '?release=' + tongyuReleaseVersion;
      }
      }
    }
  }
  // 当前 Flutter 只提供 CanvasKit。指定 html 渲染器会停在开屏。
  // fontFallbackBaseUrl：缺字时不要去 fonts.gstatic.com（国内失败会闪方框）；
  // 指同源空目录，404 立刻放弃，中文只靠 pubspec 的 SportsChinese。
  _flutter.loader.load({
    config: {
      renderer: 'canvaskit',
      canvasKitBaseUrl: new URL('canvaskit/', document.baseURI).toString(),
      fontFallbackBaseUrl: new URL('fonts/canvas-fallback/', document.baseURI).toString(),
    },
  }).catch(function () {
    window.tongyuLoadingFailed && window.tongyuLoadingFailed();
  });
})();
