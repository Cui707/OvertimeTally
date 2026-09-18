import 'package:flutter/foundation.dart';

import '../core/date_x.dart';
import '../data/overtime_repository.dart';
import '../models/comp_record.dart';
import '../models/daily_result.dart';
import '../models/day_record.dart';
import '../models/monthly_stats.dart';
import '../services/excel_export_service.dart';
import '../services/overtime_calculator.dart';

/// 调休时长超出当月可用额度时抛出。
class CompTimeExceededException implements Exception {
  CompTimeExceededException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 全局状态：选中月份/日期、打卡记录、调休记录与统计结果。
class OvertimeProvider extends ChangeNotifier {
  OvertimeProvider({
    required OvertimeRepository repository,
    OvertimeCalculator? calculator,
    ExcelExportService? exportService,
    DateTime Function()? now,
  })  : _repository = repository,
        _calculator = calculator ?? const OvertimeCalculator(),
        _exportService = exportService ??
            ExcelExportService(calculator ?? const OvertimeCalculator()),
        _now = now ?? DateTime.now {
    final today = dateOnly(_now());
    _selectedDate = today;
    _selectedMonth = firstDayOfMonth(today);
    _stats = MonthlyStats.empty(_selectedMonth);
  }

  final OvertimeRepository _repository;
  final OvertimeCalculator _calculator;
  final ExcelExportService _exportService;
  final DateTime Function() _now;

  bool _loading = true;
  late DateTime _selectedMonth;
  late DateTime _selectedDate;
  List<DayRecord> _dayRecords = const <DayRecord>[];
  List<CompRecord> _compRecords = const <CompRecord>[];
  late MonthlyStats _stats;
  String? _errorMessage;

  bool get loading => _loading;
  DateTime get selectedMonth => _selectedMonth;
  DateTime get selectedDate => _selectedDate;
  List<DayRecord> get dayRecords => List.unmodifiable(_dayRecords);
  List<CompRecord> get compRecords => List.unmodifiable(_compRecords);
  MonthlyStats get stats => _stats;
  String? get errorMessage => _errorMessage;

  /// 指定归属日的记录。
  DayRecord? recordForDate(DateTime date) {
    for (final record in _dayRecords) {
      if (isSameDate(record.workDate, date)) return record;
    }
    return null;
  }

  /// 指定归属日的计算结果。
  DailyResult resultForDate(DateTime date) {
    final record = recordForDate(date);
    return _calculator.computeDay(
      record ?? DayRecord(workDate: dateOnly(date)),
    );
  }

  /// 当前选中日期的计算结果。
  DailyResult get selectedDayResult => resultForDate(_selectedDate);

  /// 指定日期的调休记录。
  List<CompRecord> compRecordsForDate(DateTime date) =>
      _compRecords.where((record) => isSameDate(record.date, date)).toList();

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }

  /// 首次加载。
  Future<void> load() async {
    _loading = true;
    notifyListeners();
    await _reload();
    _loading = false;
    notifyListeners();
  }

  Future<void> _reload() async {
    try {
      _dayRecords = await _repository.dayRecordsInMonth(_selectedMonth);
      _compRecords = await _repository.compRecordsInMonth(_selectedMonth);
      _stats = _calculator.computeMonth(
        month: _selectedMonth,
        dayRecords: _dayRecords,
        compRecords: _compRecords,
      );
      _errorMessage = null;
    } catch (error) {
      _errorMessage = error.toString();
    }
  }

  Future<void> selectMonth(DateTime month) async {
    _selectedMonth = firstDayOfMonth(month);
    if (!isSameMonth(_selectedDate, _selectedMonth)) {
      _selectedDate = _selectedMonth;
    }
    await _reload();
    notifyListeners();
  }

  Future<void> selectDate(DateTime date) async {
    _selectedDate = dateOnly(date);
    if (!isSameMonth(_selectedDate, _selectedMonth)) {
      _selectedMonth = firstDayOfMonth(_selectedDate);
      await _reload();
    }
    notifyListeners();
  }

  Future<void> goToPreviousMonth() => selectMonth(
        DateTime(_selectedMonth.year, _selectedMonth.month - 1, 1),
      );

  Future<void> goToNextMonth() => selectMonth(
        DateTime(_selectedMonth.year, _selectedMonth.month + 1, 1),
      );

  Future<void> goToPreviousDay() =>
      selectDate(_selectedDate.subtract(const Duration(days: 1)));

  Future<void> goToNextDay() =>
      selectDate(_selectedDate.add(const Duration(days: 1)));

