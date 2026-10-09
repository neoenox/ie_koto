import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/sync/log.dart';

/// ランダムな操作列を何百通りも当てて、
/// 「どの端末でも同じ状態になる」と「同じ定期案件が2つ同時に見えない」を壊しにいく。
///
/// seed を固定しているので、落ちたときはその番号でそのまま再現できる。
const int _seeds = 80;
const int _stepsPerSeed = 350;
const int _deviceCount = 3;

void main() {
  test('ランダム操作を当てても、最後にはどの端末も同じ状態になる', () {
    final failures = <String>[];

    for (var seed = 0; seed < _seeds; seed++) {
      failures.addAll(_simulate(seed));
      if (failures.isNotEmpty) break;
    }

    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('opの並べ方が違っても、同じ集合なら同じ結果になる', () {
    final random = Random(20261006);
    final devices = [Device('A'), Device('B')];
    final server = <Op>[];

    for (var i = 0; i < 800; i++) {
      final device = devices[random.nextInt(devices.length)];
      final visible = project(
        device.log,
      ).values.where((t) => t.isVisible).toList();
      if (visible.isEmpty || random.nextDouble() < 0.45) {
        _add(random, device, 'task-$i', i);
      } else {
        _mutate(random, device, visible[random.nextInt(visible.length)], i, i);
      }
    }
    _syncAll(server, devices);

    final forward = mergeOps(devices[0].log, devices[1].log);
    final reversed = mergeOps(
      devices[1].log.reversed.toList(),
      devices[0].log.reversed.toList(),
    );

    expect(_summary(project(forward)), _summary(project(reversed)));
  });
}

/// 1つのseedぶんのシミュレーション。見つけた違反を返す（空なら健全）。
List<String> _simulate(int seed) {
  final random = Random(seed);
  final devices = [for (var i = 0; i < _deviceCount; i++) Device('D$i')];
  final server = <Op>[]; // 世帯のopを預かる場所（GET /ops と POST /ops のイメージ）
  var issueSeq = 0;
  var opSeq = 0;

  for (var step = 0; step < _stepsPerSeed; step++) {
    final device = devices[random.nextInt(devices.length)];
    final visible = project(
      device.log,
    ).values.where((t) => t.isVisible).toList();

    if (visible.isEmpty || random.nextDouble() < 0.45) {
      _add(random, device, 'task-${issueSeq++}', step);
    } else {
      _mutate(
        random,
        device,
        visible[random.nextInt(visible.length)],
        step,
        opSeq++,
      );
    }

    // 3割は、誰か1人とだけ合わせる（＝他の端末は知らないまま）
    if (random.nextDouble() < 0.3) {
      final a = devices[random.nextInt(devices.length)];
      final b = devices[random.nextInt(devices.length)];
      if (a != b) _exchange(server, a, b);
    }
    if (random.nextDouble() < 0.2) {
      _runFollowUps(device, step);
    }
  }

  // 最後に全員が何度も同期し、足りない操作を書き切る
  for (var round = 0; round < 200; round++) {
    var wrote = 0;
    for (final device in devices) {
      wrote += _runFollowUps(device, _stepsPerSeed + round).length;
    }
    _syncAll(server, devices);
    if (wrote == 0 && devices.every((d) => d.outbox.isEmpty)) break;
  }

  final truth = project(mergeOps(server, const <Op>[]));
  final violations = <String>[];

  // 1. どの端末も同じ状態になっているか
  final expected = _summary(truth);
  for (final device in devices) {
    if (!_sameMap(_summary(project(device.log)), expected)) {
      violations.add('seed=$seed ${device.id} が他の端末と一致しない');
    }
  }

  // 2. 同じ定期案件が、同時に2つ見えていないか
  final openBySeries = <String, List<String>>{};
  for (final task in truth.values.where((t) => t.isOpen)) {
    final series = task.seriesId ?? task.id;
    openBySeries.putIfAbsent(series, () => <String>[]).add(task.id);
  }
  openBySeries.forEach((series, ids) {
    if (ids.length > 1) {
      violations.add('seed=$seed 同じ系列 $series に未完了が${ids.length}件: $ids');
    }
  });

  // 3. 見えている案件の中に、見えてはいけない派生（元を失ったもの）が混じっていないか
  for (final task in truth.values.where((t) => t.isVisible)) {
    if (!task.isDerived) continue;
    final origin = truth[task.originIssueId];
    final ok =
        origin != null &&
        !origin.orphaned &&
        origin.standingCompletionOpId == task.derivedFrom;
    if (!ok) {
      violations.add('seed=$seed 元を失った派生案件が見えている: ${task.id}');
    }
  }

  // 4. 定期案件で有効な完了があるなら、次の1件が存在しているか
  //    （利用者が消した場合は、消えたままにしておくのが正しい）
  //    元の案件が消されていても、完了が有効なら連なりは続く。
  for (final task in truth.values) {
    if (task.orphaned) continue;
    final completion = task.standingCompletionOpId;
    if (completion == null || task.recurrence.isNone) continue;
    final next = truth[nextIssueId(completion)];
    if (next == null) {
      violations.add('seed=$seed 完了したのに次の1件が作られていない: ${task.id}');
    } else if (!next.isVisible && !next.deleted) {
      violations.add('seed=$seed 次の1件の行方が分からない: ${next.id}');
    }
  }

  // 5. タイトルの無い案件が見えていないか
  for (final task in truth.values.where((t) => t.isVisible)) {
    if (task.title.trim().isEmpty) {
      violations.add('seed=$seed タイトルの無い案件が見えている: ${task.id}');
    }
  }

  return violations;
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

void _mutate(Random random, Device device, Task target, int step, int opSeq) {
  final at = DateTime(2026, 10, 1).add(Duration(minutes: step, seconds: opSeq));

  switch (random.nextInt(9)) {
    case 0:
      device.write(
        OpKind.rename,
        target.id,
        data: <String, Object?>{'title': '直した$opSeq'},
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
        data: <String, Object?>{'text': 'メモ$opSeq'},
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

/// 2台だけ合わせる。他の端末は知らないまま。
void _exchange(List<Op> server, Device a, Device b) {
  server.addAll(a.takeOutbox());
  server.addAll(b.takeOutbox());
  a.receive(server);
  b.receive(server);
}

/// 全員がサーバーに送り、全員がサーバーから受け取る。
void _syncAll(List<Op> server, List<Device> devices) {
  for (final device in devices) {
    server.addAll(device.takeOutbox());
  }
  for (final device in devices) {
    device.receive(server);
  }
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
      ].join('|'),
};

bool _sameMap(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
