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
    expect(stats.totalOvertimePay, 525.5);
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
    expect(stats.weekdayOvertimePay, 45.5);
    expect(stats.weekendOvertimePay, 400.0);
    expect(stats.totalOvertimePay, 445.5);
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
    expect(stats.totalOvertimePay, 45.5);
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
