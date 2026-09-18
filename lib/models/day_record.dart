import '../core/date_x.dart';

const Object _unset = Object();

/// 一天的打卡记录。
///
/// [workDate] 为归属日（上班打卡当天）。跨零点下班时，[clockOut] 会落在次日，
/// 但记录仍归属于上班那天。
class DayRecord {
  const DayRecord({
    this.id,
    required this.workDate,
    this.clockIn,
    this.clockOut,
    this.note,
  });

  final int? id;
  final DateTime workDate;
  final DateTime? clockIn;
  final DateTime? clockOut;
  final String? note;

  bool get hasClockIn => clockIn != null;

  bool get hasClockOut => clockOut != null;

  /// 是否已完整打卡（上下班都有记录）。
  bool get isComplete => clockIn != null && clockOut != null;

  DayRecord copyWith({
    int? id,
    DateTime? workDate,
    Object? clockIn = _unset,
    Object? clockOut = _unset,
    Object? note = _unset,
  }) {
    return DayRecord(
      id: id ?? this.id,
      workDate: workDate ?? this.workDate,
      clockIn: identical(clockIn, _unset) ? this.clockIn : clockIn as DateTime?,
      clockOut:
          identical(clockOut, _unset) ? this.clockOut : clockOut as DateTime?,
      note: identical(note, _unset) ? this.note : note as String?,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'work_date': formatDate(workDate),
        'clock_in': clockIn?.toIso8601String(),
        'clock_out': clockOut?.toIso8601String(),
        'note': note,
      };

  factory DayRecord.fromMap(Map<String, Object?> map) {
    final rawIn = map['clock_in'] as String?;
    final rawOut = map['clock_out'] as String?;
    return DayRecord(
      id: map['id'] as int?,
      workDate: DateTime.parse(map['work_date'] as String),
      clockIn: rawIn == null ? null : DateTime.parse(rawIn),
      clockOut: rawOut == null ? null : DateTime.parse(rawOut),
      note: map['note'] as String?,
    );
  }

  @override
  String toString() =>
      'DayRecord(${formatDate(workDate)}, in: $clockIn, out: $clockOut)';
}
