import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/theme.dart';

/// 移动端快捷回复底部弹窗：
/// 提供搜索、分类及一键引用到输入框，符合手机单手快速回复体验。
class MobileCannedBottomSheet extends StatefulWidget {
  const MobileCannedBottomSheet({
    super.key,
    required this.canned,
    required this.onSelect,
  });

  final List<CannedResponse> canned;
  final ValueChanged<String> onSelect;

  static Future<void> show({
    required BuildContext context,
    required List<CannedResponse> canned,
    required ValueChanged<String> onSelect,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => MobileCannedBottomSheet(
        canned: canned,
        onSelect: onSelect,
      ),
    );
  }

  @override
  State<MobileCannedBottomSheet> createState() =>
      _MobileCannedBottomSheetState();
}

class _MobileCannedBottomSheetState extends State<MobileCannedBottomSheet> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<CannedResponse> get _filteredList {
    if (_query.trim().isEmpty) {
      return widget.canned;
    }
    final q = _query.trim().toLowerCase();
    return widget.canned.where((item) {
      return item.title.toLowerCase().contains(q) ||
          item.content.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final filtered = _filteredList;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      decoration: BoxDecoration(
        color: isDark ? scheme.surface : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(isDark ? 80 : 30),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部拖动条与标题
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 12, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.bolt_rounded,
                    size: 20,
                    color: RelayTheme.blue,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '快捷回复',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: isDark ? scheme.onSurface : RelayTheme.ink,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // 搜索输入框
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  color: isDark
                      ? scheme.surfaceContainerHighest
                      : const Color(0xFFF1F3F7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: (val) => setState(() => _query = val),
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: '搜索快捷回复标题或内容…',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: isDark ? scheme.outline : RelayTheme.muted,
                    ),
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 36, minHeight: 36),
                    suffixIcon: _query.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 16),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          )
                        : null,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    isDense: true,
                  ),
                ),
              ),
            ),
            const Divider(height: 12),
            // 回复列表
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.inbox_outlined,
                            size: 40,
                            color: scheme.outlineVariant,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _query.isEmpty ? '暂无快捷回复' : '未匹配到快捷回复',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark ? scheme.outline : RelayTheme.muted,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 8, endIndent: 8),
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        return InkWell(
                          onTap: () {
                            widget.onSelect(item.content);
                            Navigator.of(context).pop();
                          },
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    const Icon(
                                      Icons.north_west_rounded,
                                      size: 16,
                                      color: RelayTheme.blue,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  item.content,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    height: 1.4,
                                    color: isDark
                                        ? scheme.onSurfaceVariant
                                        : RelayTheme.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
