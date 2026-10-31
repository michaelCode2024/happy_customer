import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/util/web_emoji_font.dart';

/// 输入框表情。分类和内容与访客端一致，点一下插入光标处，面板保持打开。
class ComposerEmojiPanel extends StatefulWidget {
  const ComposerEmojiPanel({super.key, required this.onPick});

  final ValueChanged<String> onPick;

  @override
  State<ComposerEmojiPanel> createState() => _ComposerEmojiPanelState();
}

class _ComposerEmojiPanelState extends State<ComposerEmojiPanel> {
  int _tab = 0;

  static const _tabs = ['笑脸', '心情', '手势', '日常'];

  static const _groups = <List<String>>[
    [
      '😀', '😃', '😄', '😁', '😆', '😅', '😂', '🤣',
      '😊', '🙂', '🙃', '😉', '😌', '😍', '🥰', '😘',
      '😋', '😛', '😜', '🤪', '🤔', '🤭', '🤫', '🫡',
    ],
    [
      '😎', '🤩', '🥳', '😏', '😒', '😔', '😢', '😭',
      '😤', '😠', '😡', '🤯', '😳', '🥺', '😱', '😨',
      '😰', '😥', '😓', '🤗', '🥱', '😴', '😷', '🤒',
    ],
    [
      '👍', '👎', '👏', '🙌', '👐', '🤝', '🙏', '💪',
      '👌', '✌️', '🤞', '🤟', '🤘', '🤙', '👋', '🤚',
      '✋', '🖐️', '👊', '✊', '🤛', '🤜', '🙋', '🫶',
    ],
    [
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍',
      '💕', '💖', '💯', '✅', '🎉', '🎊', '🎁', '🌹',
      '🌸', '☀️', '🌈', '⭐', '🔥', '☕', '🍰', '🎈',
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final emojis = _groups[_tab];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1E1F24) : const Color(0xFFF5F6F7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Material(
                      color: _tab == i
                          ? const Color(0xFFE5EDFF)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => setState(() => _tab = i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          child: Text(
                            _tabs[i],
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.2,
                              color: _tab == i
                                  ? const Color(0xFF3370FF)
                                  : (dark
                                      ? const Color(0xFFE8EAEF)
                                      : const Color(0xFF1F2329)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: emojis.length,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 32,
                mainAxisSpacing: 0,
                crossAxisSpacing: 0,
              ),
              itemBuilder: (context, index) {
                final emoji = emojis[index];
                return InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => widget.onPick(emoji),
                  child: Center(
                    child: Text(
                      emoji,
                      style: withWebEmojiFallback(
                        const TextStyle(fontSize: 20, height: 1),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 桌面表情浮层。贴在按钮上方，盖住消息区，不把输入区撑高。
class ComposerEmojiPopover extends StatelessWidget {
  const ComposerEmojiPopover({
    super.key,
    required this.info,
    required this.tapGroup,
    required this.onDismiss,
    required this.onPick,
  });

  final OverlayChildLayoutInfo info;

  /// 和表情按钮同一个 [TapRegion] 组，点按钮收起时不会被当成点到外面。
  final Object tapGroup;
  final VoidCallback onDismiss;
  final ValueChanged<String> onPick;

  static const _width = 320.0;
  static const _gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final origin =
        MatrixUtils.getAsTranslation(info.childPaintTransform) ?? Offset.zero;
    final overlay = info.overlaySize;
    var left = origin.dx;
    if (left + _width > overlay.width - 12) {
      left = overlay.width - _width - 12;
    }
    if (left < 12) left = 12;

    final placeAbove = origin.dy >= 160;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final panel = Material(
      elevation: 10,
      shadowColor: const Color(0x33000000),
      surfaceTintColor: Colors.transparent,
      color: dark ? const Color(0xFF1E1F24) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: dark ? const Color(0xFF3A3D46) : const Color(0xFFE5E6EB),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: _width,
        child: ComposerEmojiPanel(onPick: onPick),
      ),
    );

    return Positioned(
      left: left,
      width: _width,
      bottom: placeAbove ? overlay.height - origin.dy + _gap : null,
      top: placeAbove ? null : origin.dy + info.childSize.height + _gap,
      child: TapRegion(
        groupId: tapGroup,
        onTapOutside: (_) => onDismiss(),
        child: panel,
      ),
    );
  }
}
