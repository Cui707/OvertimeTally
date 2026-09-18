import '../core/date_x.dart';
import '../models/comp_record.dart';
import '../models/day_record.dart';
import 'overtime_repository.dart';

/// 内存实现，用于单元测试与 Widget 测试。
class InMemoryOvertimeRepository implements OvertimeRepository {
  final Map<String, DayRecord> _days = <String, DayRecord>{};
  final Map<int, CompRecord> _comps = <int, CompRecord>{};
  int _nextDayId = 1;
  int _nextCompId = 1;

  @override
  Future<List<DayRecord>> dayRecordsInMonth(DateTime month) async {
    final records = _days.values
        .where((record) => isSameMonth(record.workDate, month))
        .toList()
      ..sort((a, b) => a.workDate.compareTo(b.workDate));
    return records;
  }

  @override
  Future<DayRecord?> dayRecordFor(DateTime date) async {
    final record = _days[formatDate(date)];
    return record;
  }

  @override
  Future<DayRecord?> findOpenRecord() async {
    final open = _days.values
        .where((record) => record.hasClockIn && !record.hasClockOut)
        .toList()
      ..sort((a, b) => b.workDate.compareTo(a.workDate));
    return open.isEmpty ? null : open.first;
  }

  @override
  Future<void> upsertDayRecord(DayRecord record) async {
    final key = formatDate(record.workDate);
    final existing = _days[key];
    var id = record.id ?? existing?.id;
    if (id == null) {
      id = _nextDayId++;
    } else if (id >= _nextDayId) {
      _nextDayId = id + 1;
    }
    _days[key] = record.copyWith(id: id);
  }

  @override
  Future<void> deleteDayRecord(DateTime date) async {
    _days.remove(formatDate(date));
  }

  @override
  Future<List<CompRecord>> compRecordsInMonth(DateTime month) async {
    final records = _comps.values
        .where((record) => isSameMonth(record.date, month))
        .toList()
      ..sort((a, b) {
        final byDate = a.date.compareTo(b.date);
        return byDate != 0 ? byDate : (a.id ?? 0).compareTo(b.id ?? 0);
      });
    return records;
  }

  @override
  Future<int> upsertCompRecord(CompRecord record) async {
    final id = record.id ?? _nextCompId++;
    if (id >= _nextCompId) _nextCompId = id + 1;
    _comps[id] = record.copyWith(id: id);
    return id;
  }

  @override
  Future<void> deleteCompRecord(int id) async {
    _comps.remove(id);
  }
}
