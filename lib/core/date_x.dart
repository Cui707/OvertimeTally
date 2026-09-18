/// 日期/时间处理的轻量工具函数，避免在业务层重复拼接字符串。
library;

/// 中文星期标签，下标为 `DateTime.weekday - 1`（周一=1 ... 周日=7）。
const List<String> kWeekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 去掉时分秒，只保留日期部分。
DateTime dateOnly(DateTime value) => DateTime(value.year, value.month, value.day);

/// 判断两个时间是否为同一天。
bool isSameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 判断两个时间是否在同一个月。
bool isSameMonth(DateTime a, DateTime b) => a.year == b.year && a.month == b.month;

/// 当天零点起算的分钟数。
int minutesOfDay(DateTime value) => value.hour * 60 + value.minute;

/// 当月第一天。
DateTime firstDayOfMonth(DateTime value) => DateTime(value.year, value.month, 1);

/// 当月最后一天。
DateTime lastDayOfMonth(DateTime value) => DateTime(value.year, value.month + 1, 0);

/// 当月天数。
int daysInMonth(DateTime value) => lastDayOfMonth(value).day;

/// 是否为周末（周六或周日）。
bool isWeekend(DateTime value) =>
    value.weekday == DateTime.saturday || value.weekday == DateTime.sunday;

/// `yyyy-MM-dd`，用于数据库存储与字典序比较。
String formatDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

/// `HH:mm`，空值显示为 `--:--`。
String formatTime(DateTime? value) {
  if (value == null) return '--:--';
  return '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

/// `yyyy年M月`。
String formatMonthLabel(DateTime value) => '${value.year}年${value.month}月';

/// `M月d日 周X`。
String formatDayLabel(DateTime value) =>
    '${value.month}月${value.day}日 ${weekdayLabel(value)}';

/// 中文星期标签。
String weekdayLabel(DateTime value) => kWeekdayLabels[value.weekday - 1];

/// 把分钟数格式化为 `X小时Y分`。
String formatMinutes(int minutes) {
  if (minutes <= 0) return '0分钟';
  final hours = minutes ~/ 60;
  final mins = minutes % 60;
  if (hours == 0) return '$mins分钟';
  if (mins == 0) return '$hours小时';
  return '$hours小时$mins分';
}

/// 把分钟数格式化为 `X.X` 小时，保留一位小数。
String formatHours(int minutes) {
  if (minutes <= 0) return '0.0';
  return (minutes / 60).toStringAsFixed(1);
}
