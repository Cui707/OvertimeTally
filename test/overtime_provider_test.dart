import 'package:flutter_test/flutter_test.dart';
import 'package:overtime_tally/core/work_rules.dart';
import 'package:overtime_tally/data/in_memory_repository.dart';
import 'package:overtime_tally/data/settings_store.dart';
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

  test('updateRules 后按新规则重算并持久化', () async {
    var now = DateTime(2026, 9, 14, 8, 15);
    final store = InMemorySettingsStore();
    final provider = OvertimeProvider(
      repository: InMemoryOvertimeRepository(),
      settingsStore: store,
      now: () => now,
    );
    await provider.load();
    await provider.clockIn();
    now = DateTime(2026, 9, 14, 17, 50); // 应下班 17:30，实际加班 20 分钟
    await provider.clockOut();

    // 默认阈值 30 分钟：不计加班。
    expect(provider.stats.weekdayOvertimeMinutes, 0);

    // 阈值改为 0：20 分钟计入加班；计费单位 30 分钟时不足一个单位，费用为 0。
    await provider.updateRules(
      provider.rules.copyWith(
        overtimeThresholdMinutes: 0,
        payUnitMinutes: 30,
      ),
    );
    expect(provider.stats.weekdayOvertimeMinutes, 20);
    expect(provider.stats.weekdayOvertimePay, 0);

    // 计费单位改为 10 分钟：floor(20/10)=2 个单位 × 30 元。
    await provider.updateRules(provider.rules.copyWith(payUnitMinutes: 10));
    expect(provider.stats.weekdayOvertimePay, 60);

    // 持久化：新 Provider 读取同一存储应得到相同规则。
    final reloaded = OvertimeProvider(
      repository: InMemoryOvertimeRepository(),
      settingsStore: store,
      now: () => now,
    );
    await reloaded.load();
    expect(reloaded.rules.overtimeThresholdMinutes, 0);
    expect(reloaded.rules.payUnitMinutes, 10);
  });

  test('修改每日总跨度会改变应下班时间与加班时长', () async {
    var now = DateTime(2026, 9, 14, 8, 15);
    final provider = buildProvider(() => now);
    await provider.load();
    await provider.clockIn();
    now = DateTime(2026, 9, 14, 17, 30);
    await provider.clockOut();

    // 默认跨度 9h15m：应下班 17:30，加班 0。
    expect(
      provider.resultForDate(DateTime(2026, 9, 14)).weekdayOvertimeMinutes,
      0,
    );

    // 跨度改为 8 小时：应下班 16:15，加班 75 分钟。
    await provider.updateRules(
      provider.rules.copyWith(dailySpanMinutes: 8 * 60),
    );
    expect(
      provider.resultForDate(DateTime(2026, 9, 14)).weekdayOvertimeMinutes,
      75,
    );
  });

  test('resetRules 恢复默认设置', () async {
    final now = DateTime(2026, 9, 14, 9, 0);
    final provider = buildProvider(() => now);
    await provider.load();
    await provider.updateRules(provider.rules.copyWith(weekdayRatePerHour: 99));
    expect(provider.rules.weekdayRatePerHour, 99);
    await provider.resetRules();
    expect(provider.rules, WorkRules.standard);
  });
}
