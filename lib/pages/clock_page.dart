import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/date_x.dart';
import '../models/daily_result.dart';
import '../models/day_record.dart';
import '../providers/overtime_provider.dart';

/// 打卡操作与当日信息页面。
class ClockPage extends StatelessWidget {
  const ClockPage({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<OvertimeProvider>();
    final date = provider.selectedDate;
    final record = provider.recordForDate(date);
    final result = provider.resultForDate(date);
    final isToday = isSameDate(date, dateOnly(DateTime.now()));

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _DateSelector(
          date: date,
          isToday: isToday,
          onPrevious: provider.goToPreviousDay,
          onNext: provider.goToNextDay,
          onPick: () => _pickDate(context),
        ),
        const SizedBox(height: 8),
        _PunchCard(
          onClockIn: () => _clockIn(context),
          onClockOut: () => _clockOut(context),
          onEditClockIn: () => _pickClockIn(context, date, record?.clockIn),
          onEditClockOut: () => _pickClockOut(context, date, record),
          hasClockIn: record?.hasClockIn ?? false,
          hasClockOut: record?.hasClockOut ?? false,
        ),
        const SizedBox(height: 8),
        _DailyInfoCard(result: result, date: date),
        const SizedBox(height: 8),
        _NoteCard(
          note: record?.note,
          onEdit: () => _editNote(context, date, record?.note),
          onClear: record == null
              ? null
              : () => _deleteRecord(context, date),
        ),
      ],
    );
  }

  Future<void> _pickDate(BuildContext context) async {
    final provider = context.read<OvertimeProvider>();
    final picked = await showDatePicker(
      context: context,
      initialDate: provider.selectedDate,
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
      helpText: '选择日期',
    );
    if (picked != null) {
      await provider.selectDate(picked);
    }
  }

  Future<void> _clockIn(BuildContext context) async {
    final provider = context.read<OvertimeProvider>();
    final messenger = ScaffoldMessenger.of(context);
    await provider.clockIn();
    final error = provider.errorMessage;
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? '上班打卡成功')),
    );
    if (error != null) provider.clearError();
  }

  Future<void> _clockOut(BuildContext context) async {
    final provider = context.read<OvertimeProvider>();
    final messenger = ScaffoldMessenger.of(context);
    await provider.clockOut();
    final error = provider.errorMessage;
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? '下班打卡成功')),
    );
    if (error != null) provider.clearError();
  }

  Future<void> _pickClockIn(
    BuildContext context,
    DateTime date,
    DateTime? current,
  ) async {
    final provider = context.read<OvertimeProvider>();
    final picked = await showTimePicker(
      context: context,
      initialTime: current == null
          ? const TimeOfDay(hour: 8, minute: 15)
          : TimeOfDay.fromDateTime(current),
      helpText: '选择上班时间',
    );
    if (picked == null) return;
    final value = DateTime(
      date.year,
      date.month,
      date.day,
      picked.hour,
      picked.minute,
    );
    await provider.updateClockIn(date, value);
  }

  Future<void> _pickClockOut(
    BuildContext context,
    DateTime date,
    DayRecord? record,
  ) async {
    final provider = context.read<OvertimeProvider>();
    final current = record?.clockOut;
    final picked = await showTimePicker(
      context: context,
      initialTime: current == null
          ? const TimeOfDay(hour: 17, minute: 30)
          : TimeOfDay.fromDateTime(current),
      helpText: '选择下班时间',
    );
    if (picked == null) return;
    var value = DateTime(
      date.year,
      date.month,
      date.day,
      picked.hour,
      picked.minute,
    );
    final clockIn = record?.clockIn;
    if (clockIn != null && !value.isAfter(clockIn)) {
      value = value.add(const Duration(days: 1));
    }
    await provider.updateClockOut(date, value);
  }

  Future<void> _editNote(
    BuildContext context,
    DateTime date,
    String? current,
  ) async {
    final provider = context.read<OvertimeProvider>();
    final controller = TextEditingController(text: current ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑备注'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '例如：外出、请假、加班原因等',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final trimmed = result.trim();
    await provider.updateNote(date, trimmed.isEmpty ? null : trimmed);
  }

  Future<void> _deleteRecord(BuildContext context, DateTime date) async {
    final provider = context.read<OvertimeProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除记录'),
        content: Text('确定要删除 ${formatDate(date)} 的打卡记录吗？'),
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
      await provider.deleteDayRecord(date);
    }
  }
}

