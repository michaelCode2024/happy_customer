import 'package:flutter/material.dart';

void main() {
  runApp(const RelayDeskApp());
}

class RelayDeskApp extends StatelessWidget {
  const RelayDeskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RelayDesk',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF356AE6),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF86A8FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const WorkbenchPage(),
    );
  }
}

class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({super.key});

  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final content = const _EmptyInbox();
        if (compact) {
          return Scaffold(
            appBar: AppBar(title: const Text('RelayDesk 工作台')),
            body: content,
            bottomNavigationBar: NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: (value) => setState(() => selectedIndex = value),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.forum_outlined), label: '会话'),
                NavigationDestination(icon: Icon(Icons.people_outline), label: '客户'),
                NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置'),
              ],
            ),
          );
        }
        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                extended: constraints.maxWidth >= 1100,
                selectedIndex: selectedIndex,
                onDestinationSelected: (value) => setState(() => selectedIndex = value),
                leading: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Icon(Icons.support_agent, size: 32),
                ),
                destinations: const [
                  NavigationRailDestination(icon: Icon(Icons.forum_outlined), label: Text('会话')),
                  NavigationRailDestination(icon: Icon(Icons.people_outline), label: Text('客户')),
                  NavigationRailDestination(icon: Icon(Icons.settings_outlined), label: Text('设置')),
                ],
              ),
              const VerticalDivider(width: 1),
              const Expanded(child: content),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mark_unread_chat_alt_outlined, size: 72),
            SizedBox(height: 20),
            Text('工作台已就绪', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text('下一步将接入坐席身份、实时收件箱与会话回复。', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
