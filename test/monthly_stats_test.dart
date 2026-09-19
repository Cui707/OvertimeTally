import 'package:flutter_test/flutter_test.dart';
import 'package:overtime_tally/models/comp_record.dart';
import 'package:overtime_tally/models/day_record.dart';
import 'package:overtime_tally/services/overtime_calculator.dart';

void main() {
  const calculator = OvertimeCalculator();
  final month = DateTime(2026, 9);

  List<DayRecord> dayRecords() => [
        DayRecord(
          workDate: DateTime(2026, 9, 14),
          clockIn: DateTime(2026, 9, 14, 8, 15),
          clockOut: DateTime(2026, 9, 14, 18, 0),
        ),
        DayRecord(
          workDate: DateTime(2026, 9, 15),
          clockIn: DateTime(2026, 9, 15, 8, 15),
          clockOut: DateTime(2026, 9, 15, 18, 31),
        ),
        DayRecord(
          workDate: DateTime(2026, 9, 12),
          clockIn: DateTime(2026, 9, 12, 9, 0),
          clockOut: DateTime(2026, 9, 12, 15, 0),
        ),
        DayRecord(
          workDate: DateTime(2026, 9, 13),
          clockIn: DateTime(2026, 9, 13, 10, 0),
          clockOut: DateTime(2026, 9, 13, 16, 0),
        ),
      ];

  test('无调休时的月度汇总', () {
    final stats = calculator.computeMonth(
      month: month,
      dayRecords: dayRecords(),
      compRecords: const [],
    );
    expect(stats.weekdayOvertimeMinutes, 91);
    expect(stats.weekendOvertimeMinutes, 720);
    expect(stats.compUsedMinutes, 0);
    expect(stats.remainingCompMinutes, 720);
    expect(stats.totalOvertimeMinutes, 811);
    // 91 分钟 -> 1 小时 -> 30 元；720 分钟 -> 12 小时 -> 480 元。
    expect(stats.weekdayOvertimePay, 30);
    expect(stats.weekendOvertimePay, 480);
    expect(stats.totalOvertimePay, 510);
  });

  test('调休抵扣周末加班后，总加班与加班费同步修正', () {
    final stats = calculator.computeMonth(
      month: month,
      dayRecords: dayRecords(),
      compRecords: [CompRecord(date: DateTime(2026, 9, 13), minutes: 120)],
    );
    expect(stats.compUsedMinutes, 120);
    expect(stats.compAvailableMinutes, 720);
    expect(stats.remainingCompMinutes, 600);
    expect(stats.effectiveWeekendOvertimeMinutes, 600);
    expect(stats.totalOvertimeMinutes, 691);
    expect(stats.weekdayOvertimePay, 30);
    expect(stats.weekendOvertimePay, 400);
    expect(stats.totalOvertimePay, 430);
  });

  test('调休超过周末加班时，剩余与有效周末加班都不会为负', () {
    final stats = calculator.computeMonth(
      month: month,
      dayRecords: dayRecords(),
      compRecords: [CompRecord(date: DateTime(2026, 9, 13), minutes: 1000)],
    );
    expect(stats.remainingCompMinutes, 0);
    expect(stats.effectiveWeekendOvertimeMinutes, 0);
    expect(stats.totalOvertimeMinutes, 91);
    expect(stats.totalOvertimePay, 30);
  });

  test('每日零头累计：3 天各 90 分钟，月度按 4 小时结算而非逐日 1 小时相加', () {
    final stats = calculator.computeMonth(
      month: month,
      dayRecords: [
        for (final day in [14, 15, 16])
          DayRecord(
            workDate: DateTime(2026, 9, day),
            clockIn: DateTime(2026, 9, day, 8, 15),
            clockOut: DateTime(2026, 9, day, 19, 0),
          ),
      ],
      compRecords: const [],
    );
    expect(stats.weekdayOvertimeMinutes, 270);
    // 逐日相加只有 3 × 30 = 90 元；按月累计 270 分钟 = 4 小时 -> 120 元。
    expect(stats.weekdayOvertimePay, 120);
    expect(stats.totalOvertimePay, 120);
  });

  test('调休只统计所属月份', () {
    final stats = calculator.computeMonth(
      month: month,
      dayRecords: dayRecords(),
      compRecords: [
        CompRecord(date: DateTime(2026, 8, 31), minutes: 60),
        CompRecord(date: DateTime(2026, 9, 30), minutes: 30),
      ],
    );
    expect(stats.compUsedMinutes, 30);
  });
}
