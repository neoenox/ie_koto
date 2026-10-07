import 'package:flutter/foundation.dart';

/// 内部は仕事のIssueと同じ形。ただし画面には出さない。
enum IssueStatus { open, doing, waiting, done }

extension IssueStatusWords on IssueStatus {
  /// 画面で見せる言葉はこれだけ。仕事の用語（チケット／ステータス／優先度）は使わない。
  String get word => switch (this) {
        IssueStatus.open || IssueStatus.doing => 'やること',
        IssueStatus.waiting => '対応待ち',
        IssueStatus.done => 'おわった',
      };
}

/// くりかえし。家事では「○日ごと（終わってから）」の方が自然なことが多い。
enum RecurrenceKind { none, daily, weekdays, everyDays }

@immutable
class Recurrence {
  final RecurrenceKind kind;

  /// DateTime.monday(1) 〜 DateTime.sunday(7)
  final Set<int> weekdays;
  final int everyDays;

  /// true なら「終わってから数える」。エアコン掃除や歯ブラシ交換はこちら。
  final bool fromCompletion;

  const Recurrence._(
    this.kind, {
    this.weekdays = const <int>{},
    this.everyDays = 0,
    this.fromCompletion = false,
  });

  static const Recurrence none = Recurrence._(RecurrenceKind.none);
  static const Recurrence daily = Recurrence._(RecurrenceKind.daily);

  factory Recurrence.onWeekdays(Set<int> days) =>
      Recurrence._(RecurrenceKind.weekdays, weekdays: Set.unmodifiable(days));

  factory Recurrence.every(int days, {bool fromCompletion = true}) => Recurrence._(
        RecurrenceKind.everyDays,
        everyDays: days,
        fromCompletion: fromCompletion,
      );

  bool get isNone => kind == RecurrenceKind.none;

  static const Map<int, String> weekdayNames = {
    1: '月',
    2: '火',
    3: '水',
    4: '木',
    5: '金',
    6: '土',
    7: '日',
  };

  String get label {
    switch (kind) {
      case RecurrenceKind.none:
        return 'なし';
      case RecurrenceKind.daily:
        return '毎日';
      case RecurrenceKind.weekdays:
        final names = (weekdays.toList()..sort())
            .map((d) => weekdayNames[d] ?? '')
            .join('・');
        return '毎週 $names';
      case RecurrenceKind.everyDays:
        return fromCompletion ? '終わってから$everyDays日ごと' : '$everyDays日ごと';
    }
  }

  /// 次の1件をいつ出すか。定期の家事は完了すると自動で次の1件が出てくる。
  /// 遅れて完了しても、次の1件は完了した日より後にする（溜まった回数ぶん押させない）。
  DateTime? nextDue({required DateTime completedAt, DateTime? previousDue}) {
    final done = _day(completedAt);
    final prev = previousDue == null ? null : _day(previousDue);
    // 前回の期限と完了日の、遅い方から数える。
    final from = prev != null && prev.isAfter(done) ? prev : done;
    switch (kind) {
      case RecurrenceKind.none:
        return null;
      case RecurrenceKind.daily:
        return _addDays(from, 1);
      case RecurrenceKind.weekdays:
        var d = _addDays(from, 1);
        for (var i = 0; i < 7; i++) {
          if (weekdays.contains(d.weekday)) return d;
          d = _addDays(d, 1);
        }
        return d;
      case RecurrenceKind.everyDays:
        if (fromCompletion || prev == null) return _addDays(done, everyDays);
        // 期限から数える場合は周期を保ったまま、完了日より後まで進める。
        final step = everyDays < 1 ? 1 : everyDays;
        var d = _addDays(prev, step);
        while (!d.isAfter(done)) {
          d = _addDays(d, step);
        }
        return d;
    }
  }
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

enum EventKind { created, comment, photo, assignee, due, recurrence, status, completed, reopened }

/// Issueの履歴。UIでは「家族のタイムライン」として出す。
@immutable
class IssueEvent {
  final EventKind kind;
  final DateTime at;
  final String? actorId;
  final String? text;

  const IssueEvent(this.kind, this.at, {this.actorId, this.text});
}

class Issue {
  final String id;
  final DateTime createdAt;
  final String reporterId;

  /// 同じ定期案件の連なりを示す。UIには出さない。
  String? seriesId;

  String title;
  String? assigneeId;
  DateTime? dueDate;
  Recurrence recurrence;
  IssueStatus status;
  DateTime? completedAt;

  /// 完了時に自動生成した次の1件。もどす時に一緒に消す。
  String? generatedNextId;

  final List<IssueEvent> events;

  Issue({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.reporterId,
    this.assigneeId,
    this.dueDate,
    this.recurrence = Recurrence.none,
    this.status = IssueStatus.open,
    this.seriesId,
    this.completedAt,
    List<IssueEvent>? events,
  }) : events = events ?? <IssueEvent>[];

  bool get isDone => status == IssueStatus.done;

  /// 定期案件のまとまり。番号は見せないが、内部では同じ並びとして扱う。
  String get seriesKey => seriesId ?? id;
}

@immutable
class Member {
  final String id;
  final String name;

  const Member(this.id, this.name);
}
