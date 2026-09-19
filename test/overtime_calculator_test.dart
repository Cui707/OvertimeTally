import 'package:flutter_test/flutter_test.dart';
import 'package:overtime_tally/core/work_rules.dart';
import 'package:overtime_tally/models/day_record.dart';
import 'package:overtime_tally/services/overtime_calculator.dart';

void main() {
  const calculator = OvertimeCalculator();

  DayRecord workday(DateTime clockIn, DateTime clockOut) =>
      DayRecord(workDate: DateTime(2026, 9, 14), clockIn: clockIn, clockOut: clockOut);

  DayRecord weekend(DateTime clockIn, DateTime clockOut) =>
      DayRecord(workDate: DateTime(2026, 9, 12), clockIn: clockIn, clockOut: clockOut);

  group('工作日规则', () {
    test('8:15-17:30 标准日无加班', () {
      final result = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 8, 15), DateTime(2026, 9, 14, 17, 30)),
      );
      expect(result.isWeekend, isFalse);
      expect(result.workMinutes, WorkRules.standard.requiredWorkMinutes);
      expect(result.requiredClockOut, DateTime(2026, 9, 14, 17, 30));
      expect(result.weekdayOvertimeMinutes, 0);
      expect(result.overtimePay, 0);
      expect(result.isLate, isFalse);
      expect(result.incomplete, isFalse);
    });

    test('加班 29 分钟不计加班', () {
      final result = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 8, 15), DateTime(2026, 9, 14, 17, 59)),
      );
      expect(result.weekdayOvertimeMinutes, 0);
      expect(result.overtimePay, 0);
    });

    test('加班 30 分钟按 30 分钟计，不足 1 小时加班费为 0', () {
      final result = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 8, 15), DateTime(2026, 9, 14, 18, 0)),
      );
      expect(result.weekdayOvertimeMinutes, 30);
      expect(result.overtimePay, 0);
    });

    test('加班 31 分钟按 31 分钟计，不足 1 小时加班费为 0', () {
      final result = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 8, 15), DateTime(2026, 9, 14, 18, 1)),
      );
      expect(result.weekdayOvertimeMinutes, 31);
      expect(result.overtimePay, 0);
    });

    test('加班 59 分钟记录 59 分钟，加班费 0 元', () {
      final result = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 8, 15), DateTime(2026, 9, 14, 18, 29)),
      );
      expect(result.weekdayOvertimeMinutes, 59);
      expect(result.overtimePay, 0);
    });

    test('加班 70 分钟记录 70 分钟，加班费 30 元（按 1 小时结算）', () {
      final result = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 8, 15), DateTime(2026, 9, 14, 18, 40)),
      );
      expect(result.weekdayOvertimeMinutes, 70);
      expect(result.overtimePay, 30);
    });

    test('加班 90 分钟加班费 30 元，加班 120 分钟加班费 60 元', () {
      final ninety = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 8, 15), DateTime(2026, 9, 14, 19, 0)),
      );
      expect(ninety.weekdayOvertimeMinutes, 90);
      expect(ninety.overtimePay, 30);

      final oneTwenty = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 8, 15), DateTime(2026, 9, 14, 19, 30)),
      );
      expect(oneTwenty.weekdayOvertimeMinutes, 120);
      expect(oneTwenty.overtimePay, 60);
    });

    test('9:15 上班不算迟到，应下班 18:30', () {
      final result = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 9, 15), DateTime(2026, 9, 14, 18, 30)),
      );
      expect(result.isLate, isFalse);
      expect(result.requiredClockOut, DateTime(2026, 9, 14, 18, 30));
      expect(result.weekdayOvertimeMinutes, 0);
    });

    test('9:16 上班算迟到', () {
      final result = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 9, 16), DateTime(2026, 9, 14, 18, 31)),
      );
      expect(result.isLate, isTrue);
      expect(result.requiredClockOut, DateTime(2026, 9, 14, 18, 31));
      expect(result.weekdayOvertimeMinutes, 0);
    });

    test('迟到 10:00 上班，应下班 19:15，19:44 下班不计加班', () {
      final result = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 10, 0), DateTime(2026, 9, 14, 19, 44)),
      );
      expect(result.isLate, isTrue);
      expect(result.requiredClockOut, DateTime(2026, 9, 14, 19, 15));
      expect(result.weekdayOvertimeMinutes, 0);
    });

    test('迟到 10:00 上班，19:45 下班计 30 分钟加班', () {
      final result = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 10, 0), DateTime(2026, 9, 14, 19, 45)),
      );
      expect(result.weekdayOvertimeMinutes, 30);
      expect(result.overtimePay, 0);
    });

    test('缺下班打卡视为不完整', () {
      final result = calculator.computeDay(
        DayRecord(workDate: DateTime(2026, 9, 14), clockIn: DateTime(2026, 9, 14, 8, 15)),
      );
      expect(result.incomplete, isTrue);
      expect(result.weekdayOvertimeMinutes, 0);
    });

    test('只有下班打卡视为不完整', () {
      final result = calculator.computeDay(
        DayRecord(workDate: DateTime(2026, 9, 14), clockOut: DateTime(2026, 9, 14, 18, 0)),
      );
      expect(result.incomplete, isTrue);
      expect(result.isEmpty, isFalse);
    });

    test('空记录不是不完整，只是没有内容', () {
      final result = calculator.computeDay(DayRecord(workDate: DateTime(2026, 9, 14)));
      expect(result.incomplete, isFalse);
      expect(result.isEmpty, isTrue);
    });
  });

  group('周末规则', () {
    test('周末工作时长全额计入周末加班，费率 40 元/时', () {
      final result = calculator.computeDay(
        weekend(DateTime(2026, 9, 12, 10, 0), DateTime(2026, 9, 12, 15, 0)),
      );
      expect(result.isWeekend, isTrue);
      expect(result.weekendOvertimeMinutes, 300);
      expect(result.weekdayOvertimeMinutes, 0);
      expect(result.workMinutes, 300);
      expect(result.overtimePay, 200.0);
      expect(result.isLate, isFalse);
    });

    test('周末晚于 9:15 也不算迟到', () {
      final result = calculator.computeDay(
        weekend(DateTime(2026, 9, 12, 11, 0), DateTime(2026, 9, 12, 14, 0)),
      );
      expect(result.isLate, isFalse);
      expect(result.weekendOvertimeMinutes, 180);
    });
  });

  group('跨零点', () {
    test('工作日跨零点下班，加班从应下班时间算起', () {
      final result = calculator.computeDay(
        workday(DateTime(2026, 9, 14, 8, 15), DateTime(2026, 9, 15, 1, 0)),
      );
      expect(result.weekdayOvertimeMinutes, 450);
      expect(result.overtimePay, 210.0);
    });

    test('周末跨零点，工作时长全额计入', () {
      final result = calculator.computeDay(
        weekend(DateTime(2026, 9, 12, 20, 0), DateTime(2026, 9, 13, 2, 0)),
      );
      expect(result.weekendOvertimeMinutes, 360);
      expect(result.overtimePay, 240.0);
    });
  });
}
