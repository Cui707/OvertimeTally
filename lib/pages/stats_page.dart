import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/date_x.dart';
import '../providers/overtime_provider.dart';
import '../widgets/month_picker_bar.dart';
import '../widgets/stat_tile.dart';
import '../widgets/stat_tile_grid.dart';

/// 月度统计面板。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  bool _exporting = false;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<OvertimeProvider>();
    final stats = provider.stats;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        MonthPickerBar(
          month: provider.selectedMonth,
          onPrevious: provider.goToPreviousMonth,
          onNext: provider.goToNextMonth,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: StatTileGrid(
            minTileWidth: 140,
            maxColumns: 2,
            tiles: [
              StatTile(
                label: '当月加班总时长',
                value: formatHours(stats.totalOvertimeMinutes),
                icon: Icons.timer_outlined,
                emphasis: true,
              ),
              StatTile(
                label: '当月总加班费',
                value: stats.totalOvertimePay.toStringAsFixed(2),
                icon: Icons.payments_outlined,
                emphasis: true,
              ),
              StatTile(
                label: '剩余可调休',
                value: formatHours(stats.remainingCompMinutes),
                icon: Icons.hourglass_bottom,
              ),
              StatTile(
                label: '当月已调休',
                value: formatHours(stats.compUsedMinutes),
                icon: Icons.event_available,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '加班明细',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const Divider(height: 20),
                  _DetailRow(
                    label: '工作日加班总时长',
                    value: '${formatMinutes(stats.weekdayOvertimeMinutes)}'
                        '（${formatHours(stats.weekdayOvertimeMinutes)} 小时）',
                  ),
                  _DetailRow(
                    label: '周末加班总时长',
                    value: '${formatMinutes(stats.weekendOvertimeMinutes)}'
                        '（${formatHours(stats.weekendOvertimeMinutes)} 小时）',
                  ),
                  _DetailRow(
                    label: '调休抵扣',
                    value: formatMinutes(stats.compUsedMinutes),
                  ),
                  _DetailRow(
                    label: '当月加班总时长',
                    value: '${formatMinutes(stats.totalOvertimeMinutes)}'
                        '（${formatHours(stats.totalOvertimeMinutes)} 小时）',
                  ),
                  _DetailRow(
                    label: '当月工作日加班费',
                    value: '${stats.weekdayOvertimeMinutes ~/ 60} 小时 × '
                        '${stats.weekdayRatePerHour.toStringAsFixed(0)} 元 = '
                        '${stats.weekdayOvertimePay.toStringAsFixed(2)} 元',
                  ),
                  _DetailRow(
                    label: '当月周末加班费',
                    value: '${stats.effectiveWeekendOvertimeMinutes ~/ 60} 小时 × '
                        '${stats.weekendRatePerHour.toStringAsFixed(0)} 元 = '
                        '${stats.weekendOvertimePay.toStringAsFixed(2)} 元',
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download_outlined),
            label: Text(_exporting ? '正在导出...' : '导出本月 Excel'),
          ),
        ),
      ],
    );
  }

  Future<void> _export() async {
    final provider = context.read<OvertimeProvider>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      final path = await provider.exportSelectedMonth();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(path == null ? '已取消保存' : '已保存到：$path'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('导出失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final valueStyle = theme.textTheme.bodyLarge?.copyWith(
      fontWeight: FontWeight.w500,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 320) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: labelStyle),
                const SizedBox(height: 2),
                Text(value, style: valueStyle),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 150, child: Text(label, style: labelStyle)),
              Expanded(child: Text(value, style: valueStyle)),
            ],
          );
        },
      ),
    );
  }
}
