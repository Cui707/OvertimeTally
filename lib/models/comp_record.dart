import '../core/date_x.dart';

const Object _unset = Object();

/// 一条调休使用记录：在 [date] 当天使用了 [minutes] 分钟的调休。
class CompRecord {
  const CompRecord({
    this.id,
    required this.date,
    required this.minutes,
    this.note,
  });

  final int? id;
  final DateTime date;
  final int minutes;
  final String? note;

  CompRecord copyWith({
    int? id,
    DateTime? date,
    int? minutes,
    Object? note = _unset,
  }) {
    return CompRecord(
      id: id ?? this.id,
      date: date ?? this.date,
      minutes: minutes ?? this.minutes,
      note: identical(note, _unset) ? this.note : note as String?,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'date': formatDate(date),
        'minutes': minutes,
        'note': note,
      };

  factory CompRecord.fromMap(Map<String, Object?> map) => CompRecord(
        id: map['id'] as int?,
        date: DateTime.parse(map['date'] as String),
        minutes: map['minutes'] as int,
        note: map['note'] as String?,
      );

  @override
  String toString() => 'CompRecord(${formatDate(date)}, $minutes 分钟)';
}
