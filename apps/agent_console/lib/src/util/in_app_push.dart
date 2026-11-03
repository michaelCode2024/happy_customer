import 'package:flutter/foundation.dart';

/// 一条「站内推送提醒」的完整信息。
///
/// 由 [WorkbenchController] 在收到新消息时产生，界面层负责把它渲染成
/// 右上角滑出的提醒卡片。这里刻意只放数据，不依赖任何 Widget，
/// 让控制器不必反向依赖 UI。
class InAppMessagePush {
  const InAppMessagePush({
    required this.messageId,
    required this.conversationId,
    required this.sender,
    required this.preview,
  });

  /// 去重键：同一条消息只提醒一次。
  final String messageId;

  /// 点击卡片后要打开的会话。
  final String conversationId;

  /// 发送者显示名；空串时界面回退成「客户」。
  final String sender;

  /// 消息预览，作为卡片副标题；过长由界面截断。
  final String preview;
}

/// 站内推送提醒队列。
///
/// 控制器只负责「来了一条新消息」这一事实，界面负责显示与自动消失。
/// 两者用 [ChangeNotifier] 解耦：控制器 push，浮层监听后渲染，
/// 浮层播完退场动画再 remove，避免卡片突然消失。
class InAppPushManager extends ChangeNotifier {
  InAppPushManager({this.maxVisible = 4});

  /// 同屏最多堆叠几张卡片，避免刷屏把会话区挡死。
  final int maxVisible;

  final List<InAppMessagePush> _items = <InAppMessagePush>[];

  /// 当前需要显示的提醒，按到达顺序从旧到新。
  List<InAppMessagePush> get items =>
      List<InAppMessagePush>.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  /// 入队。同一 [InAppMessagePush.messageId] 不重复；超出上限时挤掉最旧的一张。
  void push(InAppMessagePush item) {
    if (item.messageId.isEmpty) return;
    if (_items.any((e) => e.messageId == item.messageId)) return;
    _items.add(item);
    while (_items.length > maxVisible) {
      _items.removeAt(0);
    }
    notifyListeners();
  }

  /// 卡片自己播完退场动画后调用，真正从队列移除。
  void remove(String messageId) {
    final before = _items.length;
    _items.removeWhere((e) => e.messageId == messageId);
    if (_items.length != before) notifyListeners();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }
}
