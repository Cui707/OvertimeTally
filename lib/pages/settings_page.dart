import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/date_x.dart';
import '../core/work_rules.dart';
import '../providers/overtime_provider.dart';

/// 规则设置页：自定义标准工时、费率与加班结算口径。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TimeOfDay _startTime;
  late final TextEditingController _delayController;
  late final TextEditingController _spanHoursController;
  late final TextEditingController _spanMinutesController;
  late final TextEditingController _weekdayRateController;
  late final TextEditingController _weekendRateController;
  late final TextEditingController _thresholdController;
  late final TextEditingController _payUnitController;

  @override
  void initState() {
    super.initState();
    _delayController = TextEditingController();
    _spanHoursController = TextEditingController();
    _spanMinutesController = TextEditingController();
    _weekdayRateController = TextEditingController();
    _weekendRateController = TextEditingController();
    _thresholdController = TextEditingController();
    _payUnitController = TextEditingController();
    _applyRules(context.read<OvertimeProvider>().rules);
  }

  /// 把规则写入表单（控制器已创建，只更新文本，避免重复初始化）。
  void _applyRules(WorkRules rules) {
    _startTime = TimeOfDay(
      hour: rules.standardStartMinutes ~/ 60,
      minute: rules.standardStartMinutes % 60,
    );
    _delayController.text = '${rules.allowedDelayMinutes}';
    _spanHoursController.text = '${rules.dailySpanMinutes ~/ 60}';
    _spanMinutesController.text = '${rules.dailySpanMinutes % 60}';
    _weekdayRateController.text = _trimNumber(rules.weekdayRatePerHour);
    _weekendRateController.text = _trimNumber(rules.weekendRatePerHour);
    _thresholdController.text = '${rules.overtimeThresholdMinutes}';
    _payUnitController.text = '${rules.payUnitMinutes}';
  }

  @override
  void dispose() {
    _delayController.dispose();
    _spanHoursController.dispose();
    _spanMinutesController.dispose();
    _weekdayRateController.dispose();
    _weekendRateController.dispose();
    _thresholdController.dispose();
    _payUnitController.dispose();
    super.dispose();
  }

  static String _trimNumber(double value) =>
      value == value.roundToDouble() ? '${value.toInt()}' : '$value';

  int get _startMinutes => _startTime.hour * 60 + _startTime.minute;

  int get _delayMinutes => int.tryParse(_delayController.text.trim()) ?? 0;

  int get _spanMinutes =>
      (int.tryParse(_spanHoursController.text.trim()) ?? 0) * 60 +
      (int.tryParse(_spanMinutesController.text.trim()) ?? 0);

  static String _hm(int minutes) {
    final normalized = ((minutes % (24 * 60)) + 24 * 60) % (24 * 60);
    return '${(normalized ~/ 60).toString().padLeft(2, '0')}:'
        '${(normalized % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
      helpText: '选择标准上班时间',
    );
    if (picked != null) setState(() => _startTime = picked);
  }

  Future<void> _save() async {
    final provider = context.read<OvertimeProvider>();
    final messenger = ScaffoldMessenger.of(context);

    final delay = int.tryParse(_delayController.text.trim());
    final weekdayRate = double.tryParse(_weekdayRateController.text.trim());
    final weekendRate = double.tryParse(_weekendRateController.text.trim());
    final threshold = int.tryParse(_thresholdController.text.trim());
    final payUnit = int.tryParse(_payUnitController.text.trim());
    final span = _spanMinutes;

    String? error;
    if (delay == null ||
        weekdayRate == null ||
        weekendRate == null ||
        threshold == null ||
        payUnit == null) {
      error = '请填写有效的数字';
    } else if (delay < 0) {
      error = '允许延迟上班时长不能为负数';
    } else if (span < provider.rules.requiredWorkMinutes) {
      error = '每日总跨度不能小于每日应工作时长（8 小时）';
    } else if (weekdayRate < 0 || weekendRate < 0) {
      error = '加班费率不能为负数';
    } else if (threshold < 0) {
      error = '加班起算时长不能为负数';
    } else if (payUnit < 1) {
      error = '加班费起算时长至少为 1 分钟';
    }

    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    await provider.updateRules(
      provider.rules.copyWith(
        standardStartMinutes: _startMinutes,
        allowedDelayMinutes: delay,
        dailySpanMinutes: span,
        weekdayRatePerHour: weekdayRate,
        weekendRatePerHour: weekendRate,
        overtimeThresholdMinutes: threshold,
        payUnitMinutes: payUnit,
      ),
    );
    messenger.showSnackBar(const SnackBar(content: Text('设置已保存，统计已按新规则重算')));
  }

  Future<void> _reset() async {
    final provider = context.read<OvertimeProvider>();
    final messenger = ScaffoldMessenger.of(context);
    await provider.resetRules();
    setState(() => _applyRules(provider.rules));
    messenger.showSnackBar(const SnackBar(content: Text('已恢复默认设置')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final requiredWork = context.watch<OvertimeProvider>().rules.requiredWorkMinutes;
    final lunch = _spanMinutes - requiredWork;

    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: true),
      body: ListView(
        // 设置页是独立全屏路由，没有底部导航栏兜住系统栏，
        // 这里补上系统底部安全区，避免最底下的按钮与系统导航栏重合。
        padding: EdgeInsets.fromLTRB(
          12,
          12,
          12,
          12 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          _SectionCard(
            title: '时间设置',
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('标准上班时间'),
                subtitle: Text(_hm(_startMinutes)),
                trailing: const Icon(Icons.access_time),
                onTap: _pickStartTime,
              ),
              const Divider(height: 1),
              _NumberField(
                controller: _delayController,
                label: '允许延迟上班时长（分钟）',
                onChanged: _onChanged,
              ),
              _NumberField(
                controller: _spanHoursController,
                label: '每日总跨度（小时）',
                onChanged: _onChanged,
              ),
              _NumberField(
                controller: _spanMinutesController,
                label: '每日总跨度（分钟）',
                onChanged: _onChanged,
              ),
            ],
          ),
          _PreviewCard(
            latestClockIn: _hm(_startMinutes + _delayMinutes),
            standardEnd: _hm(_startMinutes + _spanMinutes),
            lunch: lunch,
            span: _spanMinutes,
          ),
          _SectionCard(
            title: '加班费率',
            children: [
              _NumberField(
                controller: _weekdayRateController,
                label: '工作日加班费每时（元）',
                allowDecimal: true,
                onChanged: _onChanged,
              ),
              _NumberField(
                controller: _weekendRateController,
                label: '周末加班费每时（元）',
                allowDecimal: true,
                onChanged: _onChanged,
              ),
            ],
          ),
          _SectionCard(
            title: '加班结算',
            children: [
              _NumberField(
                controller: _thresholdController,
                label: '加班起算时长（分钟）',
                onChanged: _onChanged,
              ),
              _NumberField(
                controller: _payUnitController,
                label: '加班费起算时长（分钟）',
                onChanged: _onChanged,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '加班费 = (加班分钟 ÷ 加班费起算时长，向下取整) × 费率；'
                  '月度按工作日/周末分别累计后取整。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('保存设置'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.restore),
            label: const Text('恢复默认'),
          ),
        ],
      ),
    );
  }

  void _onChanged(String _) => setState(() {});
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.latestClockIn,
    required this.standardEnd,
    required this.lunch,
    required this.span,
  });

  final String latestClockIn;
  final String standardEnd;
  final int lunch;
  final int span;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '预览',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _row(theme, '最晚打卡上班', latestClockIn),
            _row(theme, '标准下班时间', standardEnd),
            _row(theme, '每日应工作', formatMinutes(8 * 60)),
            _row(
              theme,
              '午休时长',
              lunch >= 0 ? formatMinutes(lunch) : '不合法（总跨度小于 8 小时）',
            ),
            _row(theme, '每日总跨度', formatMinutes(span)),
          ],
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
          Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    required this.onChanged,
    this.allowDecimal = false,
  });

  final TextEditingController controller;
  final String label;
  final ValueChanged<String> onChanged;
  final bool allowDecimal;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.numberWithOptions(decimal: allowDecimal),
        inputFormatters: [
          FilteringTextInputFormatter.allow(
            allowDecimal ? RegExp(r'[0-9.]') : RegExp(r'[0-9]'),
          ),
        ],
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: onChanged,
      ),
    );
  }
}
