import 'package:flutter/widgets.dart';

/// 统一通知档位。
///
/// 所有站内轻提示都收敛到这两个档位，由右下角 [NoticeHub] 统一渲染。
enum NoticeKind {
  /// 短提示条：与卡片同一圆角和左色条，图标 + 一两行文字 + 可选关闭。
  /// 用于「已复制」「发送失败」这类纯反馈，3 秒自隐。
  toast,

  /// 可操作通知卡：头像/图标 + 标题(含计数) + 单行预览 + 动作 + 关闭。
  /// 用于「新消息」「待接待」「新分配」「转接」这类需要坐席跟进的提醒。
  card,
}

/// 一条统一通知。
///
/// 刻意只放数据、不依赖任何 Widget，让 state 层的控制器不必反向依赖 UI。
/// [body] 与 [count] 可变：同 [groupKey] 的卡片聚合时刷新预览、累加计数。
class NoticeItem {
  NoticeItem({
    required this.id,
    required this.kind,
    required this.title,
    this.kicker,
    this.groupKey,
    this.body,
    this.avatarLabel,
    this.icon,
    this.accent,
    this.openId,
    this.actionLabel,
    this.onAction,
    this.dismissible = true,
    Duration? duration,
    this.countUnit = '条新消息',
  }) : duration = duration ??
            (kind == NoticeKind.card
                ? const Duration(seconds: 8)
                : const Duration(seconds: 3));

  /// 唯一键；同一条提示只出现一次，聚合与移除都靠它。
  final String id;

  final NoticeKind kind;

  /// 标题。普通卡片上是主文案；带 [kicker] 时降为副行（如发送者名）。
  final String title;

  /// 眉题。非空时卡片改成新消息版式：眉题在上，正文为主行，标题为副行。
  final String? kicker;

  /// 聚合键（如会话 id）：同键的 [NoticeKind.card] 通知合并为一张并累加计数，
  /// 不再一摞堆叠；最新一条的预览会覆盖旧预览。
  final String? groupKey;

  /// 单行预览；卡片副标题。
  String? body;

  /// 头像首字（如客户姓氏）；非空时优先于 [icon]。
  final String? avatarLabel;

  /// 头像位图标；[avatarLabel] 为空时使用。
  final IconData? icon;

  /// 左侧竖条、头像与计数角标的强调色；空则用主题主色。
  final Color? accent;

  /// 点击卡片或动作按钮时，经宿主回调传出的标识（如会话 id）。
  final String? openId;

  /// 动作按钮文案；空则卡片不显示动作按钮。
  final String? actionLabel;

  /// 点击卡片或动作按钮时直接调用的回调；优先于 [openId] 走宿主跳转。
  final VoidCallback? onAction;

  final bool dismissible;

  /// 自动收起时长。
  final Duration duration;

  /// 计数角标后缀：「N 条新消息」。仅聚合后（[count] > 1）显示。
  final String countUnit;

  /// 聚合计数，默认 1。
  int count = 1;
}

/// 右下角统一通知宿主的数据源。
///
/// 控制器只负责「该弹一条提示了」这一事实，界面负责渲染与自动消失，
/// 两者用 [ChangeNotifier] 解耦：控制器 show，浮层监听后渲染。
class NoticeHubController extends ChangeNotifier {
  NoticeHubController({this.maxVisible = 3});

  /// 点击卡片上的会话时回调。工作台挂上，离开工作台时清空。
  ValueChanged<String>? onOpen;

  /// 同屏最多堆叠几张通知，避免刷屏把会话区挡死。
  final int maxVisible;

  final List<NoticeItem> _items = <NoticeItem>[];

  bool get isEmpty => _items.isEmpty;

  int get length => _items.length;

  /// 当前需要显示的通知，按到达顺序从旧到新（最新的在最下）。
  List<NoticeItem> get items => List<NoticeItem>.unmodifiable(_items);

  /// 入队一条通知。同一 [NoticeItem.id] 不重复；
  /// 同 [NoticeItem.groupKey] 的卡片聚合计数、刷新预览；
  /// 超出上限时挤掉最旧的一张。
  void show(NoticeItem item) {
    if (item.id.isEmpty) return;
    if (item.kind == NoticeKind.card && item.groupKey != null) {
      final i = _items.indexWhere(
          (e) => e.kind == NoticeKind.card && e.groupKey == item.groupKey);
      if (i >= 0) {
        final existing = _items[i];
        existing.count += 1;
        existing.body = item.body;
        notifyListeners();
        return;
      }
    }
    // 同一句轻提示只留一张。重复触发（例如连点发送）刷新这一张，不再叠成三层。
    if (item.kind == NoticeKind.toast) {
      final i = _items.indexWhere(
          (e) => e.kind == NoticeKind.toast && e.title == item.title);
      if (i >= 0) {
        _items[i].count += 1;
        notifyListeners();
        return;
      }
    }
    _items.add(item);
    while (_items.length > maxVisible) {
      _items.removeAt(0);
    }
    notifyListeners();
  }

  /// 卡片播完退场动画后调用，真正从队列移除。
  void dismiss(String id) {
    final before = _items.length;
    _items.removeWhere((e) => e.id == id);
    if (_items.length != before) notifyListeners();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }
}
