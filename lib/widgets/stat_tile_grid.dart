import 'package:flutter/material.dart';

/// 自适应统计卡片栅格。
///
/// 根据可用宽度与 [minTileWidth] 自动决定列数（最多 [maxColumns] 列），
/// 在窄屏设备上自动降为 2 列或 1 列，避免内容溢出。
class StatTileGrid extends StatelessWidget {
  const StatTileGrid({
    super.key,
    required this.tiles,
    this.minTileWidth = 100,
    this.maxColumns = 4,
    this.spacing = 8,
  });

  final List<Widget> tiles;
  final double minTileWidth;
  final int maxColumns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        var columns = maxWidth ~/ minTileWidth;
        if (columns < 1) columns = 1;
        if (columns > maxColumns) columns = maxColumns;
        if (columns > tiles.length) columns = tiles.length;

        final tileWidth = (maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final tile in tiles)
              SizedBox(width: tileWidth, child: tile),
          ],
        );
      },
    );
  }
}
