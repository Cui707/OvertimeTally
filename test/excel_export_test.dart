import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overtime_tally/models/comp_record.dart';
import 'package:overtime_tally/models/day_record.dart';
import 'package:overtime_tally/services/excel_export_service.dart';
import 'package:overtime_tally/services/export_naming_service.dart';
import 'package:overtime_tally/services/overtime_calculator.dart';

double _cellNumber(List<Data?> row, int index) =>
    double.parse(row[index]!.value.toString());

void main() {
  final service = ExcelExportService(const OvertimeCalculator());

  test('导出重名时后缀位于扩展名之前，且扩展名保持为 .xlsx', () async {
    final directory =
        await Directory.systemTemp.createTemp('overtime_tally_naming');
    addTearDown(() => directory.delete(recursive: true));
    final naming = ExportNamingService(
      directoryProvider: () async => directory,
    );

    expect(
      await naming.suggestFileName(
        base: 'OvertimeTally_2026-09',
        extension: 'xlsx',
      ),
      'OvertimeTally_2026-09.xlsx',
    );

    await naming.confirmSaved(base: 'OvertimeTally_2026-09');
    expect(
      await naming.suggestFileName(
        base: 'OvertimeTally_2026-09',
        extension: 'xlsx',
      ),
      'OvertimeTally_2026-09（1）.xlsx',
    );

    await naming.confirmSaved(base: 'OvertimeTally_2026-09');
    final third = await naming.suggestFileName(
      base: 'OvertimeTally_2026-09',
      extension: 'xlsx',
    );
    expect(third, 'OvertimeTally_2026-09（2）.xlsx');
    expect(third.endsWith('.xlsx'), isTrue);
    expect(third.contains('.xlsx（'), isFalse);
  });

  test('不同月份的导出计数互相独立', () async {
    final directory =
        await Directory.systemTemp.createTemp('overtime_tally_naming');
    addTearDown(() => directory.delete(recursive: true));
    final naming = ExportNamingService(
      directoryProvider: () async => directory,
    );

    await naming.confirmSaved(base: 'OvertimeTally_2026-09');
    expect(
      await naming.suggestFileName(
        base: 'OvertimeTally_2026-10',
        extension: 'xlsx',
      ),
      'OvertimeTally_2026-10.xlsx',
    );
    expect(
      await naming.suggestFileName(
        base: 'OvertimeTally_2026-09',
        extension: 'xlsx',
      ),
      'OvertimeTally_2026-09（1）.xlsx',
    );
  });

  test('导出的工作簿包含表头、每日数据与合计行', () {
    final bytes = service.buildWorkbook(
      month: DateTime(2026, 9),
      dayRecords: [
        DayRecord(
          workDate: DateTime(2026, 9, 14),
          clockIn: DateTime(2026, 9, 14, 8, 15),
          clockOut: DateTime(2026, 9, 14, 18, 0),
        ),
        DayRecord(
          workDate: DateTime(2026, 9, 12),
          clockIn: DateTime(2026, 9, 12, 9, 0),
          clockOut: DateTime(2026, 9, 12, 15, 0),
        ),
      ],
      compRecords: [CompRecord(date: DateTime(2026, 9, 12), minutes: 60)],
    );

    expect(bytes, isNotEmpty);

    final excel = Excel.decodeBytes(bytes);
    final sheet = excel['2026-09'];
    final rows = sheet.rows;

    expect(
      rows.first.map((cell) => cell?.value.toString()).toList(),
      ExcelExportService.headers,
    );

    final weekendRow = rows.firstWhere(
      (row) => row[0]?.value.toString() == '2026-09-12',
    );
    expect(weekendRow[1]?.value.toString(), '周六');
    expect(_cellNumber(weekendRow, 4), 0);
    expect(_cellNumber(weekendRow, 5), 360);
    expect(_cellNumber(weekendRow, 6), 60);
    expect(_cellNumber(weekendRow, 7), 240);

    final workdayRow = rows.firstWhere(
      (row) => row[0]?.value.toString() == '2026-09-14',
    );
    expect(workdayRow[1]?.value.toString(), '周一');
    expect(_cellNumber(workdayRow, 4), 30);
    // 30 分钟不足 1 小时，单日加班费为 0。
    expect(_cellNumber(workdayRow, 7), 0);

    final totalRow = rows.firstWhere(
      (row) => row[0]?.value.toString() == '合计',
    );
    expect(_cellNumber(totalRow, 4), 30);
    expect(_cellNumber(totalRow, 5), 360);
    expect(_cellNumber(totalRow, 6), 60);
    // 合计加班费按月独立累计：工作日 0 小时 + 周末有效 300 分钟(5 小时) × 40 = 200 元。
    expect(_cellNumber(totalRow, 7), 200);
  });

  test('默认文件名与工作表名', () {
    expect(service.monthSheetName(DateTime(2026, 9)), '2026-09');
    expect(service.defaultFileName(DateTime(2026, 9)), 'OvertimeTally_2026-09.xlsx');
  });
}
