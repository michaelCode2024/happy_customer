// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

bool get canOpenWebsite => true;

/// 官网与工作台共用部署域名；不带令牌、企业标识或登录表单内容。
void openWebsite() => html.window.location.assign('/');
