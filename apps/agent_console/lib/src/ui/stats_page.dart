import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/ui/workspace_layout.dart';

import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/util/format.dart';

/// The operations dashboard.
///
/// The layout answers the three questions a supervisor actually asks: how much
/// work came in, how fast did we answer, and who is carrying it. The API returns
/// a different shape for an ordinary agent (their own workload), which the page
/// detects through [StatsOverview.isTenantWide] rather than trying to force one
/// layout onto both.
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.session, required this.workbench});

  final SessionController session;
  final WorkbenchController workbench;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  StatsOverview? _overview;
  bool _loading = true;
  String? _error;
  int _days = 14;
  int _loadRevision = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final revision = ++_loadRevision;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final overview = await widget.workbench.api.stats(days: _days);
      if (!mounted || revision != _loadRevision) {
        return;
      }
      setState(() {
        _overview = overview;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || revision != _loadRevision) {
        return;
      }
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overview = _overview;
    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).scaffoldBackgroundColor : const Color(0xFFEEF2FB),
      appBar: WorkspaceAppBar(
        title: '数据统计',
        description: '了解会话趋势、响应效率和团队工作量',
        icon: Icons.insights_outlined,
        actions: <Widget>[
          if (overview?.isTenantWide ?? false)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: DropdownButton<int>(
                value: _days,
                underline: const SizedBox.shrink(),
                items: const <DropdownMenuItem<int>>[
                  DropdownMenuItem<int>(value: 7, child: Text('近 7 天')),
                  DropdownMenuItem<int>(value: 14, child: Text('近 14 天')),
                  DropdownMenuItem<int>(value: 30, child: Text('近 30 天')),
                  DropdownMenuItem<int>(value: 90, child: Text('近 90 天')),
                ],
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() => _days = value);
                  _load();
                },
              ),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text('无法加载统计：$_error', textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        OutlinedButton(
                            onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              : overview == null
                  ? const Center(child: Text('暂无数据'))
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                      children: <Widget>[
                        if (!overview.isTenantWide) ...<Widget>[
                          _SingleCard(
                            title: '我进行中的会话',
                            value: '${overview.openConversations}',
                            caption: '统计面板仅对主管及以上角色开放，这里显示你的个人工作量。',
                          ),
                        ] else ...<Widget>[
                          _cardGrid(context, overview),
                          const SizedBox(height: 14),
                          _TrendCard(overview: overview),
                          const SizedBox(height: 14),
                          _LeaderboardCard(rows: overview.leaderboard),
                        ],
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                            '会话趋势按天汇总，队列与在线状态显示当前数据。',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 11,
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ),
                      ],
                    ),
    );
  }

  Widget _cardGrid(BuildContext context, StatsOverview overview) {
    // 调度台只留核心 KPI；其余量在趋势表 / 排行里看，避免一排分析卡片。
    final cards = <_Metric>[
      _Metric('进行中', '${overview.openConversations}', Icons.chat_bubble_outline_rounded,
          const Color(0xFF3263FF)),
      _Metric('待分配', '${overview.queued}', Icons.inbox_outlined,
          const Color(0xFFF97316)),
      _Metric('在线坐席', '${overview.onlineAgents}', Icons.people_outline_rounded,
          const Color(0xFF31977C)),
      _Metric('首响', durationText(overview.avgFirstResponseSeconds),
          Icons.schedule_rounded, const Color(0xFF7C5CFC)),
      _Metric('AI 解决率', percentText(overview.aiDeflectionRate),
          Icons.auto_awesome_outlined, const Color(0xFF0EA5E9)),
      _Metric(
        '评分',
        overview.avgRating <= 0 ? '—' : overview.avgRating.toStringAsFixed(1),
        Icons.sentiment_satisfied_alt_rounded,
        const Color(0xFFEC4899),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 1080
            ? 6
            : constraints.maxWidth > 760
                ? 3
                : 2;
        const gap = 12.0;
        final width =
            (constraints.maxWidth - (columns - 1) * gap) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final metric in cards)
              SizedBox(width: width, child: _MetricCard(metric: metric)),
          ],
        );
      },
    );
  }
}

class _Metric {
  const _Metric(this.label, this.value, this.icon, this.tone);

  final String label;
  final String value;
  final IconData icon;
  final Color tone;
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric});

  final _Metric metric;

  @override
  Widget build(BuildContext context) {
    return WorkspaceKpiCard(
        label: metric.label,
        value: metric.value,
        icon: metric.icon,
        tone: metric.tone);
  }
}

class _SingleCard extends StatelessWidget {
  const _SingleCard({
    required this.title,
    required this.value,
    required this.caption,
  });

  final String title;
  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WorkspaceCard(
      title: title,
      icon: Icons.insights_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(value,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontSize: 32, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(caption,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant, height: 1.55)),
        ],
      ),
    );
  }
}

