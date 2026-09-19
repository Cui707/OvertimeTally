/// 月度汇总结果。
class MonthlyStats {
  const MonthlyStats({
    required this.month,
    this.weekdayOvertimeMinutes = 0,
    this.weekendOvertimeMinutes = 0,
    this.compUsedMinutes = 0,
    this.weekdayRatePerHour = 30,
    this.weekendRatePerHour = 40,
    this.payUnitMinutes = 60,
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

  /// 加班费计费单位（分钟，向下取整）。
  final int payUnitMinutes;

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

  /// 当月工作日加班费（元）。
  ///
  /// 加班费按计费单位向下取整：先累计当月工作日加班分钟数，
  /// 再整体换算为整数个计费单位，而不是把每天的加班费相加，
  /// 这样每天不足一个计费单位的零头可以累计。
  double get weekdayOvertimePay =>
      _floorUnits(weekdayOvertimeMinutes) * weekdayRatePerHour;

  /// 当月周末加班费（元），已排除被调休抵扣的部分，同样向下取整。
  double get weekendOvertimePay =>
      _floorUnits(effectiveWeekendOvertimeMinutes) * weekendRatePerHour;

  /// 当月总加班费（元）。
  double get totalOvertimePay => weekdayOvertimePay + weekendOvertimePay;

  static MonthlyStats empty(DateTime month) => MonthlyStats(month: month);

  int _floorUnits(int minutes) {
    if (minutes <= 0) return 0;
    final unit = payUnitMinutes <= 0 ? 60 : payUnitMinutes;
    return minutes ~/ unit;
  }

  @override
  String toString() =>
      'MonthlyStats($month, total: $totalOvertimeMinutes, pay: $totalOvertimePay)';
}