  /// 记录上班打卡（使用系统实时时间）。
  Future<void> clockIn() async {
    final now = _now();
    final today = dateOnly(now);
    final existing = await _repository.dayRecordFor(today);
    if (existing != null && existing.hasClockIn) {
      _errorMessage = '今天已经打过上班卡了';
      notifyListeners();
      return;
    }
    final record =
        (existing ?? DayRecord(workDate: today)).copyWith(clockIn: now);
    await _repository.upsertDayRecord(record);
    await _refreshAfterMutation(today);
  }

  /// 记录下班打卡。若存在未下班的记录（如跨零点），自动关联到该天。
  Future<void> clockOut() async {
    final now = _now();
    final open = await _repository.findOpenRecord();
    final targetDate = open?.workDate ?? dateOnly(now);
    final record = open ??
        (await _repository.dayRecordFor(targetDate)) ??
        DayRecord(workDate: targetDate);
    await _repository.upsertDayRecord(record.copyWith(clockOut: now));
    await _refreshAfterMutation(targetDate);
  }

  Future<void> updateClockIn(DateTime date, DateTime? clockIn) async {
    final record = await _repository.dayRecordFor(date) ??
        DayRecord(workDate: dateOnly(date));
    await _repository.upsertDayRecord(record.copyWith(clockIn: clockIn));
    await _refreshAfterMutation(date);
  }

  Future<void> updateClockOut(DateTime date, DateTime? clockOut) async {
    final record = await _repository.dayRecordFor(date) ??
        DayRecord(workDate: dateOnly(date));
    await _repository.upsertDayRecord(record.copyWith(clockOut: clockOut));
    await _refreshAfterMutation(date);
  }

  Future<void> updateNote(DateTime date, String? note) async {
    final record = await _repository.dayRecordFor(date) ??
        DayRecord(workDate: dateOnly(date));
    await _repository.upsertDayRecord(record.copyWith(note: note));
    await _refreshAfterMutation(date);
  }

  Future<void> deleteDayRecord(DateTime date) async {
    await _repository.deleteDayRecord(date);
    await _refreshAfterMutation(date);
  }

  /// 新增调休记录，超出可用额度时抛出 [CompTimeExceededException]。
  Future<void> addCompRecord({
    required DateTime date,
    required int minutes,
    String? note,
  }) async {
    await _saveCompRecord(
      CompRecord(date: dateOnly(date), minutes: minutes, note: note),
    );
  }

  /// 更新调休记录。
  Future<void> updateCompRecord(CompRecord record) async {
    await _saveCompRecord(record);
  }

  /// 删除调休记录。
  Future<void> deleteCompRecord(int id) async {
    await _repository.deleteCompRecord(id);
    await _reload();
    notifyListeners();
  }

  Future<void> _saveCompRecord(CompRecord record) async {
    if (record.minutes <= 0) {
      throw CompTimeExceededException('调休时长必须大于 0 分钟');
    }

    final targetMonth = firstDayOfMonth(record.date);
    if (!isSameMonth(targetMonth, _selectedMonth)) {
      _selectedMonth = targetMonth;
      await _reload();
    }

    final available = _weekendOvertimeMinutesFor(targetMonth);
    var usedByOthers = 0;
    for (final comp in _compRecords) {
      if (record.id != null && comp.id == record.id) continue;
      usedByOthers += comp.minutes;
    }
    final remaining = available - usedByOthers;
    if (record.minutes > remaining) {
      throw CompTimeExceededException(
        '调休时长超出当月可用额度，最多还能调休 '
        '${formatMinutes(remaining < 0 ? 0 : remaining)}',
      );
    }

    await _repository.upsertCompRecord(record);
    await _reload();
    notifyListeners();
  }

  int _weekendOvertimeMinutesFor(DateTime month) {
    var total = 0;
    for (final record in _dayRecords) {
      if (!isSameMonth(record.workDate, month)) continue;
      total += _calculator.computeDay(record).weekendOvertimeMinutes;
    }
    return total;
  }

  /// 导出当前选中月份为 Excel，返回保存路径（取消时返回 null）。
  Future<String?> exportSelectedMonth() {
    final bytes = _exportService.buildWorkbook(
      month: _selectedMonth,
      dayRecords: _dayRecords,
      compRecords: _compRecords,
    );
    return _exportService.save(
      bytes: bytes,
      fileName: _exportService.defaultFileName(_selectedMonth),
    );
  }

  Future<void> _refreshAfterMutation(DateTime affectedDate) async {
    _selectedDate = dateOnly(affectedDate);
    if (!isSameMonth(_selectedDate, _selectedMonth)) {
      _selectedMonth = firstDayOfMonth(_selectedDate);
    }
    await _reload();
    notifyListeners();
  }
}
