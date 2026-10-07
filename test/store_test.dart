import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/log.dart';

void main() {
  test('既定の担当者名は閲覧者基準で切り替え、変更した名前は維持する', () {
    final store = IssueStore();
    expect(store.assigneeWord('me'), '自分');
    expect(store.assigneeWord('partner'), 'パートナー');
    final issue = store.add(title: '買い物');
    store.setAssignee(issue.id, 'partner');
    store.setMeId('partner');
    expect(store.assigneeWord('partner'), '自分');
    expect(store.assigneeWord('me'), 'パートナー');
    expect(store.byId(issue.id)!.events.last.text, '自分が担当になった');
    store.renameMember('me', '太郎');
    expect(store.assigneeWord('me'), '太郎');
    expect(store.assigneeWord(null), 'だれでも');
    expect(store.memberLabel('unknown'), isNull);
  });

  test('世帯共通の新IDへ旧ログを読み替え、以後は新IDで操作する', () {
    final store = IssueStore();
    final issue = store.add(title: '家族の用事', assigneeId: 'partner');
    store.setAssignee(issue.id, 'partner');
    store.applyMemberDirectory(const MemberDirectory(
      members: [
        Member('mem_11111111111111111111111111111111', '自分'),
        Member('mem_22222222222222222222222222222222', 'パートナー'),
        Member('mem_33333333333333333333333333333333', 'あき'),
      ],
      aliases: {
        'me': 'mem_11111111111111111111111111111111',
        'partner': 'mem_22222222222222222222222222222222',
      },
    ));

    expect(store.byId(issue.id)!.assigneeId, 'mem_22222222222222222222222222222222');
    expect(store.assigneeWord(store.byId(issue.id)!.assigneeId), 'パートナー');
    expect(store.ops.first.data['assigneeId'], 'partner', reason: '既存ログは書き換えない');

    store.setMeId('mem_22222222222222222222222222222222');
    expect(store.assigneeWord(store.byId(issue.id)!.assigneeId), '自分');
    store.setAssignee(issue.id, 'mem_33333333333333333333333333333333');
    expect(store.ops.last.memberId, 'mem_22222222222222222222222222222222');
    expect(store.ops.last.data['assigneeId'], 'mem_33333333333333333333333333333333');
  });

  IssueStore storeAt(DateTime now) => IssueStore(clock: () => now);

  test('登録はタイトルだけでできる', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(title: 'トイレットペーパーを買う');
    expect(issue.assigneeId, isNull);
    expect(issue.dueDate, isNull);
    expect(issue.recurrence.isNone, isTrue);
    expect(store.openIssues.map((i) => i.title), contains('トイレットペーパーを買う'));
  });

  test('期限が今日までのものは今日、それ以外はあとで', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    store.add(title: '今日のぶん', dueDate: DateTime(2026, 10, 6));
    store.add(title: '明後日のぶん', dueDate: DateTime(2026, 10, 8));
    store.add(title: '期限なしのぶん');
    expect(store.todayQueue.map((i) => i.title), ['今日のぶん']);
    expect(store.laterQueue.map((i) => i.title), ['明後日のぶん', '期限なしのぶん']);
  });

  test('毎日は完了すると翌日の1件が自動で出てくる', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(
      title: 'お風呂そうじ',
      dueDate: DateTime(2026, 10, 6),
      recurrence: Recurrence.daily,
    );
    store.complete(issue.id);
    final next = store.openIssues.single;
    expect(next.title, 'お風呂そうじ');
    expect(next.dueDate, DateTime(2026, 10, 7));
    expect(store.justDone.single.id, issue.id);
  });

  test('終わってから30日ごとは、完了した日から数える', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(title: '歯ブラシ交換', recurrence: Recurrence.every(30));
    store.complete(issue.id);
    expect(store.openIssues.single.dueDate, DateTime(2026, 11, 5));
  });

  test('毎週の指定は、次のその曜日に出てくる', () {
    final store = storeAt(DateTime(2026, 10, 7, 9)); // 水曜日
    final issue = store.add(
      title: 'ゴミ出し',
      dueDate: DateTime(2026, 10, 7),
      recurrence: Recurrence.onWeekdays({DateTime.tuesday, DateTime.friday}),
    );
    store.complete(issue.id);
    final next = store.openIssues.single.dueDate!;
    expect(next.weekday, DateTime.friday);
    expect(next, DateTime(2026, 10, 9));
  });

  test('遅れて完了した毎日は、次の1件が明日になる（溜まったぶん押させない）', () {
    final store = storeAt(DateTime(2026, 10, 10, 9));
    final issue = store.add(
      title: 'お風呂そうじ',
      dueDate: DateTime(2026, 10, 5),
      recurrence: Recurrence.daily,
    );
    store.complete(issue.id);
    expect(store.openIssues.single.dueDate, DateTime(2026, 10, 11));
    expect(store.todayQueue, isEmpty);
  });

  test('遅れて完了した毎週は、完了日より後のその曜日になる', () {
    final store = storeAt(DateTime(2026, 10, 14, 9)); // 水曜日
    final issue = store.add(
      title: 'ゴミ出し',
      dueDate: DateTime(2026, 10, 6), // 先週の火曜日
      recurrence: Recurrence.onWeekdays({DateTime.tuesday, DateTime.friday}),
    );
    store.complete(issue.id);
    expect(store.openIssues.single.dueDate, DateTime(2026, 10, 16));
  });

  test('期限から数えるN日ごとは、周期を保ったまま完了日より後に進む', () {
    final next = Recurrence.every(7, fromCompletion: false).nextDue(
      completedAt: DateTime(2026, 10, 20, 9),
      previousDue: DateTime(2026, 10, 6),
    );
    expect(next, DateTime(2026, 10, 27));
  });

  test('前倒しで完了した毎日は、元の期限の翌日になる', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(
      title: 'お風呂そうじ',
      dueDate: DateTime(2026, 10, 7),
      recurrence: Recurrence.daily,
    );
    store.complete(issue.id);
    expect(store.openIssues.single.dueDate, DateTime(2026, 10, 8));
  });

  test('完了済みを「やることにもどす」と、自動生成した次の1件も消える', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(
      title: 'お風呂そうじ',
      dueDate: DateTime(2026, 10, 6),
      recurrence: Recurrence.daily,
    );
    store.complete(issue.id);
    store.setStatus(issue.id, IssueStatus.open);
    expect(store.openIssues.map((i) => i.id), [issue.id]);
    expect(store.all, hasLength(1));
    expect(store.byId(issue.id)!.completedAt, isNull);
  });

  test('完了済みを「対応待ち」にしても、自動生成した次の1件は残らない', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(
      title: 'お風呂そうじ',
      dueDate: DateTime(2026, 10, 6),
      recurrence: Recurrence.daily,
    );
    store.complete(issue.id);
    store.setStatus(issue.id, IssueStatus.waiting);
    expect(store.all, hasLength(1));
    expect(store.byId(issue.id)!.status, IssueStatus.waiting);
    expect(store.byId(issue.id)!.generatedNextId, isNull);
  });

  test('完了した直後の行は、一覧の元の位置に残る（末尾に移らない）', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final a = store.add(title: 'A', dueDate: DateTime(2026, 10, 6));
    store.add(title: 'B', dueDate: DateTime(2026, 10, 6));
    final c = store.add(title: 'C');
    store.add(title: 'D');
    expect(store.todayRows.map((i) => i.title), ['A', 'B']);
    expect(store.laterRows.map((i) => i.title), ['C', 'D']);

    store.complete(a.id);
    store.complete(c.id);
    expect(store.todayRows.map((i) => i.title), ['A', 'B']);
    expect(store.laterRows.map((i) => i.title), ['C', 'D']);
    expect(store.todayQueue.map((i) => i.title), ['B'], reason: '完了は「やること」の件数から外れる');
  });

  test('取り消せる時間が過ぎた行は、一覧から消える', () {
    var now = DateTime(2026, 10, 6, 9);
    final store = IssueStore(clock: () => now);
    final a = store.add(title: 'A', dueDate: DateTime(2026, 10, 6));
    store.complete(a.id);
    now = now.add(IssueStore.undoWindow + const Duration(seconds: 1));
    expect(store.todayRows, isEmpty);
  });

  test('もどすと、自動生成した次の1件も消える', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(
      title: 'お風呂そうじ',
      dueDate: DateTime(2026, 10, 6),
      recurrence: Recurrence.daily,
    );
    store.complete(issue.id);
    expect(store.openIssues, hasLength(1));
    store.undoComplete(issue.id);
    expect(store.openIssues.map((i) => i.id), [issue.id]);
    expect(store.all, hasLength(1));
    expect(store.byId(issue.id)!.status, IssueStatus.open);
    expect(store.byId(issue.id)!.completedAt, isNull);
  });

  test('完了から時間が過ぎると、その場の取り消しはできなくなる', () {
    var now = DateTime(2026, 10, 6, 9);
    final store = IssueStore(clock: () => now);
    final issue = store.add(title: '牛乳を買う');
    store.complete(issue.id);
    expect(store.justDone, hasLength(1));
    now = now.add(IssueStore.undoWindow + const Duration(seconds: 1));
    expect(store.justDone, isEmpty);
  });

  test('対応待ちにしても一覧からは消えない', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(title: '水道から変な音がする', assigneeId: 'me');
    store.setStatus(issue.id, IssueStatus.waiting);
    expect(store.openIssues.single.status, IssueStatus.waiting);
    expect(store.laterQueue.single.title, '水道から変な音がする');
  });

  test('同じ案件の前回・前々回が残る', () {
    final store = IssueStore.demo(clock: () => DateTime(2026, 10, 6, 9));
    final aircon = store.openIssues.firstWhere((i) => i.title.startsWith('エアコン'));
    final history = store.seriesHistory(aircon.seriesKey);
    expect(history, hasLength(2));
    expect(history.first.completedAt!.isAfter(history.last.completedAt!), isTrue);
  });

  test('履歴の時刻は、追加した時刻より前にならない', () {
    final store = IssueStore.demo(clock: () => DateTime(2026, 10, 6, 9));
    for (final issue in store.all) {
      for (final event in issue.events) {
        expect(
          event.at.isBefore(issue.createdAt),
          isFalse,
          reason: '${issue.title} の履歴が追加より前になっている',
        );
      }
    }
  });

  test('一覧に出す担当は「だれでも」と表示する', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(title: '子供の靴を買う');
    expect(store.assigneeWord(issue.assigneeId), 'だれでも');
    store.setAssignee(issue.id, 'partner');
    expect(store.assigneeWord(store.byId(issue.id)!.assigneeId), 'パートナー');
  });

  test('自動生成される次の1件のidは、完了opから決まる', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(
      title: 'お風呂そうじ',
      dueDate: DateTime(2026, 10, 6),
      recurrence: Recurrence.daily,
    );
    store.complete(issue.id);

    final completion = store.ops.singleWhere((op) => op.kind == OpKind.complete);
    final next = store.openIssues.single;
    expect(next.id, nextIssueId(completion.id), reason: 'どちらの端末が完了しても、同じidになる');
    expect(store.byId(issue.id)!.generatedNextId, nextIssueId(completion.id));
  });

  test('取り消して、もう一度完了しても、見える未完了は1つだけ', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(
      title: 'お風呂そうじ',
      dueDate: DateTime(2026, 10, 6),
      recurrence: Recurrence.daily,
    );
    store.complete(issue.id);
    final firstNext = store.openIssues.single;

    store.undoComplete(issue.id);
    expect(store.openIssues.map((i) => i.id), [issue.id]);
    expect(store.byId(firstNext.id), isNull, reason: '見えなくなる（opは残っている）');

    store.complete(issue.id);
    expect(store.openIssues, hasLength(1), reason: '2回目の完了の次の1件だけが見える');
    expect(
      store.ops.where((op) => op.kind == OpKind.complete),
      hasLength(2),
      reason: 'opは追記のみ。取り消しで消していない',
    );
    expect(store.ops.where((op) => op.kind == OpKind.reopen), hasLength(1));
  });

  test('2台が同じop集合を持てば、同じ画面になる', () {
    final a = IssueStore(deviceId: 'A', clock: () => DateTime(2026, 10, 6, 9));
    final issue = a.add(
      title: 'お風呂そうじ',
      dueDate: DateTime(2026, 10, 6),
      recurrence: Recurrence.daily,
    );
    a.complete(issue.id);
    a.comment(issue.id, 'ひとこと');

    final b = IssueStore(deviceId: 'B', clock: () => DateTime(2026, 10, 6, 10));
    b.receive(a.ops);

    expect(b.all.map((i) => i.id).toSet(), a.all.map((i) => i.id).toSet());
    expect(b.openIssues.map((i) => i.id).toSet(), a.openIssues.map((i) => i.id).toSet());
    expect(b.openIssues.single.title, 'お風呂そうじ');
    expect(b.openIssues.single.dueDate, DateTime(2026, 10, 7));
    expect(b.ops.map((op) => op.id).toSet(), a.ops.map((op) => op.id).toSet());
    expect(b.byId(issue.id)!.seriesKey, a.byId(issue.id)!.seriesKey);
  });

  test('画面に見えるものは、いつもop logの射影と一致する', () {
    final store = storeAt(DateTime(2026, 10, 6, 9));
    final issue = store.add(
      title: 'お風呂そうじ',
      dueDate: DateTime(2026, 10, 6),
      recurrence: Recurrence.daily,
    );
    store.complete(issue.id);
    store.undoComplete(issue.id);
    store.comment(issue.id, 'ひとこと');
    store.setStatus(issue.id, IssueStatus.waiting);

    final tasks = project(store.ops);
    expect(
      store.all.map((i) => i.id).toSet(),
      tasks.values.where((t) => t.isVisible).map((t) => t.id).toSet(),
      reason: '見えているものは、射影が隠していないものと一致する',
    );
    expect(
      store.openIssues.map((i) => i.id).toSet(),
      tasks.values.where((t) => t.isOpen).map((t) => t.id).toSet(),
    );
    expect(store.byId(issue.id)!.status, IssueStatus.waiting);
  });
}
