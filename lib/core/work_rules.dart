/// 公司弹性工时与加班调休规则。
///
/// 默认：标准上班 08:15，允许延迟 60 分钟（最晚 09:15 打卡），
/// 每日总跨度 9 小时 15 分（含午休），其中 8 小时为工作时间、1 小时 15 分为午休。
/// 无论是否迟到，当天都需做满 8 小时工作时间。
///
/// 这些参数可在「设置」页面自定义并持久化。
class WorkRules {
  const WorkRules({
    this.standardStartMinutes = 8 * 60 + 15,
    this.allowedDelayMinutes = 60,
    this.requiredWorkMinutes = 8 * 60,
    this.dailySpanMinutes = 9 * 60 + 15,
    this.weekdayRatePerHour = 30,
    this.weekendRatePerHour = 40,
    this.overtimeThresholdMinutes = 30,
    this.payUnitMinutes = 60,
  });

  /// 标准上班时间（当天零点起的分钟数），默认 08:15。
  final int standardStartMinutes;

  /// 允许延迟上班的分钟数，默认 60（最晚打卡 = 标准上班 + 该值）。
  final int allowedDelayMinutes;

  /// 每天必须做满的工作分钟数，默认 480（8 小时）。
  final int requiredWorkMinutes;

  /// 从上班到应下班的总跨度（含午休），默认 555（9 小时 15 分）。
  final int dailySpanMinutes;

  /// 工作日加班费率（元/小时），默认 30。
  final double weekdayRatePerHour;

  /// 周末加班费率（元/小时），默认 40。
  final double weekendRatePerHour;

  /// 触发加班计算的最小分钟数（含），默认 30。
  final int overtimeThresholdMinutes;

  /// 加班费计费单位（分钟，向下取整），默认 60。
  ///
  /// 加班费 = (加班分钟 ÷ 该值，向下取整) × 费率。
  final int payUnitMinutes;

  /// 最晚打卡上班时间 = 标准上班 + 允许延迟。
  int get latestClockInMinutes => standardStartMinutes + allowedDelayMinutes;

  /// 标准下班时间 = 标准上班 + 每日总跨度。
  int get standardEndMinutes => standardStartMinutes + dailySpanMinutes;

  /// 午休时长 = 每日总跨度 - 每日应工作。
  int get lunchBreakMinutes => dailySpanMinutes - requiredWorkMinutes;

  WorkRules copyWith({
    int? standardStartMinutes,
    int? allowedDelayMinutes,
    int? requiredWorkMinutes,
    int? dailySpanMinutes,
    double? weekdayRatePerHour,
    double? weekendRatePerHour,
    int? overtimeThresholdMinutes,
    int? payUnitMinutes,
  }) {
    return WorkRules(
      standardStartMinutes: standardStartMinutes ?? this.standardStartMinutes,
      allowedDelayMinutes: allowedDelayMinutes ?? this.allowedDelayMinutes,
      requiredWorkMinutes: requiredWorkMinutes ?? this.requiredWorkMinutes,
      dailySpanMinutes: dailySpanMinutes ?? this.dailySpanMinutes,
      weekdayRatePerHour: weekdayRatePerHour ?? this.weekdayRatePerHour,
      weekendRatePerHour: weekendRatePerHour ?? this.weekendRatePerHour,
      overtimeThresholdMinutes:
          overtimeThresholdMinutes ?? this.overtimeThresholdMinutes,
      payUnitMinutes: payUnitMinutes ?? this.payUnitMinutes,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'standardStartMinutes': standardStartMinutes,
        'allowedDelayMinutes': allowedDelayMinutes,
        'requiredWorkMinutes': requiredWorkMinutes,
        'dailySpanMinutes': dailySpanMinutes,
        'weekdayRatePerHour': weekdayRatePerHour,
        'weekendRatePerHour': weekendRatePerHour,
        'overtimeThresholdMinutes': overtimeThresholdMinutes,
        'payUnitMinutes': payUnitMinutes,
      };

  factory WorkRules.fromJson(Map<String, Object?> json) {
    int readInt(String key, int fallback) {
      final value = json[key];
      if (value is num) return value.toInt();
      return fallback;
    }

    double readDouble(String key, double fallback) {
      final value = json[key];
      if (value is num) return value.toDouble();
      return fallback;
    }

    const defaults = WorkRules.standard;
    return WorkRules(
      standardStartMinutes:
          readInt('standardStartMinutes', defaults.standardStartMinutes),
      allowedDelayMinutes:
          readInt('allowedDelayMinutes', defaults.allowedDelayMinutes),
      requiredWorkMinutes:
          readInt('requiredWorkMinutes', defaults.requiredWorkMinutes),
      dailySpanMinutes: readInt('dailySpanMinutes', defaults.dailySpanMinutes),
      weekdayRatePerHour:
          readDouble('weekdayRatePerHour', defaults.weekdayRatePerHour),
      weekendRatePerHour:
          readDouble('weekendRatePerHour', defaults.weekendRatePerHour),
      overtimeThresholdMinutes: readInt(
        'overtimeThresholdMinutes',
        defaults.overtimeThresholdMinutes,
      ),
      payUnitMinutes: readInt('payUnitMinutes', defaults.payUnitMinutes),
    );
  }

  /// 默认规则。
  static const WorkRules standard = WorkRules();

  @override
  bool operator ==(Object other) {
    return other is WorkRules &&
        other.standardStartMinutes == standardStartMinutes &&
        other.allowedDelayMinutes == allowedDelayMinutes &&
        other.requiredWorkMinutes == requiredWorkMinutes &&
        other.dailySpanMinutes == dailySpanMinutes &&
        other.weekdayRatePerHour == weekdayRatePerHour &&
        other.weekendRatePerHour == weekendRatePerHour &&
        other.overtimeThresholdMinutes == overtimeThresholdMinutes &&
        other.payUnitMinutes == payUnitMinutes;
  }

  @override
  int get hashCode => Object.hash(
        standardStartMinutes,
        allowedDelayMinutes,
        requiredWorkMinutes,
        dailySpanMinutes,
        weekdayRatePerHour,
        weekendRatePerHour,
        overtimeThresholdMinutes,
        payUnitMinutes,
      );

  @override
  String toString() => 'WorkRules(start: $standardStartMinutes, '
      'delay: $allowedDelayMinutes, span: $dailySpanMinutes, '
      'weekday: $weekdayRatePerHour, weekend: $weekendRatePerHour, '
      'threshold: $overtimeThresholdMinutes, payUnit: $payUnitMinutes)';
}
