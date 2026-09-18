/// 月度汇总结果。
class MonthlyStats {
  const MonthlyStats({
    required this.month,
    this.weekdayOvertimeMinutes = 0,
    this.weekendOvertimeMinutes = 0,
    this.compUsedMinutes = 0,
    this.weekdayRatePerHour = 30,
    this.weekendRatePerHour = 40,
  });

  /// 所属月份（当月第一天）。
  final DateTime month;

  /// 工作日加班总分钟数。
  final int weekdayOvertimeMinutes;

  /// 周末加班总分钟数（未扣调休的毛值，也就是可用于调休的总额度）。
  final int weekendOvertimeMinutes;

  /// 当月已使用的调休分钟数。
  final int compUsedMinutes;

  /// 工作日加班费率（元/小时）。
  final double weekdayRatePerHour;

  /// 周末加班费率（元/小时）。
  final double weekendRatePerHour;

  /// 当月可用于调休的总时长（来自周末加班）。
  int get compAvailableMinutes => weekendOvertimeMinutes;

  /// 扣除调休后，剩余可调休时长。
  int get remainingCompMinutes {
    final remaining = weekendOvertimeMinutes - compUsedMinutes;
    return remaining < 0 ? 0 : remaining;
  }

  /// 被调休抵扣后仍需计入加班统计的周末加班时长。
  int get effectiveWeekendOvertimeMinutes {
    final effective = weekendOvertimeMinutes - compUsedMinutes;
    return effective < 0 ? 0 : effective;
  }

  /// 当月总加班时长（工作日加班 + 未被调休抵扣的周末加班）。
  int get totalOvertimeMinutes =>
      weekdayOvertimeMinutes + effectiveWeekendOvertimeMinutes;

  /// 工作日加班费（元）。
  double get weekdayOvertimePay =>
      _round2(weekdayOvertimeMinutes / 60 * weekdayRatePerHour);

  /// 周末加班费（元），已排除被调休抵扣的部分。
  double get weekendOvertimePay =>
      _round2(effectiveWeekendOvertimeMinutes / 60 * weekendRatePerHour);

  /// 当月总加班费（元，保留两位小数）。
  double get totalOvertimePay => _round2(weekdayOvertimePay + weekendOvertimePay);

  static MonthlyStats empty(DateTime month) => MonthlyStats(month: month);

  static double _round2(double value) =>
      double.parse(value.toStringAsFixed(2));

  @override
  String toString() =>
      'MonthlyStats($month, total: $totalOvertimeMinutes, pay: $totalOvertimePay)';
}
