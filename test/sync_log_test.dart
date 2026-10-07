import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/sync/log.dart';

/// 見比べるための要約。両端末でこれが一致すれば収束している。
Map<String, String> summary(Map<String, Task> tasks) => {
      for (final task in tasks.values)
        if (task.isVisible)
          task.id: [
            task.title,
            task.status.name,
            task.dueDate?.toIso8601String() ?? '-',
            task.recurrence.label,
            task.comments.join(','),
            task.derivedFrom ?? '-',
          ].join('|'),
    };

List<Task> openTasks(Map<String, Task> tasks) => tasks.values.where((t) => t.isOpen).toList();

void main() {
  test('2台がオフラインで別々に完了しても、次の1件は1つだけ', () {
    final a = Device('A');
    a.write(
      OpKind.add,
      'a1',
      data: <String, Object?>{
        'title': 'お風呂そうじ',
        'dueDate': DateTime(2026, 10, 6),
        'recurrence': Recurrence.daily,
      },
      at: DateTime(2026, 10, 6, 8),
    );

    // 最初の同期。ここから2台はオフラインになる。
    final b = Device('B')..receive(a.takeOutbox());

    // Aは朝に完了、Bは夜に完了（お互いを知らないまま）
    a.write(OpKind.complete, 'a1', at: DateTime(2026, 10, 6, 9));
    writeMissingFollowUps(project(a.log), a, at: DateTime(2026, 10, 6, 9));

    b.write(OpKind.complete, 'a1', at: DateTime(2026, 10, 6, 20));
    writeMissingFollowUps(project(b.log), b, at: DateTime(2026, 10, 6, 20));

    // 突き合わせる
    final merged = mergeOps(a.log, b.log);
    final tasks = project(merged);
    final standing = tasks['a1']!.standingCompletionOpId!;
    final open = openTasks(tasks);

    expect(standing, 'A:2', reason: '有効な完了は、論理時計の早い方1つだけ');
    expect(open, hasLength(1), reason: 'お風呂そうじの次の1件は1つだけ');
    expect(open.single.id, nextIssueId(standing));
    expect(open.single.title, 'お風呂そうじ');
    expect(open.single.dueDate, DateTime(2026, 10, 7));

    // 相手の知らないうちに作られた「もう1つの次の1件」は、見えなくなる
    a.receive(merged);
    b.receive(merged);
    writeMissingFollowUps(project(a.log), a, at: DateTime(2026, 10, 6, 21));
    writeMissingFollowUps(project(b.log), b, at: DateTime(2026, 10, 6, 21));

    final after = project(mergeOps(a.log, b.log));
    expect(openTasks(after), hasLength(1));
    expect(summary(after), summary(project(mergeOps(b.log, a.log))), reason: 'どちらの端末でも同じ結果');
  });

  test('取り消すと、そこから生まれた次の1件も消える', () {
    final a = Device('A');
    a.write(
      OpKind.add,
      'a1',
      data: <String, Object?>{
        'title': 'お風呂そうじ',
        'dueDate': DateTime(2026, 10, 6),
        'recurrence': Recurrence.daily,
      },
      at: DateTime(2026, 10, 6, 8),
    );
    a.write(OpKind.complete, 'a1', at: DateTime(2026, 10, 6, 9));
    writeMissingFollowUps(project(a.log), a, at: DateTime(2026, 10, 6, 9));
    expect(openTasks(project(a.log)), hasLength(1));

    a.write(OpKind.reopen, 'a1', at: DateTime(2026, 10, 6, 9, 5));
    writeMissingFollowUps(project(a.log), a, at: DateTime(2026, 10, 6, 9, 5));

    final tasks = project(a.log);
    expect(tasks['a1']!.status, IssueStatus.open);
    expect(tasks[nextIssueId('A:2')]!.isVisible, isFalse, reason: '元を失った「次の1件」は見えない');
    expect(openTasks(tasks), hasLength(1));
    expect(openTasks(tasks).single.id, 'a1');
  });

  test('完了済みを「対応待ち」に戻すと、次の1件は見えなくなる', () {
    final a = Device('A');
    a.write(
      OpKind.add,
      'a1',
      data: <String, Object?>{
        'title': 'お風呂そうじ',
        'dueDate': DateTime(2026, 10, 6),
        'recurrence': Recurrence.daily,
      },
    );
    final completion = a.write(OpKind.complete, 'a1');
    writeMissingFollowUps(project(a.log), a);
    expect(openTasks(project(a.log)), hasLength(1));

    // 完了状態のまま「対応待ち」に戻す（画面の「やることにもどす」）
    a.write(OpKind.status, 'a1', data: <String, Object?>{'status': IssueStatus.waiting});

    final tasks = project(a.log);
    expect(tasks['a1']!.status, IssueStatus.waiting);
    expect(tasks[nextIssueId(completion.id)]!.isVisible, isFalse);
    expect(openTasks(tasks).single.id, 'a1');
  });

  test('消した「次の1件」は、あとから作り直さない', () {
    final a = Device('A');
    a.write(
      OpKind.add,
      'a1',
      data: <String, Object?>{'title': 'お風呂そうじ', 'recurrence': Recurrence.daily},
    );
    final completion = a.write(OpKind.complete, 'a1');
    writeMissingFollowUps(project(a.log), a);

    final nextId = nextIssueId(completion.id);
    a.write(OpKind.delete, nextId);

    expect(writeMissingFollowUps(project(a.log), a), isEmpty, reason: '消したものを勝手に戻さない');
    expect(project(a.log)[nextId]!.isVisible, isFalse);
  });

  test('元を失った1件から更に生まれた1件も、まとめて見えなくなる', () {
    final a = Device('A');
    a.write(
      OpKind.add,
      'a1',
      data: <String, Object?>{
        'title': 'エアコンのフィルターそうじ',
        'dueDate': DateTime(2026, 10, 6),
        'recurrence': Recurrence.daily,
      },
    );
    final firstCompletion = a.write(OpKind.complete, 'a1');
    writeMissingFollowUps(project(a.log), a);

    final second = nextIssueId(firstCompletion.id);
    final secondCompletion = a.write(OpKind.complete, second);
    writeMissingFollowUps(project(a.log), a);
    final third = nextIssueId(secondCompletion.id);
    expect(openTasks(project(a.log)).single.id, third);

    // 元の案件を取り消すと、連鎖して生まれた1件まで見えなくなる
    a.write(OpKind.reopen, 'a1');

    final tasks = project(a.log);
    expect(tasks[second]!.isVisible, isFalse);
    expect(tasks[third]!.isVisible, isFalse);
    expect(openTasks(tasks).single.id, 'a1');
  });

  test('完了済みの元を消しても、次の1件とその先の連なりは残る', () {
    final a = Device('A');
    a.write(
      OpKind.add,
      'a1',
      data: <String, Object?>{
        'title': 'お風呂そうじ',
        'dueDate': DateTime(2026, 10, 6),
        'recurrence': Recurrence.daily,
      },
    );
    final firstCompletion = a.write(OpKind.complete, 'a1');
    writeMissingFollowUps(project(a.log), a);
    final second = nextIssueId(firstCompletion.id);
    final secondCompletion = a.write(OpKind.complete, second);
    writeMissingFollowUps(project(a.log), a);
    final third = nextIssueId(secondCompletion.id);

    // 過去の記録を整理するつもりで、元の案件を消す
    a.write(OpKind.delete, 'a1');

    final tasks = project(a.log);
    expect(tasks['a1']!.isVisible, isFalse);
    expect(tasks[second]!.isVisible, isTrue);
    expect(openTasks(tasks).single.id, third);
    expect(writeMissingFollowUps(tasks, a), isEmpty);
  });

  test('元が消されたあとに完了が届いても、次の1件は作られる', () {
    final a = Device('A');
    final b = Device('B');
    a.write(
      OpKind.add,
      'a1',
      data: <String, Object?>{'title': 'お風呂そうじ', 'recurrence': Recurrence.daily},
    );
    b.receive(a.takeOutbox());

    // A は完了、B は同時に消す（どちらもオフライン）
    final completion = a.write(OpKind.complete, 'a1');
    b.write(OpKind.delete, 'a1');
    b.receive(a.takeOutbox());
    a.receive(b.takeOutbox());

    final writes = writeMissingFollowUps(project(b.log), b);
    expect(writes.single.issueId, nextIssueId(completion.id));
    expect(openTasks(project(b.log)).single.id, nextIssueId(completion.id));
  });

  test('定期でない案件を完了しても、次の1件は作らない', () {
    final a = Device('A');
    a.write(OpKind.add, 'x', data: <String, Object?>{'title': '牛乳を買う'});
    a.write(OpKind.complete, 'x');
    expect(writeMissingFollowUps(project(a.log), a), isEmpty);
  });

  test('別々に追加したものは、両方とも残る', () {
    final a = Device('A')..write(OpKind.add, 'a1', data: <String, Object?>{'title': 'Aのぶん'});
    final b = Device('B')..write(OpKind.add, 'b1', data: <String, Object?>{'title': 'Bのぶん'});

    final tasks = project(mergeOps(a.log, b.log));
    final open = openTasks(tasks);
    expect(open, hasLength(2));
    expect(open.map((t) => t.title).toSet(), {'Aのぶん', 'Bのぶん'});
  });

  test('同時についたコメントは両方残り、並びも同じになる', () {
    final a = Device('A');
    a.write(OpKind.add, 'x', data: <String, Object?>{'title': '電球'}, at: DateTime(2026, 10, 6, 8));
    final b = Device('B')..receive(a.takeOutbox());

    a.write(OpKind.comment, 'x', data: <String, Object?>{'text': 'Aから'}, at: DateTime(2026, 10, 6, 9));
    b.write(OpKind.comment, 'x', data: <String, Object?>{'text': 'Bから'}, at: DateTime(2026, 10, 6, 9));

    final tasks = project(mergeOps(a.log, b.log));
    expect(tasks['x']!.comments, ['Aから', 'Bから']);
    expect(project(mergeOps(b.log, a.log))['x']!.comments, ['Aから', 'Bから']);
  });

  test('端末の時計がずれていても、順序は論理時計で決まる', () {
    final a = Device('A');
    a.write(OpKind.add, 'x', data: <String, Object?>{'title': 'もとの名前'}, at: DateTime(2026, 10, 6, 10));

    final b = Device('B')..receive(a.takeOutbox());
    // Bの時計は1時間遅れている。それでもBの変更が後になる。
    b.write(OpKind.rename, 'x', data: <String, Object?>{'title': 'Bが直した'}, at: DateTime(2026, 10, 6, 9));

    final tasks = project(mergeOps(a.log, b.log));
    expect(tasks['x']!.title, 'Bが直した');
  });

  test('相手のopを受け取ると、次の番号は相手より後になる', () {
    final a = Device('A');
    a.write(OpKind.add, 'a1', data: <String, Object?>{'title': 'Aのぶん'});
    expect(a.lamport, 1);

    final b = Device('B')..receive(a.takeOutbox());
    b.write(OpKind.add, 'b1', data: <String, Object?>{'title': 'Bのぶん'});
    expect(b.lamport, 2);

    // 同じopを2回受け取っても増えない
    b.receive(a.log);
    expect(b.lamport, 2);
  });

  test('同じop集合なら、並べる順が違っても同じ結果になる', () {
    final a = Device('A');
    a.write(OpKind.add, 'a1', data: <String, Object?>{'title': 'Aのぶん'}, at: DateTime(2026, 10, 6, 8));
    final b = Device('B')..receive(a.takeOutbox());
    b.write(OpKind.add, 'b1', data: <String, Object?>{'title': 'Bのぶん'}, at: DateTime(2026, 10, 6, 9));
    a.receive(b.takeOutbox());

    expect(summary(project(mergeOps(a.log, b.log))), summary(project(mergeOps(b.log, a.log))));
  });
}
