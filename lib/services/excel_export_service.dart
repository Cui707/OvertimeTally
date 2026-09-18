import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';

import '../core/date_x.dart';
import '../models/comp_record.dart';
import '../models/daily_result.dart';
import '../models/day_record.dart';
import 'overtime_calculator.dart';

/// 负责把某个月的数据导出为 `.xlsx`，并调用系统原生保存弹窗。
class ExcelExportService {
  const ExcelExportService(this.calculator);

  final OvertimeCalculator calculator;

  static const List<String> headers = <String>[
    '日期',
    '星期',
    '上班时间',
    '下班时间',
    '工作日加班(分)',
    '周末加班(分)',
    '调休时长(分)',
    '当日加班费(元)',
    '备注',
  ];

  /// 工作表名称，例如 `2026-09`。
  String monthSheetName(DateTime month) =>
      '${month.year.toString().padLeft(4, '0')}-'
      '${month.month.toString().padLeft(2, '0')}';

  /// 默认文件名，例如 `OvertimeTally_2026-09.xlsx`。
  String defaultFileName(DateTime month) =>
      'OvertimeTally_${monthSheetName(month)}.xlsx';

  /// 生成工作簿字节内容。
  List<int> buildWorkbook({
    required DateTime month,
    required List<DayRecord> dayRecords,
    required List<CompRecord> compRecords,
  }) {
    final excel = Excel.createExcel();
    final sheetName = monthSheetName(month);
    final sheet = excel[sheetName];
    final defaultSheet = excel.getDefaultSheet();
    if (defaultSheet != null && defaultSheet != sheetName) {
      excel.delete(defaultSheet);
    }

    sheet.appendRow(
      headers.map<CellValue?>(TextCellValue.new).toList(),
    );

    final recordByDate = <String, DayRecord>{
      for (final record in dayRecords) formatDate(record.workDate): record,
    };
    final compByDate = <String, int>{};
    for (final comp in compRecords) {
      final key = formatDate(comp.date);
      compByDate[key] = (compByDate[key] ?? 0) + comp.minutes;
    }

    final keys = <String>{...recordByDate.keys, ...compByDate.keys}.toList()
      ..sort();

    var totalWeekday = 0;
    var totalWeekend = 0;
    var totalComp = 0;
    var totalPay = 0.0;

    for (final key in keys) {
      final record = recordByDate[key];
      final date = record?.workDate ?? DateTime.parse(key);
      final result = calculator.computeDay(
        record ?? DayRecord(workDate: date),
      );
      final compMinutes = compByDate[key] ?? 0;

      totalWeekday += result.weekdayOvertimeMinutes;
      totalWeekend += result.weekendOvertimeMinutes;
      totalComp += compMinutes;
      totalPay += result.overtimePay;

      sheet.appendRow(<CellValue?>[
        TextCellValue(formatDate(date)),
        TextCellValue(weekdayLabel(date)),
        TextCellValue(formatTime(result.clockIn)),
        TextCellValue(formatTime(result.clockOut)),
        IntCellValue(result.weekdayOvertimeMinutes),
        IntCellValue(result.weekendOvertimeMinutes),
        IntCellValue(compMinutes),
        DoubleCellValue(result.overtimePay),
        TextCellValue(_buildNote(result, compMinutes)),
      ]);
    }

    sheet.appendRow(<CellValue?>[
      TextCellValue('合计'),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      IntCellValue(totalWeekday),
      IntCellValue(totalWeekend),
      IntCellValue(totalComp),
      DoubleCellValue(OvertimeCalculator.round2(totalPay)),
      TextCellValue(''),
    ]);

    final bytes = excel.encode();
    return bytes ?? const <int>[];
  }

  /// 弹出系统原生保存对话框并写入文件，返回保存路径（取消时返回 null）。
  Future<String?> save({
    required List<int> bytes,
    required String fileName,
  }) {
    return FilePicker.platform.saveFile(
      dialogTitle: '保存 Excel 文件',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const <String>['xlsx'],
      bytes: Uint8List.fromList(bytes),
    );
  }

  String _buildNote(DailyResult result, int compMinutes) {
    final parts = <String>[];
    if (result.isLate) parts.add('迟到');
    if (result.incomplete) parts.add('打卡不完整');
    if (compMinutes > 0) parts.add('调休 ${formatMinutes(compMinutes)}');
    final note = result.note;
    if (note != null && note.trim().isNotEmpty) parts.add(note.trim());
    return parts.join('；');
  }
}
