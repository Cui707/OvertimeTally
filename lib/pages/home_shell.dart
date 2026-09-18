import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/overtime_provider.dart';
import 'calendar_page.dart';
import 'clock_page.dart';
import 'comp_time_page.dart';
import 'stats_page.dart';

/// 应用外壳：底部导航 + 四个页面。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const List<String> _titles = ['打卡', '日历', '调休', '统计'];

  int _index = 0;

  void _openDay(DateTime date) {
    context.read<OvertimeProvider>().selectDate(date);
    setState(() => _index = 0);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<OvertimeProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text('OvertimeTally · ${_titles[_index]}'),
        centerTitle: true,
      ),
      body: provider.loading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在加载...'),
                ],
              ),
            )
          : IndexedStack(
              index: _index,
              children: [
                const ClockPage(),
                CalendarPage(onEditDay: _openDay),
                const CompTimePage(),
                const StatsPage(),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.punch_clock_outlined),
            selectedIcon: Icon(Icons.punch_clock),
            label: '打卡',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '日历',
          ),
          NavigationDestination(
            icon: Icon(Icons.beach_access_outlined),
            selectedIcon: Icon(Icons.beach_access),
            label: '调休',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: '统计',
          ),
        ],
      ),
    );
  }
}
