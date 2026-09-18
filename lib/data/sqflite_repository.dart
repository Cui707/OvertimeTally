import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../core/date_x.dart';
import '../models/comp_record.dart';
import '../models/day_record.dart';
import 'overtime_repository.dart';

/// 基于 sqflite 的持久化实现。
class SqfliteOvertimeRepository implements OvertimeRepository {
  SqfliteOvertimeRepository({this.databaseName = 'overtime_tally.db'});

  final String databaseName;

  static const int _version = 1;
  static const String _dayTable = 'day_records';
  static const String _compTable = 'comp_records';

  Database? _database;

  Future<Database> get _db async {
    final cached = _database;
    if (cached != null) return cached;
    final path = join(await getDatabasesPath(), databaseName);
    final db = await openDatabase(
      path,
      version: _version,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE $_dayTable('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'work_date TEXT NOT NULL UNIQUE, '
          'clock_in TEXT, '
          'clock_out TEXT, '
          'note TEXT)',
        );
        await db.execute(
          'CREATE TABLE $_compTable('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'date TEXT NOT NULL, '
          'minutes INTEGER NOT NULL, '
          'note TEXT)',
        );
        await db.execute(
          'CREATE INDEX idx_comp_date ON $_compTable(date)',
        );
      },
    );
    _database = db;
    return db;
  }

  @override
  Future<List<DayRecord>> dayRecordsInMonth(DateTime month) async {
    final db = await _db;
    final rows = await db.query(
      _dayTable,
      where: 'work_date >= ? AND work_date <= ?',
      whereArgs: [formatDate(firstDayOfMonth(month)), formatDate(lastDayOfMonth(month))],
      orderBy: 'work_date ASC',
    );
    return rows.map(DayRecord.fromMap).toList();
  }

  @override
  Future<DayRecord?> dayRecordFor(DateTime date) async {
    final db = await _db;
    final rows = await db.query(
      _dayTable,
      where: 'work_date = ?',
      whereArgs: [formatDate(date)],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DayRecord.fromMap(rows.first);
  }

  @override
  Future<DayRecord?> findOpenRecord() async {
    final db = await _db;
    final rows = await db.query(
      _dayTable,
      where: 'clock_in IS NOT NULL AND clock_out IS NULL',
      orderBy: 'work_date DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DayRecord.fromMap(rows.first);
  }

  @override
  Future<void> upsertDayRecord(DayRecord record) async {
    final db = await _db;
    final map = record.toMap()..remove('id');
    await db.insert(
      _dayTable,
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteDayRecord(DateTime date) async {
    final db = await _db;
    await db.delete(
      _dayTable,
      where: 'work_date = ?',
      whereArgs: [formatDate(date)],
    );
  }

  @override
  Future<List<CompRecord>> compRecordsInMonth(DateTime month) async {
    final db = await _db;
    final rows = await db.query(
      _compTable,
      where: 'date >= ? AND date <= ?',
      whereArgs: [formatDate(firstDayOfMonth(month)), formatDate(lastDayOfMonth(month))],
      orderBy: 'date ASC, id ASC',
    );
    return rows.map(CompRecord.fromMap).toList();
  }

  @override
  Future<int> upsertCompRecord(CompRecord record) async {
    final db = await _db;
    final map = record.toMap();
    if (record.id == null) {
      map.remove('id');
      return db.insert(_compTable, map);
    }
    await db.update(
      _compTable,
      map,
      where: 'id = ?',
      whereArgs: [record.id],
    );
    return record.id!;
  }

  @override
  Future<void> deleteCompRecord(int id) async {
    final db = await _db;
    await db.delete(_compTable, where: 'id = ?', whereArgs: [id]);
  }
}
