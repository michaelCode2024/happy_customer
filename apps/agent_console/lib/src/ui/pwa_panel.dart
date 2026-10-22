import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../api/tongyu_api.dart';
import '../util/pwa_bridge.dart';

/// 安装、离线就绪和版本更新使用同一个入口，避免把浏览器权限误当成已开启。
class PwaPanel extends StatefulWidget {
  const PwaPanel(
      {super.key,
      this.api,
      this.onReconnect,
      this.settingsOnly = false,
      this.hideUpdateBanner = false});
  final TongYuApi? api;
  final bool settingsOnly;
  final bool hideUpdateBanner;
  final Future<void> Function()? onReconnect;
  @override
  State<PwaPanel> createState() => _PwaPanelState();
}

class _PwaPanelState extends State<PwaPanel> {
  Timer? _timer;
  Map<String, dynamic> _status = {};
  bool _busy = false;
  bool _prompting = false;
  bool _offline = false;
  @override
  void initState() {
    super.initState();
    _status = pwaStatus();
    _offline = browserOffline || (widget.api?.isOffline ?? false);
    if (kIsWeb &&
        !widget.settingsOnly &&
        Uri.base.queryParameters['install'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(pwaAction('consumeInstallRequest'));
        if (mounted && pwaStatus()['installed'] != true) _installation();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerUpdate());
    if (kIsWeb)
      _timer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!mounted) return;
        final wasBrowserOffline = _status['offline'] == true;
        setState(() {
          _status = pwaStatus();
          _offline = browserOffline || (widget.api?.isOffline ?? false);
        });
        unawaited(_offerUpdate());
        if (wasBrowserOffline && !browserOffline) unawaited(_reconnect());
      });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _offerUpdate() async {
    if (!mounted ||
        widget.settingsOnly ||
        _prompting ||
        _status['update'] != true ||
        ModalRoute.of(context)?.isCurrent != true) return;
    _prompting = true;
    try {
      if (await pwaAction('claimUpdatePrompt') == 'show' && mounted)
        await _confirmUpdate();
    } finally {
      _prompting = false;
    }
  }

  Future<void> _confirmUpdate() async {
    // 更新说明来自等待激活的 worker，避免把当前版本说明配到下一个版本。
    final raw = pwaStatus()['updateRelease'];
    final release = raw is Map ? raw : const {};
    final version = (release['version'] ?? '').toString();
    final rawNotes = release['notes'];
    final notes =
        rawNotes is List ? rawNotes.whereType<String>().toList() : <String>[];
    final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
                title: const Text('通语有新版本'),
                content: SizedBox(
                    width: 400,
                    child: SingleChildScrollView(
                        child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (version.isNotEmpty)
                          Text('版本 $version',
                              style: Theme.of(c).textTheme.titleSmall),
                        const SizedBox(height: 12),
                        if (notes.isEmpty) const Text('新版本已下载，可以立即更新。'),
                        for (final note in notes)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Text('• $note')),
                        const SizedBox(height: 12),
                        const Text(
                            '更新前会等待文字草稿保存。页面将重新加载，尚未发送的附件需要重新选择；正在录音时请先完成录音。'),
                      ],
                    ))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('稍后')),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('立即更新')),
                ]));
    if (ok != true || !mounted) return;
    // 等待输入框的草稿防抖与本机存储队列完成，再允许重载。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await widget.api?.offlineStore?.flush();
    if (!mounted) return;
    if (widget.api?.offlineStore?.writeFailed == true) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('草稿尚未可靠保存，请先复制文字，再更新应用')));
      return;
    }
    await _action('update');
  }

  Future<void> _reconnect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // 联网后先重新鉴权，权限撤销时不能继续把旧数据冒充最新状态。
      await widget.api?.me();
      await widget.onReconnect?.call();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('暂时无法同步，请检查网络后重试')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(String action) async {
    final message = await pwaAction(action);
    if (mounted && message.isNotEmpty)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
  }

  void _installation() {
    final status = pwaStatus();
    if (status['installed'] == true) return;
    final ios = status['ios'] == true;
    final embedded = status['embedded'] == true;
    final android = status['android'] == true;
    final steps = embedded
        ? ['点击当前浏览器右上角菜单', '选择在系统浏览器中打开，苹果建议使用 Safari', '在浏览器中重新点击添加到桌面']
        : ios
            ? [
                '点击浏览器的分享按钮（方框向上箭头）',
                '选择「添加到主屏幕」，如未看到请向下滚动菜单',
                '如有「作为 Web App 打开」请保持开启，再点击「添加」',
                '回到主屏幕，点击「通语」图标打开'
              ]
            : android
                ? [
                    '点击下方「继续安装」，在浏览器弹窗中确认',
                    '如没有弹窗，打开浏览器右上角菜单，选择「安装应用」或「添加到主屏幕」',
                    '安装完成后，从主屏幕的「通语」图标打开'
                  ]
                : [
                    '点击下方「继续安装」，在浏览器弹窗中确认',
                    '如没有弹窗，使用地址栏安装图标或浏览器菜单中的「安装应用」；建议使用 Chrome 或 Edge',
                    '安装完成后，从桌面或应用列表打开「通语」'
                  ];
    showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(ios ? '将通语添加到主屏幕' : '安装通语应用'),
              content: SizedBox(
                  width: 400,
                  child: SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(embedded
                            ? '当前为应用内浏览器，请先切换到系统浏览器。'
                            : ios
                                ? '苹果需要你在浏览器菜单里确认，网页无法替你完成添加。'
                                : '由浏览器完成安装，无需下载安装包。'),
                        const SizedBox(height: 16),
                        for (var i = 0; i < steps.length; i++)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    CircleAvatar(
                                        radius: 12,
                                        child: Text('${i + 1}',
                                            style:
                                                const TextStyle(fontSize: 12))),
                                    const SizedBox(width: 12),
                                    Expanded(child: Text(steps[i])),
                                  ])),
                        const Text('已添加过？直接从桌面图标打开即可，无需重复安装。'),
                      ]))),
              actions: [
                if (!ios && !embedded)
                  FilledButton(
                      onPressed: () async {
                        // 保留这次点击的用户激活，直接调用浏览器安装；无弹窗时保留操作步骤。
                        final result = await pwaAction('install');
                        if (mounted && ctx.mounted)
                          showDialog<void>(
                              context: ctx,
                              builder: (c) => AlertDialog(
                                      title: const Text('安装提示'),
                                      content: Text(result),
                                      actions: [
                                        TextButton(
                                            onPressed: () => Navigator.pop(c),
                                            child: const Text('知道了'))
                                      ]));
                      },
                      child: const Text('继续安装')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('知道了')),
              ],
            ));
  }

  // ignore: unused_element
  void _details() => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: const Text('安装与离线使用'),
            content: const SizedBox(
                width: 420,
                child: SingleChildScrollView(
                    child: Text(
                        'iPhone / iPad：使用 Safari 打开工作台，点「分享 → 添加到主屏幕」，然后从桌面图标打开。\n\n'
                        '安卓 / 电脑：点击「安装应用」，或使用浏览器菜单中的安装入口。\n\n'
                        '首次联网打开后，可在个人设置 → 外观与通知中确认「离线资源已就绪」。离线可查看本账号最近查看过的会话文字，继续编辑草稿；未缓存的会话与附件仍需联网。\n\n'
                        '应用会在联网启动、回到前台和持续使用时自动检查更新，并在后台下载。新版本就绪后会提示；保存草稿并点击「更新应用」后才会重载，无需重新添加桌面图标。也可点击下方「检查更新」。\n\n'
                        '离线草稿不会自动发送。联网后先同步会话，确认回复仍适用，再点击发送。首次登录、AI、附件上传、群聊和管理操作需要联网。\n\n'
                        '会话快照最多保留 24 小时，本机草稿最多保留 7 天，并有容量限制；退出账号会清理本账号离线数据。浏览器或系统清理存储后，需重新联网准备。\n\n'
                        '后台通知需登录后在消息中心主动开启，并允许系统通知；iPhone / iPad 需 iOS 16.4 及以上和主屏幕应用。断网期间不能接收新消息。'))),
            actions: [
              TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    unawaited(_action('persist'));
                  },
                  child: const Text('申请保留本机数据')),
              if (pwaStatus()['installed'] != true)
                TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _installation();
                    },
                    child: const Text('添加到桌面')),
              TextButton(
                  onPressed: () => _action('checkUpdate'),
                  child: const Text('检查更新')),
              if (widget.api != null)
                TextButton(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                          context: ctx,
                          builder: (c) => AlertDialog(
                                  title: const Text('清理本账号离线数据？'),
                                  content:
                                      const Text('本机的会话快照和未同步草稿将删除，服务端消息不受影响。'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(c, false),
                                        child: const Text('取消')),
                                    TextButton(
                                        onPressed: () => Navigator.pop(c, true),
                                        child: const Text('清理'))
                                  ]));
                      if (confirmed == true)
                        await widget.api?.offlineStore?.clear(retire: false);
                    },
                    child: const Text('清理离线数据')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
            ],
          ));

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return const SizedBox.shrink();
    final update = _status['update'] == true;

    // 只保留热更新提示，不展示任何离线、离线安装恢复相关横幅
    if (widget.settingsOnly) {
      return ListTile(
        leading: const Icon(Icons.system_update_alt_rounded),
        title: const Text('系统更新'),
        subtitle: Text(update ? '新版本已就绪，请保存草稿后更新' : '已是最新版本'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _action('checkUpdate'),
      );
    }

    // 仅在有新版本就绪时才展示热更新条
    if (!update || widget.hideUpdateBanner) {
      return const SizedBox.shrink();
    }

    return Material(
        color: const Color(0xFFEFF4FF),
        child: Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFD3E0FD))),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 16, color: Color(0xFF3263FF)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '通语工作台新版本已就绪，保存草稿后即可立即应用',
                      style: TextStyle(fontSize: 13, color: Color(0xFF0C1D40), fontWeight: FontWeight.w500),
                    ),
                  ),
                  TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF3263FF),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      ),
                      onPressed: _confirmUpdate,
                      child: const Text('立即更新', style: TextStyle(fontWeight: FontWeight.w600))),
                ])));
  }
}
