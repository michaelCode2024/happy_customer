import 'package:flutter/material.dart';

/// 网页顶栏取色。登录页蓝色头部和滚上来的白卡不是同一种底，顶栏跟着当前露出来的颜色走。
class BrowserChrome {
  static final ValueNotifier<Color?> top = ValueNotifier<Color?>(null);

  static void setTop(Color? color) {
    if (top.value == color) return;
    top.value = color;
  }
}
