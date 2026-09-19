import 'package:flutter/material.dart';

/// 一个统计信息卡片。
///
/// 内部标签与数值均可收缩/缩放，避免在窄屏或小尺寸设备上溢出。
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.emphasis = false,
    this.icon,
  });

  final String label;
  final String value;
  final bool emphasis;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground =
        emphasis ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;

    return Card(
      margin: EdgeInsets.zero,
      elevation: emphasis ? 2 : 0,
      color: emphasis ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: foreground),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: emphasis ? scheme.onPrimaryContainer : scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
