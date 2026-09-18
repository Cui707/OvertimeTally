import 'package:flutter/material.dart';

import '../core/date_x.dart';

/// 月份切换栏：左右箭头 + 当前月份。
class MonthPickerBar extends StatelessWidget {
  const MonthPickerBar({
    super.key,
    required this.month,
    required this.onPrevious,
    required this.onNext,
  });

  final DateTime month;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left),
            tooltip: '上个月',
          ),
          Expanded(
            child: Center(
              child: Text(
                formatMonthLabel(month),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
            tooltip: '下个月',
          ),
        ],
      ),
    );
  }
}
