// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:web/web.dart' as web;

bool get canOpenWebsite => true;

/// iOS 主屏幕书签把 `navigator.standalone` 设为 true，标准 display-mode 查不到。
extension type _IosNavigator(web.Navigator _) implements web.Navigator {
  external bool? get standalone;
}

/// 主屏幕启动的书签包和 PWA 都属于客户端入口；兼容已安装的旧书签，
/// 通过运行模式识别，不要求用户重新下载描述文件。
bool get canReturnToWebsite =>
    !html.window.matchMedia('(display-mode: standalone)').matches &&
    !html.window.matchMedia('(display-mode: fullscreen)').matches &&
    _IosNavigator(web.window.navigator).standalone != true;

/// 官网与工作台共用部署域名；不带令牌、企业标识或登录表单内容。
void openWebsite() => html.window.location.assign('/');

void openDownloads() => html.window.open('/downloads/', '_blank');
