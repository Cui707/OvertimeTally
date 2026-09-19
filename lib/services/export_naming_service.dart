import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 负责生成不会与已有文件冲突的导出文件名。
///
/// 系统保存对话框遇到重名时会把 “（1）” 追加到扩展名之后，得到
/// `文件名.xlsx（1）` 这种无法打开的文件。这里由应用自己维护每个基名
/// 的导出次数，在扩展名之前生成 `文件名（1）.xlsx`，从根本上避免系统重命名。
class ExportNamingService {
  ExportNamingService({
    Future<Directory> Function()? directoryProvider,
    this.fileName = 'export_naming.json',
  }) : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  /// 计数文件名称。
  final String fileName;

  Future<File> _storeFile() async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File(p.join(directory.path, fileName));
  }

  Future<Map<String, int>> _readCounts() async {
    try {
      final file = await _storeFile();
      if (!await file.exists()) return <String, int>{};
      final content = await file.readAsString();
      if (content.trim().isEmpty) return <String, int>{};
      final decoded = jsonDecode(content);
      if (decoded is! Map) return <String, int>{};
      return decoded.map(
        (key, value) => MapEntry('$key', (value as num).toInt()),
      );
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> _writeCounts(Map<String, int> counts) async {
    final file = await _storeFile();
    await file.writeAsString(jsonEncode(counts));
  }

  /// 生成建议文件名，例如 `OvertimeTally_2026-09（1）.xlsx`。
  ///
  /// 后缀始终位于扩展名之前，保证文件可正常打开。
  Future<String> suggestFileName({
    required String base,
    required String extension,
  }) async {
    final counts = await _readCounts();
    final index = counts[base] ?? 0;
    final suffix = index <= 0 ? '' : '（$index）';
    return '$base$suffix.$extension';
  }

  /// 文件保存成功后调用，递增该基名的计数。
  Future<void> confirmSaved({required String base}) async {
    final counts = await _readCounts();
    counts[base] = (counts[base] ?? 0) + 1;
    await _writeCounts(counts);
  }
}
