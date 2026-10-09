/// 画面に出す言葉づかい。日にちは「今日／明日／8/7」の3通りだけ。
String two(int n) => n.toString().padLeft(2, '0');

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// 履歴の時刻。今日なら「19:13」、それ以外は「10/5」。
String timeLabel(DateTime at, DateTime now) => _sameDay(at, now)
    ? '${at.hour}:${two(at.minute)}'
    : '${at.month}/${at.day}';

/// 期限。過ぎていたら「8/7まで」。
String dueLabel(DateTime due, DateTime now) {
  final d = _day(due);
  final diff = d.difference(_day(now)).inDays;
  if (diff < 0) return '${d.month}/${d.day}まで';
  if (diff == 0) return '今日';
  if (diff == 1) return '明日';
  return '${d.month}/${d.day}';
}

bool isOverdue(DateTime due, DateTime now) => _day(due).isBefore(_day(now));
