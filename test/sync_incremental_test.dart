import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/sync/log.dart';

/// 増分同期（`GET /ops?household=<id>&since=<cursor>`）の取りこぼしを突く。
///
/// 方針（docs/SYNC_DESIGN.md）:
/// - サーバーは挿入順に単調増加する cursor を振る。差分は「cursor より後」を順に返す。
/// - 端末は「ここまでもらった」cursor を覚え、次はその続きからもらう。
/// - 追記のみ・op_id が主キーなので、重複も順不同も受け取って構わない。
///
/// ここで確かめたいのは2つ。
/// 1. **欠けても壊れない**: 差分が抜けても、その端末の射影は自己整合のままであること
///    （同じ系列の未完了が2つ見えない／元を失った派生が見えない）。
/// 2. **いつか必ず直る**: 全件を取り直せば、どの端末も同じ状態へ収束すること。
///
/// cursor は端末任せなので、巻き戻し（重複配信）と飛び越し（取りこぼし）の両方を混ぜる。
const int _seeds = 200;
const int _stepsPerSeed = 250;
const int _deviceCount = 3;

void main() {
  test('取りこぼし・重複・順不同が混ざっても、途中で壊れず、最後には全端末が同じ状態になる', () {
    final failures = <String>[];
    for (var seed = 0; seed < _seeds; seed++) {
      failures.addAll(_simulate(seed));
      if (failures.isNotEmpty) break;
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('差分の途中が抜けても、その端末は自己整合のままになる', () {
    final server = _Household();
    final a = _Client(Device('A'));
    final b = _Client(Device('B'));

    // A が定期案件を作って完了し、次の1件が生まれる。
    a.device.write(
      OpKind.add,
      'a1',
      data: <String, Object?>{
        'title': 'お風呂そうじ',
        'dueDate': DateTime(2026, 10, 6),
        'recurrence': Recurrence.daily,
      },
      at: DateTime(2026, 10, 6, 8),
    );
    server.postAll(a.device.takeOutbox());
    a.device.write(OpKind.complete, 'a1', at: DateTime(2026, 10, 6, 9));
    _runFollowUps(a.device, 1);
    server.postAll(a.device.takeOutbox());

    // B には「完了op」だけが届かず、次の1件（派生）だけが先に届く。
    final pending = server.since(b.cursor);
    expect(pending, hasLength(3), reason: 'add / complete / 次の1件');
    b.device.receive([pending[0], pending[2]]);
    b.cursor = server.cursor; // ← 抜けたぶんを取り戻さないまま先へ進む

    final gapped = project(b.device.log);
    expect(openTasks(gapped).map((t) => t.id), [
      'a1',
    ], reason: '完了が届いていないので、まだ元の1件が開いている');
    expect(
      gapped[nextIssueId(pending[1].id)]!.isVisible,
      isFalse,
      reason: '元を失った派生は見えない',
    );
    expect(_structuralViolations(gapped), isEmpty, reason: '欠けていても射影は自己整合');
    expect(_completionViolations(gapped), isEmpty);

    // 全件を取り直すと、必ず元の姿に戻る。
    b.device.receive(server.since(0));
    b.cursor = server.cursor;

    final healed = project(b.device.log);
    expect(openTasks(healed).map((t) => t.id), [
      nextIssueId(pending[1].id),
    ], reason: '完了が届けば、次の1件に入れ替わる');
    expect(_summary(healed), _summary(project(server.ops)));
  });

  test('途中の1件がまるごと抜けても、同じ定期案件が2つ見えない', () {
    final server = _Household();
    final a = _Client(Device('A'));
    final b = _Client(Device('B'));

    // A が作って、2回続けて完了する（task-34 → next:A:2 → next:A:4）。
    a.device.write(
      OpKind.add,
      'task-34',
      data: <String, Object?>{
        'title': 'お風呂そうじ',
        'dueDate': DateTime(2026, 10, 1),
        'recurrence': Recurrence.daily,
      },
      at: DateTime(2026, 10, 1, 8),
    );
    a.device.write(OpKind.complete, 'task-34', at: DateTime(2026, 10, 2, 8));
    _runFollowUps(a.device, 2);
    a.device.write(
      OpKind.complete,
      nextIssueId('A:2'),
      at: DateTime(2026, 10, 3, 8),
    );
    _runFollowUps(a.device, 3);
    server.postAll(a.device.takeOutbox());

    // B は「task-34の完了」と「その次の1件のadd」を丸ごと取りこぼす。
    // 系列のつながりが切れるので、放置すると元の1件と先の1件が同時に見えてしまう。
    final all = server.since(0);
    final complete34 = all.firstWhere(
      (op) => op.kind == OpKind.complete && op.issueId == 'task-34',
    );
    final addNext = all.firstWhere(
      (op) => op.kind == OpKind.add && op.issueId == nextIssueId(complete34.id),
    );
    final delivered = all
        .where((op) => op.id != complete34.id && op.id != addNext.id)
        .toList();
    b.device.receive(delivered);
    b.cursor = server.cursor; // ← 欠けたまま先へ進む

    final gapped = project(b.device.log);
    expect(openTasks(gapped).map((t) => t.id), [
      nextIssueId('A:4'),
    ], reason: '見えている中でいちばん新しい1件だけが開いている');
    expect(_structuralViolations(gapped), isEmpty);

    // 抜けた1件が届けば、元の姿（完了している）に戻る。
    b.device.receive(all);
    expect(_summary(project(b.device.log)), _summary(project(server.ops)));
    expect(openTasks(project(b.device.log)).map((t) => t.id), [
      nextIssueId('A:4'),
    ]);
  });

  test('同じ差分を何度もらっても、状態は変わらない', () {
    final server = _Household();
    final a = _Client(Device('A'));

    a.device.write(
      OpKind.add,
      'x',
      data: <String, Object?>{'title': '電球'},
      at: DateTime(2026, 10, 6, 8),
    );
    a.device.write(
      OpKind.comment,
      'x',
      data: <String, Object?>{'text': '口金E26'},
      at: DateTime(2026, 10, 6, 9),
    );
    server.postAll(a.device.takeOutbox());

    final b = _Client(Device('B'));
    final diff = server.since(b.cursor);
    b.device.receive(diff);
    final once = _summary(project(b.device.log));
    final logLength = b.device.log.length;

    // cursor を巻き戻して同じ差分を3回もらう。
    for (var i = 0; i < 3; i++) {
      b.device.receive(server.since(0));
    }
    expect(b.device.log.length, logLength, reason: '同じopは1つに畳まれる');
    expect(_summary(project(b.device.log)), once);
    expect(project(b.device.log)['x']!.comments, [
      '口金E26',
    ], reason: 'コメントが増殖しない');
  });

  test('順不同で届いても、順に届いても同じ結果になる', () {
    final server = _Household();
    final a = _Client(Device('A'));

    a.device.write(
      OpKind.add,
      'a1',
      data: <String, Object?>{
        'title': 'フィルター',
        'recurrence': Recurrence.every(90),
      },
      at: DateTime(2026, 10, 1, 8),
    );
    a.device.write(
      OpKind.rename,
      'a1',
      data: <String, Object?>{'title': 'エアコンのフィルター'},
      at: DateTime(2026, 10, 2, 8),
    );
    a.device.write(OpKind.complete, 'a1', at: DateTime(2026, 10, 3, 8));
    _runFollowUps(a.device, 3);
    server.postAll(a.device.takeOutbox());

    final diff = server.since(0);
    final forward = Device('B')..receive(diff);
    final shuffled = Device('C')
      ..receive(diff.reversed.toList()..shuffle(Random(7)));

    expect(_summary(project(forward.log)), _summary(project(shuffled.log)));
    expect(_summary(project(forward.log)), _summary(project(server.ops)));
  });

  test('POSTの二重送信では、cursorは進まない', () {
    final server = _Household();
    final a = Device('A');
    final op = a.write(OpKind.add, 'x', data: <String, Object?>{'title': '牛乳'});

    final first = server.postAll([op]);
    final cursorAfterFirst = server.cursor;
    final second = server.postAll([op]);

    expect(first, hasLength(1));
    expect(second, isEmpty, reason: 'op_idが同じなら二重登録しない');
    expect(server.cursor, cursorAfterFirst, reason: 'cursorは増えない');
    expect(server.ops, hasLength(1));
  });
}

/// 1つのseedぶんのシミュレーション。見つけた違反を返す（空なら健全）。
List<String> _simulate(int seed) {
  final random = Random(seed);
  final server = _Household();
  final clients = [
    for (var i = 0; i < _deviceCount; i++) _Client(Device('D$i')),
  ];
  final violations = <String>[];
  var issueSeq = 0;

  for (var step = 0; step < _stepsPerSeed; step++) {
    final client = clients[random.nextInt(clients.length)];

    // オフラインでも自由に書ける（追記のみ）。
    final visible = project(
      client.device.log,
    ).values.where((t) => t.isVisible).toList();
    if (visible.isEmpty || random.nextDouble() < 0.45) {
      _add(random, client.device, 'task-${issueSeq++}', step);
    } else {
      _mutate(
        random,
        client.device,
        visible[random.nextInt(visible.length)],
        step,
      );
    }

    // 送信は成功したことにする（POSTは二重送信安全なので、届かなくても後で直る）。
    if (random.nextDouble() < 0.5) {
      server.postAll(client.device.takeOutbox());
    }

    // 差分取得。ここをわざと壊す（欠け・重複・順不同・巻き戻し・飛び越し）。
    if (random.nextDouble() < 0.6) {
      final pull = _pull(
        server,
        client.cursor,
        random,
        mode: _randomMode(random),
      );
      client.device.receive(pull.ops);
      client.cursor = pull.cursor;
    }

    // 取り損ねた完了の「次の1件」を、その場で書く。
    if (random.nextDouble() < 0.3) {
      _runFollowUps(client.device, step);
    }

    // 欠けていても、射影そのものは自己整合のはず。
    for (final bad in _structuralViolations(project(client.device.log))) {
      violations.add('seed=$seed step=$step ${client.device.id}: $bad');
    }
    if (violations.isNotEmpty) return violations;
  }

  // 最後は全員が全件を取り直し、足りない操作を書き切る。
  final truth = _converge(server, clients);
  final expected = _summary(truth);

  for (final client in clients) {
    if (!_sameMap(_summary(project(client.device.log)), expected)) {
      violations.add('seed=$seed ${client.device.id} が真実と一致しない');
    }
  }
  for (final bad in _structuralViolations(truth)) {
    violations.add('seed=$seed 真実: $bad');
  }
  for (final bad in _completionViolations(truth)) {
    violations.add('seed=$seed 真実: $bad');
  }
  // 全件そろったあとは、追い越しによる非表示は1件も残っていないはず
  // （残っていたら、見えるべき案件を隠してしまっている）。
  for (final task in truth.values.where((t) => t.superseded)) {
    violations.add('seed=$seed 収束しても追い越されたまま隠れている: ${task.id}');
  }
  return violations;
}

/// 全員が全件を取り直して、足りない操作を書き切るまで回す。収束後のサーバー状態を返す。
Map<String, Task> _converge(_Household server, List<_Client> clients) {
  for (var round = 0; round < 400; round++) {
    // 先に全件を取り直して、前のラウンドの書き込みを全員に行き渡らせる。
    // （これを先にやらないと、まだ何も知らない端末の状態で「書くものが無い」と誤判定する）
    for (final client in clients) {
      client.device.receive(server.since(0));
      client.cursor = server.cursor;
    }
    var wrote = 0;
    for (final client in clients) {
      wrote += _runFollowUps(client.device, _stepsPerSeed + round).length;
    }
    for (final client in clients) {
      server.postAll(client.device.takeOutbox());
    }
    if (wrote == 0) break;
  }
  // 最後に書いたぶんも、全員に行き渡らせる。
  for (final client in clients) {
    client.device.receive(server.since(0));
    client.cursor = server.cursor;
  }
  return project(server.ops);
}

/// サーバーの物真似。世帯ごとにopを預かり、挿入順に単調増加する cursor を振る。
class _Household {
  final List<Op> ops = <Op>[];
  final Map<String, int> _cursorOfOp = <String, int>{};

  /// 次にもらうべき位置。opを1つ預かるごとに1増える。
  int get cursor => ops.length;

  /// POST /ops。op_id が主キーなので、二重送信しても増えない。増やしたopを返す。
  List<Op> postAll(Iterable<Op> incoming) {
    final added = <Op>[];
    for (final op in incoming) {
      if (_cursorOfOp.containsKey(op.id)) continue;
      ops.add(op);
      _cursorOfOp[op.id] = ops.length;
      added.add(op);
    }
    return added;
  }

  /// `GET /ops?since=<cursor>` のように、cursor より後のopを、挿入順で返す。
  List<Op> since(int cursor) {
    final start = cursor < 0 ? 0 : (cursor > ops.length ? ops.length : cursor);
    return ops.sublist(start);
  }
}

/// 1台の端末と、その端末が思っている「ここまでもらった」位置。
class _Client {
  _Client(this.device);

  final Device device;
  int cursor = 0;
}

/// 差分取得の壊し方。
enum _Mode { clean, truncated, duplicated, shuffled, rewind, jump }

_Mode _randomMode(Random random) => switch (random.nextInt(10)) {
  0 || 1 || 2 => _Mode.truncated,
  3 || 4 => _Mode.duplicated,
  5 || 6 => _Mode.shuffled,
  7 => _Mode.rewind,
  8 => _Mode.jump,
  _ => _Mode.clean,
};

/// サーバーから1回もらう。わざと壊す場合もある。
class _Pull {
  _Pull(this.ops, this.cursor);
  final List<Op> ops;
  final int cursor;
}

_Pull _pull(
  _Household server,
  int since,
  Random random, {
  required _Mode mode,
}) {
  var delivered = server.since(since);
  var cursor = server.cursor;

  switch (mode) {
    case _Mode.clean:
      break;
    case _Mode.truncated:
      // 応答の途中が抜ける。それでも端末は cursor を進めてしまう（＝取りこぼし）。
      if (delivered.length > 1) {
        final from = random.nextInt(delivered.length - 1);
        final count = 1 + random.nextInt(delivered.length - from - 1);
        delivered = [...delivered.take(from), ...delivered.skip(from + count)];
      }
    case _Mode.duplicated:
      // すでにもらったぶんも、もう一度送られてくる。
      final replayFrom = max(0, since - (1 + random.nextInt(4)));
      delivered = server.since(replayFrom);
    case _Mode.shuffled:
      // 順不同で届く。
      delivered = [...delivered]..shuffle(random);
    case _Mode.rewind:
      // cursor を巻き戻す（次は同じ差分をもう一度もらう）。
      cursor = max(0, cursor - (1 + random.nextInt(3)));
    case _Mode.jump:
      // cursor を飛び越す（間のopは、全件取り直すまで届かない）。
      cursor = cursor + 1 + random.nextInt(3);
  }
  return _Pull(delivered, cursor);
}

void _add(Random random, Device device, String id, int step) {
  final recurrence = switch (random.nextInt(4)) {
    0 => Recurrence.none,
    1 => Recurrence.daily,
    2 => Recurrence.onWeekdays({
      if (random.nextBool()) DateTime.tuesday,
      if (random.nextBool()) DateTime.friday,
      if (random.nextBool()) DateTime.sunday,
    }),
    _ => Recurrence.every(7 * (1 + random.nextInt(4))),
  };
  device.write(
    OpKind.add,
    id,
    data: <String, Object?>{
      'title': '案件$id',
      'recurrence': recurrence,
      'dueDate': DateTime(2026, 10, 1 + random.nextInt(28)),
      'assigneeId': random.nextBool() ? 'me' : null,
    },
    at: DateTime(2026, 10, 1).add(Duration(minutes: step)),
  );
}

void _mutate(Random random, Device device, Task target, int step) {
  final at = DateTime(
    2026,
    10,
    1,
  ).add(Duration(minutes: step, seconds: random.nextInt(60)));

  switch (random.nextInt(9)) {
    case 0:
      device.write(
        OpKind.rename,
        target.id,
        data: <String, Object?>{'title': '直した$step'},
        at: at,
      );
    case 1:
      device.write(
        OpKind.assignee,
        target.id,
        data: <String, Object?>{
          'assigneeId': random.nextBool() ? 'partner' : null,
        },
        at: at,
      );
    case 2:
      device.write(
        OpKind.due,
        target.id,
        data: <String, Object?>{
          'dueDate': DateTime(2026, 11, 1 + random.nextInt(20)),
        },
        at: at,
      );
    case 3:
      device.write(
        OpKind.recurrence,
        target.id,
        data: <String, Object?>{'recurrence': Recurrence.every(30)},
        at: at,
      );
    case 4:
      device.write(
        OpKind.comment,
        target.id,
        data: <String, Object?>{'text': 'メモ$step'},
        at: at,
      );
    case 5:
      device.write(
        OpKind.status,
        target.id,
        data: <String, Object?>{'status': IssueStatus.waiting},
        at: at,
      );
    case 6:
      device.write(OpKind.complete, target.id, at: at);
      _runFollowUps(device, step);
    case 7:
      if (target.status == IssueStatus.done) {
        device.write(OpKind.reopen, target.id, at: at);
      } else {
        device.write(OpKind.complete, target.id, at: at);
      }
      _runFollowUps(device, step);
    case 8:
      device.write(OpKind.delete, target.id, at: at);
  }
}

List<Op> _runFollowUps(Device device, int step) => writeMissingFollowUps(
  project(device.log),
  device,
  at: DateTime(2026, 10, 1).add(Duration(minutes: step + 1)),
);

List<Task> openTasks(Map<String, Task> tasks) =>
    tasks.values.where((t) => t.isOpen).toList();

/// どんなop集合でも成り立つはずの不変条件（欠けていても壊れない）。
List<String> _structuralViolations(Map<String, Task> tasks) {
  final bad = <String>[];

  // 1. 同じ定期案件が、同時に2つ見えていないか。
  final openBySeries = <String, List<String>>{};
  for (final task in tasks.values.where((t) => t.isOpen)) {
    openBySeries
        .putIfAbsent(task.seriesId ?? task.id, () => <String>[])
        .add(task.id);
  }
  openBySeries.forEach((series, ids) {
    if (ids.length > 1) bad.add('同じ系列 $series に未完了が${ids.length}件: $ids');
  });

  // 2. 元を失った派生（見えてはいけないもの）が混じっていないか。
  for (final task in tasks.values.where((t) => t.isVisible)) {
    if (!task.isDerived) continue;
    final origin = tasks[task.originIssueId];
    final ok =
        origin != null &&
        !origin.orphaned &&
        origin.standingCompletionOpId == task.derivedFrom;
    if (!ok) bad.add('元を失った派生が見えている: ${task.id}');
  }
  return bad;
}

/// 収束後にだけ成り立つ不変条件（全件が揃っていれば、完了には次の1件がある）。
List<String> _completionViolations(Map<String, Task> tasks) {
  final bad = <String>[];
  for (final task in tasks.values) {
    if (task.orphaned) continue;
    final completion = task.standingCompletionOpId;
    if (completion == null || task.recurrence.isNone) continue;
    final next = tasks[nextIssueId(completion)];
    if (next == null) {
      bad.add('完了したのに次の1件が無い: ${task.id}');
    } else if (!next.isVisible && !next.deleted) {
      bad.add('次の1件の行方が不明: ${next.id}');
    }
  }
  return bad;
}

/// 目に見える状態の要約。これが一致すれば収束している。
Map<String, String> _summary(Map<String, Task> tasks) => {
  for (final task in tasks.values)
    if (task.isVisible)
      task.id: [
        task.title,
        task.status.name,
        task.dueDate?.toIso8601String() ?? '-',
        task.recurrence.label,
        task.assigneeId ?? '-',
        task.comments.join(','),
        task.standingCompletionOpId ?? '-',
        task.orphaned ? 'orphan' : '-',
      ].join('|'),
};

bool _sameMap(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
