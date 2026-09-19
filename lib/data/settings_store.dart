import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/work_rules.dart';

/// 规则设置的持久化抽象。
abstract class SettingsStore {
  Future<WorkRules> load();

  Future<void> save(WorkRules rules);
}

/// 内存实现，用于单元测试。
class InMemorySettingsStore implements SettingsStore {
  InMemorySettingsStore([this._rules = WorkRules.standard]);

  WorkRules _rules;

  @override
  Future<WorkRules> load() async => _rules;

  @override
  Future<void> save(WorkRules rules) async {
    _rules = rules;
  }
}

/// 以 JSON 文件保存规则设置，写入应用私有目录。
class JsonFileSettingsStore implements SettingsStore {
  JsonFileSettingsStore({
    Future<Directory> Function()? directoryProvider,
    this.fileName = 'settings.json',
  }) : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;
  final String fileName;

  Future<File> _storeFile() async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File(p.join(directory.path, fileName));
  }

  @override
  Future<WorkRules> load() async {
    try {
      final file = await _storeFile();
      if (!await file.exists()) return WorkRules.standard;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return WorkRules.standard;
      final decoded = jsonDecode(content);
      if (decoded is! Map) return WorkRules.standard;
      return WorkRules.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return WorkRules.standard;
    }
  }

  @override
  Future<void> save(WorkRules rules) async {
    final file = await _storeFile();
    await file.writeAsString(jsonEncode(rules.toJson()));
  }
}
