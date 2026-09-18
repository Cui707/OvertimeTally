import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/date_x.dart';
import '../models/comp_record.dart';
import '../providers/overtime_provider.dart';
import '../widgets/month_picker_bar.dart';
import '../widgets/stat_tile.dart';

/// 调休信息与录入页面。
class CompTimePage extends StatelessWidget {
  const CompTimePage({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<OvertimeProvider>();
    final stats = provider.stats;
    final records = provider.compRecords;

    return Column(
      children: [
        MonthPickerBar(
          month: provider.selectedMonth,
          onPrevious: provider.goToPreviousMonth,
          onNext: provider.goToNextMonth,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: StatTile(
                  label: '可用调休',
                  value: formatHours(stats.compAvailableMinutes),
                  icon: Icons.card_giftcard,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StatTile(
                  label: '已调休',
                  value: formatHours(stats.compUsedMinutes),
                  icon: Icons.event_available,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: StatTile(
                  label: '剩余',
                  value: formatHours(stats.remainingCompMinutes),
                  icon: Icons.hourglass_bottom,
                  emphasis: true,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openEditor(context, null),
              icon: const Icon(Icons.add),
              label: const Text('新增调休记录'),
            ),
          ),
        ),
        Expanded(
          child: records.isEmpty
              ? const Center(child: Text('本月暂无调休记录'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: records.length,
                  itemBuilder: (context, index) {
                    final record = records[index];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.beach_access_outlined),
                        title: Text(
                          '${formatDate(record.date)} ${weekdayLabel(record.date)}',
                        ),
                        subtitle: Text(
                          record.note == null || record.note!.isEmpty
                              ? formatMinutes(record.minutes)
                              : '${formatMinutes(record.minutes)} · ${record.note}',
                        ),
                        trailing: Wrap(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: '编辑',
                              onPressed: () => _openEditor(context, record),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: '删除',
                              onPressed: () => _confirmDelete(context, record),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _openEditor(BuildContext context, CompRecord? existing) async {
    final provider = context.read<OvertimeProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final input = await showDialog<_CompInput>(
      context: context,
      builder: (dialogContext) => _CompDialog(
        initialDate: existing?.date ?? provider.selectedDate,
        initialMinutes: existing?.minutes ?? 0,
        initialNote: existing?.note,
        isEditing: existing != null,
      ),
    );
    if (input == null) return;

    try {
      if (existing == null) {
        await provider.addCompRecord(
          date: input.date,
          minutes: input.minutes,
          note: input.note,
        );
      } else {
        await provider.updateCompRecord(
          existing.copyWith(
            date: input.date,
            minutes: input.minutes,
            note: input.note,
          ),
        );
      }
      messenger.showSnackBar(const SnackBar(content: Text('调休记录已保存')));
    } on CompTimeExceededException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _confirmDelete(BuildContext context, CompRecord record) async {
    final provider = context.read<OvertimeProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除调休记录'),
        content: Text('确定要删除 ${formatDate(record.date)} 的调休记录吗？'),
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
    if ((confirmed ?? false) && record.id != null) {
      await provider.deleteCompRecord(record.id!);
    }
  }
}

class _CompInput {
  const _CompInput({required this.date, required this.minutes, this.note});

  final DateTime date;
  final int minutes;
  final String? note;
}

class _CompDialog extends StatefulWidget {
  const _CompDialog({
    required this.initialDate,
    required this.initialMinutes,
    required this.isEditing,
    this.initialNote,
  });

  final DateTime initialDate;
  final int initialMinutes;
  final bool isEditing;
  final String? initialNote;

  @override
  State<_CompDialog> createState() => _CompDialogState();
}

class _CompDialogState extends State<_CompDialog> {
  late DateTime _date;
  late final TextEditingController _hoursController;
  late final TextEditingController _minutesController;
  late final TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    _date = widget.initialDate;
    _hoursController =
        TextEditingController(text: (widget.initialMinutes ~/ 60).toString());
    _minutesController =
        TextEditingController(text: (widget.initialMinutes % 60).toString());
    _noteController = TextEditingController(text: widget.initialNote ?? '');
  }

  @override
  void dispose() {
    _hoursController.dispose();
    _minutesController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  int get _totalMinutes {
    final hours = int.tryParse(_hoursController.text.trim()) ?? 0;
    final minutes = int.tryParse(_minutesController.text.trim()) ?? 0;
    return hours * 60 + minutes;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
      helpText: '选择调休日期',
    );
    if (picked != null) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEditing ? '编辑调休记录' : '新增调休记录'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_today, size: 18),
              label: Text('${formatDate(_date)} ${weekdayLabel(_date)}'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _hoursController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '小时',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _minutesController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '分钟',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '合计：${formatMinutes(_totalMinutes)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '备注（可选）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _totalMinutes <= 0
              ? null
              : () {
                  final note = _noteController.text.trim();
                  Navigator.of(context).pop(
                    _CompInput(
                      date: dateOnly(_date),
                      minutes: _totalMinutes,
                      note: note.isEmpty ? null : note,
                    ),
                  );
                },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
