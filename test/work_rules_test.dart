import 'package:flutter_test/flutter_test.dart';
import 'package:overtime_tally/core/work_rules.dart';

void main() {
  test('默认规则的派生值', () {
    const rules = WorkRules.standard;
    expect(rules.standardStartMinutes, 8 * 60 + 15);
    expect(rules.latestClockInMinutes, 9 * 60 + 15);
    expect(rules.standardEndMinutes, 17 * 60 + 30);
    expect(rules.lunchBreakMinutes, 60 + 15);
    expect(rules.dailySpanMinutes, 9 * 60 + 15);
    expect(rules.payUnitMinutes, 60);
  });

  test('自定义规则的派生值随参数变化', () {
    const rules = WorkRules(
      standardStartMinutes: 8 * 60,
      allowedDelayMinutes: 30,
      dailySpanMinutes: 9 * 60,
      weekdayRatePerHour: 50,
      weekendRatePerHour: 60,
      overtimeThresholdMinutes: 15,
      payUnitMinutes: 30,
    );
    expect(rules.latestClockInMinutes, 8 * 60 + 30);
    expect(rules.standardEndMinutes, 17 * 60);
    expect(rules.lunchBreakMinutes, 60);
  });

  test('copyWith 只改指定字段', () {
    final rules = WorkRules.standard.copyWith(weekdayRatePerHour: 45);
    expect(rules.weekdayRatePerHour, 45);
    expect(rules.weekendRatePerHour, WorkRules.standard.weekendRatePerHour);
    expect(rules.standardStartMinutes, WorkRules.standard.standardStartMinutes);
  });

  test('toJson / fromJson 往返一致', () {
    const rules = WorkRules(
      standardStartMinutes: 9 * 60,
      allowedDelayMinutes: 45,
      dailySpanMinutes: 10 * 60,
      weekdayRatePerHour: 33.5,
      weekendRatePerHour: 44,
      overtimeThresholdMinutes: 20,
      payUnitMinutes: 30,
    );
    final restored = WorkRules.fromJson(rules.toJson());
    expect(restored, rules);
  });

  test('fromJson 缺失字段时回退到默认值', () {
    final restored = WorkRules.fromJson(<String, Object?>{'payUnitMinutes': 30});
    expect(restored.payUnitMinutes, 30);
    expect(restored.standardStartMinutes, WorkRules.standard.standardStartMinutes);
    expect(restored.weekdayRatePerHour, WorkRules.standard.weekdayRatePerHour);
  });
}
