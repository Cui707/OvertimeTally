import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/date_x.dart';
import '../providers/overtime_provider.dart';
import '../widgets/month_picker_bar.dart';

/// 月度日历视图，展示每天的加班与调休情况。
///
/// 点击某天跳转到打卡页编辑；长按某天可删除当天的打卡记录。
class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key, required this.onEditDay});

  final ValueChanged<DateTime> onEditDay;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<OvertimeProvider>();
    final month = provider.selectedMonth;
    final today = dateOnly(DateTime.now());

    final leading = firstDayOfMonth(month).weekday - 1;
    final totalDays = daysInMonth(month);
    final cellCount = ((leading + totalDays + 6) ~/ 7) * 7;
    final cells = List<DateTime?>.generate(cellCount, (index) {
      final day = index - leading + 1;
      if (day < 1 || day > totalDays) return null;
      return DateTime(month.year, month.month, day);
    });

    final rows = <List<DateTime?>>[];
    for (var i = 0; i < cells.length; i += 7) {
      rows.add(cells.sublist(i, i + 7));
    }

    return Column(
      children: [
        MonthPickerBar(
          month: month,
          onPrevious: provider.goToPreviousMonth,
          onNext: provider.goToNextMonth,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: kWeekdayLabels
                .map(
                  (label) => Expanded(
                    child: Center(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              children: rows
                  .map(
                    (row) => Expanded(
                      child: Row(
                        children: row
                            .map(
                              (day) => Expanded(
                                child: _DayCell(
                                  day: day,
                                  isToday: day != null && isSameDate(day, today),
                                  onTap: day == null ? null : () => onEditDay(day),
                                  onLongPress: day == null
                                      ? null
                                      : () => _deleteDay(context, day),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
        const _Legend(),
      ],
    );
  }

  Future<void> _deleteDay(BuildContext context, DateTime day) async {
    final provider = context.read<OvertimeProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final record = provider.recordForDate(day);
    if (record == null) {
      messenger.showSnackBar(
        SnackBar(content: Text('${formatDate(day)} 没有打卡记录')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除打卡记录'),
        content: Text(
          '确定要删除 ${formatDate(day)} 的打卡记录吗？'
          '该日的上下班时间与备注都会被清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await provider.deleteDayRecord(day);
      messenger.showSnackBar(
        SnackBar(content: Text('已删除 ${formatDate(day)} 的打卡记录')),
      );
    }
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.isToday,
    this.onTap,
    this.onLongPress,
  });

  final DateTime? day;
  final bool isToday;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    if (day == null) return const SizedBox.shrink();

    final provider = context.watch<OvertimeProvider>();
    final result = provider.resultForDate(day!);
    final compMinutes = provider
        .compRecordsForDate(day!)
        .fold<int>(0, (sum, record) => sum + record.minutes);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final badges = <Widget>[];
    if (result.weekdayOvertimeMinutes > 0) {
      badges.add(_badge('工+${formatHours(result.weekdayOvertimeMinutes)}h', scheme.primary));
    }
    if (result.weekendOvertimeMinutes > 0) {
      badges.add(_badge('休+${formatHours(result.weekendOvertimeMinutes)}h', scheme.tertiary));
    }
    if (compMinutes > 0) {
      badges.add(_badge('调${formatHours(compMinutes)}h', scheme.secondary));
    }

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isToday ? scheme.primary : scheme.outlineVariant,
            width: isToday ? 2 : 0.5,
          ),
          color: day!.weekday == DateTime.saturday || day!.weekday == DateTime.sunday
              ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
              : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${day!.day}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            const Spacer(),
            ...badges,
          ],
        ),
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: TextStyle(fontSize: 9, color: color, height: 1.2),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _item(scheme.primary, '工作日加班'),
              _item(scheme.tertiary, '周末加班'),
              _item(scheme.secondary, '调休'),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '点击日期查看/编辑，长按日期可删除当天打卡记录',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, color: color.withValues(alpha: 0.4)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
