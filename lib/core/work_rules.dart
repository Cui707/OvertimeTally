/// 公司弹性工时与加班调休规则。
///
/// 标准上下班 08:15-17:30，总跨度 9 小时 15 分，其中 8 小时为工作时间，
/// 其余 1 小时 15 分为午休。上班最晚 09:15，晚于该时间视为迟到；
/// 无论是否迟到，当天都需做满 8 小时工作时间。
class WorkRules {
  const WorkRules({
    this.standardStartMinutes = 8 * 60 + 15,
    this.standardEndMinutes = 17 * 60 + 30,
    this.requiredWorkMinutes = 8 * 60,
    this.dailySpanMinutes = 9 * 60 + 15,
    this.latestClockInMinutes = 9 * 60 + 15,
    this.weekdayRatePerHour = 30,
    this.weekendRatePerHour = 40,
    this.overtimeThresholdMinutes = 30,
  });

  /// 标准上班时间（当天零点起的分钟数），08:15。
  final int standardStartMinutes;

  /// 标准下班时间，17:30。
  final int standardEndMinutes;

  /// 每天必须做满的工作分钟数，480 分钟。
  final int requiredWorkMinutes;

  /// 从上班到应下班的总跨度，555 分钟（含午休）。
  final int dailySpanMinutes;

  /// 最晚打卡上班时间，09:15。
  final int latestClockInMinutes;

  /// 工作日加班费率（元/小时）。
  final double weekdayRatePerHour;

  /// 周末加班费率（元/小时）。
  final double weekendRatePerHour;

  /// 触发加班计算的最小分钟数，30 分钟（含）。
  final int overtimeThresholdMinutes;

  /// 午休时长（分钟），由跨度减去工作时长得到。
  int get lunchBreakMinutes => dailySpanMinutes - requiredWorkMinutes;

  /// 默认规则。
  static const WorkRules standard = WorkRules();
}
