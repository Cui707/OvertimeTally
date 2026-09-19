import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';

import '../core/date_x.dart';
import '../models/comp_record.dart';
import '../models/daily_result.dart';
import '../models/day_record.dart';
import 'export_naming_service.dart';
import 'overtime_calculator.dart';

/// 负责把某个月的数据导出为 `.xlsx`，并调用系统原生保存弹窗。
class ExcelExportService {
  ExcelExportService(
    this.calculator, {
    ExportNamingService? namingService,
  }) : _namingService = namingService ?? ExportNamingService();

  final OvertimeCalculator calculator;
  final ExportNamingService _namingService;

  static const String fileExtension = 'xlsx';

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

  /// 不含扩展名的基名，例如 `OvertimeTally_2026-09`。
  String monthFileBase(DateTime month) =>
      'OvertimeTally_${monthSheetName(month)}';

  /// 默认文件名，例如 `OvertimeTally_2026-09.xlsx`。
  String defaultFileName(DateTime month) =>
      '${monthFileBase(month)}.$fileExtension';

  /// 生成不会与已有文件冲突的文件名。
  ///
  /// 第二次导出同一月份时为 `OvertimeTally_2026-09（1）.xlsx`，
  /// 后缀始终位于扩展名之前。
  Future<String> nextFileName(DateTime month) => _namingService.suggestFileName(
        base: monthFileBase(month),
        extension: fileExtension,
      );

  /// 保存成功后记录一次，供下次生成递增后缀。
  Future<void> confirmSaved(DateTime month) =>
      _namingService.confirmSaved(base: monthFileBase(month));

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

    // 加班费按小时向下取整，且月度独立累计（不是把每日加班费相加）。
    final monthly = calculator.computeMonth(
      month: month,
      dayRecords: dayRecords,
      compRecords: compRecords,
    );

    sheet.appendRow(<CellValue?>[
      TextCellValue('合计'),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      IntCellValue(totalWeekday),
      IntCellValue(totalWeekend),
      IntCellValue(totalComp),
      DoubleCellValue(monthly.totalOvertimePay),
      TextCellValue('加班费按小时向下取整，按月独立累计'),
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
