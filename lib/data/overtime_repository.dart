import '../models/comp_record.dart';
import '../models/day_record.dart';

/// 数据仓储抽象，便于在测试中替换为内存实现。
abstract class OvertimeRepository {
  /// 指定月份的全部打卡记录。
  Future<List<DayRecord>> dayRecordsInMonth(DateTime month);

  /// 指定归属日的打卡记录。
  Future<DayRecord?> dayRecordFor(DateTime date);

  /// 最近一条只有上班、没有下班的记录（用于跨零点下班关联）。
  Future<DayRecord?> findOpenRecord();

  /// 新增或更新打卡记录（以 work_date 唯一）。
  Future<void> upsertDayRecord(DayRecord record);

  /// 删除指定归属日的打卡记录。
  Future<void> deleteDayRecord(DateTime date);

  /// 指定月份的全部调休记录。
  Future<List<CompRecord>> compRecordsInMonth(DateTime month);

  /// 新增或更新调休记录，返回记录 id。
  Future<int> upsertCompRecord(CompRecord record);

  /// 删除调休记录。
  Future<void> deleteCompRecord(int id);
}