class _DateSelector extends StatelessWidget {
  const _DateSelector({
    required this.date,
    required this.isToday,
    required this.onPrevious,
    required this.onNext,
    required this.onPick,
  });

  final DateTime date;
  final bool isToday;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left),
          tooltip: '前一天',
        ),
        Expanded(
          child: TextButton.icon(
            onPressed: onPick,
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text(
              '${formatDayLabel(date)}${isToday ? '（今天）' : ''}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        IconButton(
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
          tooltip: '后一天',
        ),
      ],
    );
  }
}

class _PunchCard extends StatelessWidget {
  const _PunchCard({
    required this.onClockIn,
    required this.onClockOut,
    required this.onEditClockIn,
    required this.onEditClockOut,
    required this.hasClockIn,
    required this.hasClockOut,
  });

  final VoidCallback onClockIn;
  final VoidCallback onClockOut;
  final VoidCallback onEditClockIn;
  final VoidCallback onEditClockOut;
  final bool hasClockIn;
  final bool hasClockOut;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onClockIn,
                    icon: const Icon(Icons.login),
                    label: Text(hasClockIn ? '重新打上班卡' : '上班打卡'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: onClockOut,
                    icon: const Icon(Icons.logout),
                    label: Text(hasClockOut ? '重新打下班卡' : '下班打卡'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: onEditClockIn,
                    child: const Text('手动设置上班时间'),
                  ),
                ),
                Expanded(
                  child: TextButton(
                    onPressed: onEditClockOut,
                    child: const Text('手动设置下班时间'),
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

class _DailyInfoCard extends StatelessWidget {
  const _DailyInfoCard({required this.result, required this.date});

  final DailyResult result;
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final overtime = result.overtimeMinutes;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当日信息',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Divider(height: 20),
            _InfoRow(label: '类型', value: result.isWeekend ? '周末' : '工作日'),
            _InfoRow(label: '上班时间', value: formatTime(result.clockIn)),
            if (!result.isWeekend)
              _InfoRow(
                label: '应下班时间',
                value: formatTime(result.requiredClockOut),
              ),
            _InfoRow(label: '下班时间', value: formatTime(result.clockOut)),
            _InfoRow(
              label: '工作时长',
              value: result.clockOut == null
                  ? '--'
                  : formatMinutes(result.workMinutes),
            ),
            if (result.isWeekend)
              _InfoRow(
                label: '周末加班',
                value: formatMinutes(result.weekendOvertimeMinutes),
              )
            else
              _InfoRow(
                label: '工作日加班',
                value: formatMinutes(result.weekdayOvertimeMinutes),
              ),
            _InfoRow(
              label: '当日加班费',
              value: '${result.overtimePay.toStringAsFixed(2)} 元',
              valueColor: overtime > 0 ? scheme.primary : null,
            ),
            if (result.isLate)
              _InfoRow(
                label: '考勤',
                value: '迟到',
                valueColor: scheme.error,
              )
            else if (result.incomplete)
              _InfoRow(
                label: '考勤',
                value: '打卡不完整',
                valueColor: scheme.error,
              )
            else
              const _InfoRow(label: '考勤', value: '正常'),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note, required this.onEdit, this.onClear});

  final String? note;
  final VoidCallback onEdit;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.sticky_note_2_outlined),
        title: const Text('备注'),
        subtitle: Text(
          (note == null || note!.isEmpty) ? '暂无备注' : note!,
        ),
        trailing: Wrap(
          children: [
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑备注',
            ),
            if (onClear != null)
              IconButton(
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除当天记录',
              ),
          ],
        ),
      ),
    );
  }
}
