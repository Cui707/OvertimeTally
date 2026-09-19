import 'package:flutter_test/flutter_test.dart';
import 'package:overtime_tally/data/in_memory_repository.dart';
import 'package:overtime_tally/providers/overtime_provider.dart';

void main() {
  OvertimeProvider buildProvider(DateTime Function() now) => OvertimeProvider(
        repository: InMemoryOvertimeRepository(),
        now: now,
      );

  test('打卡后自动计算当日加班与月度统计', () async {
    var now = DateTime(2026, 9, 14, 8, 15);
    final provider = buildProvider(() => now);
    await provider.load();
    expect(provider.loading, isFalse);

    await provider.clockIn();
    now = DateTime(2026, 9, 14, 18, 0);
    await provider.clockOut();

    final result = provider.resultForDate(DateTime(2026, 9, 14));
    expect(result.weekdayOvertimeMinutes, 30);
    expect(provider.stats.weekdayOvertimeMinutes, 30);
    // 30 分钟不足 1 小时，加班费为 0。
    expect(result.overtimePay, 0);
    expect(provider.stats.totalOvertimePay, 0);
  });

  test('凌晨下班自动关联到前一天', () async {
    var now = DateTime(2026, 9, 14, 8, 15);
    final provider = buildProvider(() => now);
    await provider.load();
    await provider.clockIn();

    now = DateTime(2026, 9, 15, 1, 0);
    await provider.clockOut();

    final record = provider.recordForDate(DateTime(2026, 9, 14));
    expect(record, isNotNull);
    expect(record!.clockOut, DateTime(2026, 9, 15, 1, 0));
    expect(provider.recordForDate(DateTime(2026, 9, 15)), isNull);
    expect(provider.selectedDate, DateTime(2026, 9, 14));
  });

  test('重复上班打卡会给出提示', () async {
    final now = DateTime(2026, 9, 14, 8, 15);
    final provider = buildProvider(() => now);
    await provider.load();
    await provider.clockIn();
    await provider.clockIn();
    expect(provider.errorMessage, isNotNull);
  });

  test('调休超过可用额度时拒绝保存', () async {
    final now = DateTime(2026, 9, 12, 9, 0);
    final provider = buildProvider(() => now);
    await provider.load();

    await provider.updateClockIn(
      DateTime(2026, 9, 12),
      DateTime(2026, 9, 12, 9, 0),
    );
    await provider.updateClockOut(
      DateTime(2026, 9, 12),
      DateTime(2026, 9, 12, 15, 0),
    );
    expect(provider.stats.weekendOvertimeMinutes, 360);

    await provider.addCompRecord(date: DateTime(2026, 9, 12), minutes: 360);
    expect(provider.stats.compUsedMinutes, 360);
    expect(provider.stats.remainingCompMinutes, 0);

    await expectLater(
      provider.addCompRecord(date: DateTime(2026, 9, 12), minutes: 1),
      throwsA(isA<CompTimeExceededException>()),
    );
  });

  test('编辑调休时不会把自己算作已占用额度', () async {
    final now = DateTime(2026, 9, 12, 9, 0);
    final provider = buildProvider(() => now);
    await provider.load();
    await provider.updateClockIn(
      DateTime(2026, 9, 12),
      DateTime(2026, 9, 12, 9, 0),
    );
    await provider.updateClockOut(
      DateTime(2026, 9, 12),
      DateTime(2026, 9, 12, 15, 0),
    );
    await provider.addCompRecord(date: DateTime(2026, 9, 12), minutes: 60);
    final record = provider.compRecords.single;

    await provider.updateCompRecord(record.copyWith(minutes: 120));
    expect(provider.stats.compUsedMinutes, 120);
    expect(provider.stats.remainingCompMinutes, 240);

    await expectLater(
      provider.updateCompRecord(record.copyWith(minutes: 400)),
      throwsA(isA<CompTimeExceededException>()),
    );
  });

  test('调休抵扣后总加班与加班费同步修正', () async {
    final now = DateTime(2026, 9, 12, 9, 0);
    final provider = buildProvider(() => now);
    await provider.load();
    await provider.updateClockIn(
      DateTime(2026, 9, 12),
      DateTime(2026, 9, 12, 9, 0),
    );
    await provider.updateClockOut(
      DateTime(2026, 9, 12),
      DateTime(2026, 9, 12, 15, 0),
    );
    await provider.addCompRecord(date: DateTime(2026, 9, 12), minutes: 60);

    expect(provider.stats.totalOvertimeMinutes, 300);
    expect(provider.stats.totalOvertimePay, 200.0);
  });

  test('切换月份会重新加载数据', () async {
    final now = DateTime(2026, 9, 14, 9, 0);
    final provider = buildProvider(() => now);
    await provider.load();
    await provider.goToPreviousMonth();
    expect(provider.selectedMonth, DateTime(2026, 8, 1));
    await provider.goToNextMonth();
    expect(provider.selectedMonth, DateTime(2026, 9, 1));
  });

  test('删除当天打卡记录后记录消失且统计归零', () async {
    var now = DateTime(2026, 9, 14, 8, 15);
    final provider = buildProvider(() => now);
    await provider.load();
    await provider.clockIn();
    now = DateTime(2026, 9, 14, 18, 0);
    await provider.clockOut();

    expect(provider.recordForDate(DateTime(2026, 9, 14)), isNotNull);
    expect(provider.stats.weekdayOvertimeMinutes, 30);

    await provider.deleteDayRecord(DateTime(2026, 9, 14));

    expect(provider.recordForDate(DateTime(2026, 9, 14)), isNull);
    expect(provider.stats.weekdayOvertimeMinutes, 0);
    expect(provider.stats.totalOvertimeMinutes, 0);
    expect(provider.stats.totalOvertimePay, 0);
  });
}
