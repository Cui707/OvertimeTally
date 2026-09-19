import '../core/date_x.dart';
import '../core/work_rules.dart';
import '../models/comp_record.dart';
import '../models/daily_result.dart';
import '../models/day_record.dart';
import '../models/monthly_stats.dart';

/// 加班与调休计算引擎（纯函数，便于单元测试）。
class OvertimeCalculator {
  const OvertimeCalculator([this.rules = WorkRules.standard]);

  final WorkRules rules;

  /// 计算单日结果。
  ///
  /// 规则：
  /// - 工作日应下班 = 上班时间 + 每日总跨度（迟到同样做满 8 小时）；
  /// - 工作日超过应下班且达到「加班起算时长」才计加班，且按实际分钟全额计入；
  /// - 周末当天工作时长全额计为周末加班；
  /// - 跨零点下班按次日处理；
  /// - 加班费按「加班费起算时长」向下取整结算（不足一个计费单位不计费），
  ///   例如计费单位为 60 分钟时，加班 59 分钟为 0 元、70 分钟为 1 小时。
  DailyResult computeDay(DayRecord record) {
    final date = dateOnly(record.workDate);
    final weekend = isWeekend(date);
    final clockIn = record.clockIn;
    var clockOut = record.clockOut;

    if (clockIn == null) {
      return DailyResult(
        date: date,
        isWeekend: weekend,
        clockOut: clockOut,
        incomplete: clockOut != null,
        note: record.note,
      );
    }

    if (clockOut != null && !clockOut.isAfter(clockIn)) {
      clockOut = clockOut.add(const Duration(days: 1));
    }

    final late = !weekend && minutesOfDay(clockIn) > rules.latestClockInMinutes;
    final requiredClockOut =
        clockIn.add(Duration(minutes: rules.dailySpanMinutes));

    if (clockOut == null) {
      return DailyResult(
        date: date,
        isWeekend: weekend,
        clockIn: clockIn,
        requiredClockOut: weekend ? null : requiredClockOut,
        incomplete: true,
        isLate: late,
        note: record.note,
      );
    }

    final span = clockOut.difference(clockIn).inMinutes;

    if (weekend) {
      final overtime = span > 0 ? span : 0;
      return DailyResult(
        date: date,
        isWeekend: true,
        clockIn: clockIn,
        clockOut: clockOut,
        workMinutes: overtime,
        weekendOvertimeMinutes: overtime,
        overtimePay: _floorUnits(overtime) * rules.weekendRatePerHour,
        note: record.note,
      );
    }

    final workMinutes = (span - rules.lunchBreakMinutes) > 0
        ? span - rules.lunchBreakMinutes
        : 0;
    final rawOvertime = clockOut.difference(requiredClockOut).inMinutes;
    final overtime =
        rawOvertime >= rules.overtimeThresholdMinutes ? rawOvertime : 0;

    return DailyResult(
      date: date,
      isWeekend: false,
      clockIn: clockIn,
      clockOut: clockOut,
      requiredClockOut: requiredClockOut,
      workMinutes: workMinutes,
      weekdayOvertimeMinutes: overtime,
      overtimePay: _floorUnits(overtime) * rules.weekdayRatePerHour,
      isLate: late,
      note: record.note,
    );
  }

  /// 计算月度汇总。调休会抵扣周末加班，被抵扣部分不计入总加班与加班费。
  MonthlyStats computeMonth({
    required DateTime month,
    required List<DayRecord> dayRecords,
    required List<CompRecord> compRecords,
  }) {
    var weekday = 0;
    var weekend = 0;
    for (final record in dayRecords) {
      if (!isSameMonth(record.workDate, month)) continue;
      final result = computeDay(record);
      weekday += result.weekdayOvertimeMinutes;
      weekend += result.weekendOvertimeMinutes;
    }

    var used = 0;
    for (final comp in compRecords) {
      if (!isSameMonth(comp.date, month)) continue;
      used += comp.minutes;
    }

    return MonthlyStats(
      month: firstDayOfMonth(month),
      weekdayOvertimeMinutes: weekday,
      weekendOvertimeMinutes: weekend,
      compUsedMinutes: used,
      weekdayRatePerHour: rules.weekdayRatePerHour,
      weekendRatePerHour: rules.weekendRatePerHour,
      payUnitMinutes: rules.payUnitMinutes,
    );
  }

  /// 保留两位小数。
  static double round2(double value) => double.parse(value.toStringAsFixed(2));

  /// 按计费单位向下取整：返回分钟数包含的完整计费单位个数。
  int _floorUnits(int minutes) {
    if (minutes <= 0) return 0;
    final unit = rules.payUnitMinutes <= 0 ? 60 : rules.payUnitMinutes;
    return minutes ~/ unit;
  }
}
