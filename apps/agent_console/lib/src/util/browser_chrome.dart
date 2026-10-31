import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 网页顶栏/底栏取色。登录页蓝色头部和滚上来的白卡不是同一种底，顶栏跟着当前露出来的颜色走。
///
/// 底栏同一个道理：Home 条画在贴底栏内部，采样色必须取这栏的颜色，
/// 不能写死页面底色，否则栏和系统底部之间会有一条色差。
class BrowserChrome {
  static final ValueNotifier<Color?> top = ValueNotifier<Color?>(null);

  /// 安卓状态栏不铺实色，让页面顶部自己透出来；只按亮度改图标。
  static SystemUiOverlayStyle overlayFor(Color top) {
    final lightIcons = top.computeLuminance() < 0.45;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: lightIcons ? Brightness.light : Brightness.dark,
      statusBarBrightness: lightIcons ? Brightness.dark : Brightness.light,
      systemStatusBarContrastEnforced: false,
    );
  }

  /// 贴底栏登记的颜色；多处同时存在时按登记序号取最新，卸载后自动回退。
  static final ValueNotifier<Color?> bottom = ValueNotifier<Color?>(null);

  static final Map<Object, (int, Color)> _bottoms = <Object, (int, Color)>{};
  static int _bottomSeq = 0;

  static void setTop(Color? color) {
    if (top.value == color) return;
    top.value = color;
  }

  static void registerBottom(Object owner, Color color) {
    final current = _bottoms[owner];
    if (current != null && current.$2 == color) return;
    _bottoms[owner] = (++_bottomSeq, color);
    _emitBottom();
  }

  static void unregisterBottom(Object owner) {
    if (_bottoms.remove(owner) == null) return;
    _emitBottom();
  }

  static void _emitBottom() {
    Color? latest;
    var best = -1;
    for (final entry in _bottoms.values) {
      if (entry.$1 > best) {
        best = entry.$1;
        latest = entry.$2;
      }
    }
    if (bottom.value == latest) return;
    bottom.value = latest;
  }
}

/// 只登记颜色、不参与布局：包在已有的贴底栏外面，让外层安全区跟着它取色。
///
/// 被新页面整页盖住（TickerMode 关闭）或卸载时撤销登记，避免上一页的颜色残留。
class BrowserBottomChrome extends StatefulWidget {
  const BrowserBottomChrome(
      {super.key, required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  State<BrowserBottomChrome> createState() => _BrowserBottomChromeState();
}

class _BrowserBottomChromeState extends State<BrowserBottomChrome> {
  Color? _wanted;
  bool _scheduled = false;
  bool _registered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _wanted = TickerMode.valuesOf(context).enabled ? widget.color : null;
    _scheduleSync();
  }

  @override
  void didUpdateWidget(BrowserBottomChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color) {
      _wanted = TickerMode.valuesOf(context).enabled ? widget.color : null;
      _scheduleSync();
    }
  }

  /// 登记会通知外层重建，不能在 build/didChangeDependencies 里同步改，否则会
  /// 「markNeedsBuild called during build」。放到帧末，颜色只差一帧。
  void _scheduleSync() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final color = _wanted;
      if (color == null) {
        if (_registered) {
          BrowserChrome.unregisterBottom(this);
          _registered = false;
        }
      } else {
        BrowserChrome.registerBottom(this, color);
        _registered = true;
      }
    });
  }

  @override
  void dispose() {
    if (_registered) BrowserChrome.unregisterBottom(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
