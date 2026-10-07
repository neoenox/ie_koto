import 'format.dart';
import 'store.dart';

/// アプリ内のお知らせ3種のうち、ホームに1行だけ出すための文言。
///
/// - 期限当日・過ぎたもの: 今日以前の期限でまだ終わっていないもの
/// - 自分の担当: 今日以前の期限で自分が担当のもの
/// - 朝の要約は、この1行が兼ねる（今日やるべき数がここに出る）
///
/// どちらも無ければ null（行自体を出さない）。OS通知は使わない。
String? noticeLineFor(IssueStore store) {
  final now = store.now;
  var overdue = 0;
  var mine = 0;
  for (final issue in store.openIssues) {
    final due = issue.dueDate;
    if (due == null || _day(due).isAfter(_day(now))) continue;
    if (isOverdue(due, now)) overdue += 1;
    if (issue.assigneeId != null && issue.assigneeId == store.meId) mine += 1;
  }
  if (overdue > 0 && mine > 0) return 'すぎているものが$overdue件・今日の自分は$mine件';
  if (overdue > 0) return 'すぎているものが$overdue件ある';
  if (mine > 0) return '今日の自分は$mine件';
  return null;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
