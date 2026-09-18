/// 单日计算结果。
class DailyResult {
  const DailyResult({
    required this.date,
    required this.isWeekend,
    this.clockIn,
    this.clockOut,
    this.requiredClockOut,
    this.workMinutes = 0,
    this.weekdayOvertimeMinutes = 0,
    this.weekendOvertimeMinutes = 0,
    this.overtimePay = 0,
    this.isLate = false,
    this.incomplete = false,
    this.note,
  });

  /// 归属日。
  final DateTime date;

  /// 当天是否为周末。
  final bool isWeekend;

  final DateTime? clockIn;
  final DateTime? clockOut;

  /// 按规则推导出的应下班时间（仅工作日且有上班打卡时存在）。
  final DateTime? requiredClockOut;

  /// 实际工作时长（工作日已扣除午休，周末按全额）。
  final int workMinutes;

  /// 工作日加班分钟数。
  final int weekdayOvertimeMinutes;

  /// 周末加班分钟数。
  final int weekendOvertimeMinutes;

  /// 当日加班费（元，保留两位小数）。
  final double overtimePay;

  /// 是否迟到（仅工作日判定）。
  final bool isLate;

  /// 打卡是否不完整（缺少上班或下班时间）。
  final bool incomplete;

  final String? note;

  /// 当日加班总分钟数。
  int get overtimeMinutes => weekdayOvertimeMinutes + weekendOvertimeMinutes;

  /// 是否当天没有任何打卡记录。
  bool get isEmpty => clockIn == null && clockOut == null && !incomplete;

  @override
  String toString() => 'DailyResult($date, ot: $overtimeMinutes, pay: $overtimePay)';
}