/// The two-week trend.
///
/// Deliberately a hand-drawn pair of bars rather than a charting dependency: the
/// console ships to four platforms and a charting package is a large surface for
/// two series. The bars are laid out with a fixed gutter so the axis labels stay
/// out of the way of the plot.
class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.overview});

  final StatsOverview overview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final series = overview.series;
    return WorkspaceCard(
      title: '会话趋势',
      subtitle: '按天汇总的新会话与消息量',
      icon: Icons.show_chart_rounded,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      actions: <Widget>[
        _Legend(color: theme.colorScheme.primary, label: '新会话'),
        const SizedBox(width: 10),
        _Legend(color: const Color(0xFF7C5CFC), label: '消息数'),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (series.isEmpty)
            const SizedBox(
              height: 160,
              child: WorkspaceEmptyState(
                icon: Icons.bar_chart_rounded,
                title: '所选区间内还没有统计数据',
                description: '客户产生会话后，这里会按天补齐趋势。',
                compact: true,
              ),
            )
          else
            SizedBox(
              height: 186,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final started = series
                      .map((point) => point.conversationsStarted)
                      .fold<int>(0, (a, b) => a > b ? a : b);
                  final messages = series
                      .map((point) => point.messagesIn + point.messagesOut)
                      .fold<int>(0, (a, b) => a > b ? a : b);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      for (final point in series)
                        Expanded(
                          child: _TrendColumn(
                            point: point,
                            maxStarted: started > messages ? started : messages,
                            maxMessages:
                                started > messages ? started : messages,
                            showLabel: _shouldLabel(series, point),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// Labels every other day on a long range, so the axis stays readable.
  static bool _shouldLabel(List<StatPoint> series, StatPoint point) {
    final step = series.length > 20 ? 5 : (series.length > 10 ? 3 : 1);
    return series.indexOf(point) % step == 0;
  }
}

class _TrendColumn extends StatelessWidget {
  const _TrendColumn({
    required this.point,
    required this.maxStarted,
    required this.maxMessages,
    required this.showLabel,
  });

  final StatPoint point;
  final int maxStarted;
  final int maxMessages;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '${point.date}\n新会话 ${point.conversationsStarted}\n'
          '消息 ${point.messagesIn + point.messagesOut}\n'
          'AI 回复 ${point.aiAnswered}\n'
          '首响 ${durationText(point.avgFirstResponseSeconds)}',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                _Bar(
                  value: point.conversationsStarted,
                  max: maxStarted,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 2),
                _Bar(
                  value: point.messagesIn + point.messagesOut,
                  max: maxMessages,
                  color: const Color(0xFF7C5CFC),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            showLabel ? point.date.substring(5) : '',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.max, required this.color});

  final int value;
  final int max;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ratio = max <= 0 ? 0.0 : value / max;
    return Flexible(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 18),
        child: FractionallySizedBox(
          alignment: Alignment.bottomCenter,
          heightFactor: value == 0 ? 0.0 : ratio.clamp(0.02, 1.0),
          child: Container(
            decoration: BoxDecoration(
              color: color.withAlpha(190),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(3)),
            ),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color.withAlpha(190),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Who is carrying the workload over the last thirty days.
class _LeaderboardCard extends StatelessWidget {
  const _LeaderboardCard({required this.rows});

  final List<LeaderboardRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WorkspaceCard(
      title: '坐席排行',
      subtitle: '近 30 天已解决量与响应效率',
      icon: Icons.leaderboard_outlined,
      padding: EdgeInsets.zero,
      child: rows.isEmpty
          ? const WorkspaceEmptyState(
              icon: Icons.people_outline_rounded,
              title: '还没有坐席数据',
              description: '团队完成接待后，这里会按解决量排序。',
              compact: true,
            )
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 26,
                headingRowHeight: 38,
                dataRowMinHeight: 42,
                dataRowMaxHeight: 46,
                columns: const <DataColumn>[
                  DataColumn(label: Text('坐席')),
                  DataColumn(label: Text('已解决'), numeric: true),
                  DataColumn(label: Text('进行中'), numeric: true),
                  DataColumn(label: Text('首响均值'), numeric: true),
                  DataColumn(label: Text('评分'), numeric: true),
                ],
                rows: <DataRow>[
                  for (final row in rows)
                    DataRow(
                      cells: <DataCell>[
                        DataCell(Row(children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withOpacity(.08),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              row.displayName.isEmpty
                                  ? '?'
                                  : row.displayName.characters.first,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.primary),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(row.displayName),
                        ])),
                        DataCell(Text('${row.resolved}')),
                        DataCell(Text('${row.open}')),
                        DataCell(
                            Text(durationText(row.avgFirstResponseSeconds))),
                        DataCell(
                          Text(
                            row.avgRating <= 0
                                ? '—'
                                : row.avgRating.toStringAsFixed(1),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
    );
  }
}
