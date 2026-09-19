import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:overtime_tally/core/work_rules.dart';
import 'package:overtime_tally/data/settings_store.dart';

void main() {
  test('内存存储读写往返', () async {
    final store = InMemorySettingsStore();
    expect(await store.load(), WorkRules.standard);

    const custom = WorkRules(weekdayRatePerHour: 55);
    await store.save(custom);
    expect(await store.load(), custom);
  });

  test('JSON 文件存储：缺失文件时返回默认规则', () async {
    final directory = await Directory.systemTemp.createTemp('otally_settings');
    addTearDown(() => directory.delete(recursive: true));
    final store = JsonFileSettingsStore(directoryProvider: () async => directory);

    expect(await store.load(), WorkRules.standard);
  });

  test('JSON 文件存储：保存后可再次读取', () async {
    final directory = await Directory.systemTemp.createTemp('otally_settings');
    addTearDown(() => directory.delete(recursive: true));
    final store = JsonFileSettingsStore(directoryProvider: () async => directory);

    const custom = WorkRules(
      standardStartMinutes: 9 * 60,
      allowedDelayMinutes: 15,
      dailySpanMinutes: 10 * 60,
      weekdayRatePerHour: 33.5,
      payUnitMinutes: 30,
    );
    await store.save(custom);

    final reloaded =
        JsonFileSettingsStore(directoryProvider: () async => directory);
    expect(await reloaded.load(), custom);
  });

  test('JSON 文件存储：内容损坏时回退到默认规则', () async {
    final directory = await Directory.systemTemp.createTemp('otally_settings');
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}${Platform.pathSeparator}settings.json')
        .writeAsString('not-json');

    final store = JsonFileSettingsStore(directoryProvider: () async => directory);
    expect(await store.load(), WorkRules.standard);
  });
}
