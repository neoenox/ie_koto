import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/log.dart';
import 'package:ie_koto/sync/session.dart';

import 'support/ops_server.dart';

/// ストアの送信と受信を、**実際のHTTP**につないだ状態で確かめる。
/// サーバー役はテストの中の物真似（[OpsServer]）。本物は server/ の Cloudflare Worker。
void main() {
  late OpsServer server;
  late IssueStore a;
  late IssueStore b;
  late SyncSession sessionA;
  late SyncSession sessionB;

  setUp(() async {
    server = OpsServer();
    await server.start();
    a = _store('A');
    b = _store('B');
    sessionA = _session(a, server);
    sessionB = _session(b, server);
  });

  tearDown(() async {
    sessionA.detach();
    sessionB.detach();
    await server.stop();
  });

  test('片方が追加すると、相手の同期で出てくる（送り返さない）', () async {
    final milk = a.add(title: '牛乳を買う', dueDate: DateTime(2026, 10, 6));

    final first = await sessionA.syncNow();
    expect(first.sent, 1);
    expect(first.received, 0);
    expect(a.outbox, isEmpty, reason: '送れたぶんは送信待ちから外れる');

    final second = await sessionB.syncNow();
    expect(second.received, 1);
    expect(b.byId(milk.id)?.title, '牛乳を買う');
    expect(b.byId(milk.id)?.dueDate, DateTime(2026, 10, 6));
    expect(b.outbox, isEmpty, reason: 'もらったopを送り返さない');

    expect(_view(b), _view(a), reason: '同じop集合なら、同じ画面になる');
  });

  test('完了すると、相手にも同じ「次の1件」が出る', () async {
    a.add(title: 'お風呂そうじ', dueDate: DateTime(2026, 10, 6), recurrence: Recurrence.daily);
    await sessionA.syncNow();
    await sessionB.syncNow();

    final onB = b.openIssues.single;
    b.complete(onB.id);
    await sessionB.syncNow();
    await sessionA.syncNow();

    // どちらの端末でも、次の1件は「決定的なid」で1つだけ。
    final nextId = nextIssueId(b.ops.firstWhere((op) => op.kind == OpKind.complete).id);
    expect(a.byId(nextId)?.isDone, isFalse);
    expect(b.byId(nextId)?.isDone, isFalse);
    expect(a.openIssues.map((issue) => issue.id), <String>[nextId]);
    expect(b.openIssues.map((issue) => issue.id), <String>[nextId]);
    expect(a.byId(nextId)?.dueDate, DateTime(2026, 10, 7), reason: '完了した日の翌日');
    expect(_view(b), _view(a));
  });

  test('2台が別々に完了しても、見えている未完了は1つだけ', () async {
    a.add(title: 'ゴミ出し', dueDate: DateTime(2026, 10, 6), recurrence: Recurrence.daily);
    await sessionA.syncNow();
    await sessionB.syncNow();

    // 2台が、相手と同期しないまま同じ案件を完了する。
    a.complete(a.openIssues.single.id);
    b.complete(b.openIssues.single.id);
    await sessionA.syncNow();
    await sessionB.syncNow();
    // 互いのopが届いたので、もう一度。
    await sessionA.syncNow();
    await sessionB.syncNow();

    expect(a.openIssues, hasLength(1));
    expect(b.openIssues, hasLength(1));
    expect(a.openIssues.single.id, b.openIssues.single.id, reason: '同じopを元にしているので同じidになる');
    expect(_view(b), _view(a));
  });

  test('取り消すと、相手側の「次の1件」も消える', () async {
    final bath = a.add(title: 'お風呂そうじ', dueDate: DateTime(2026, 10, 6), recurrence: Recurrence.daily);
    await sessionA.syncNow();
    await sessionB.syncNow();

    b.complete(bath.id);
    await sessionB.syncNow();
    await sessionA.syncNow();
    expect(a.openIssues, hasLength(1));
    expect(b.openIssues, hasLength(1));

    b.undoComplete(bath.id);
    await sessionB.syncNow();
    await sessionA.syncNow();

    expect(a.byId(bath.id)?.isDone, isFalse);
    expect(b.byId(bath.id)?.isDone, isFalse);
    expect(a.byId(bath.id)?.generatedNextId, isNull, reason: '自動生成した次の1件は見えなくなる');
    expect(a.openIssues.map((issue) => issue.id), <String>[bath.id]);
    expect(_view(b), _view(a));
  });

  test('送れなかったopは、送信待ちに残る（オフラインでも書ける）', () async {
    server.forcedStatus = 500;

    a.add(title: '牛乳を買う');
    await expectLater(
      sessionA.syncNow(),
      throwsA(isA<SyncException>().having((error) => error.code, 'code', 'server')),
    );

    expect(a.all, hasLength(1), reason: 'ローカルでは、ちゃんと見えている');
    expect(a.outbox, hasLength(1), reason: '送信待ちは消さない');
    expect(sessionA.lastError, isA<SyncException>());

    // サーバーが戻れば、次の同期で送られて、送信待ちが空になる。
    server.forcedStatus = null;
    await sessionA.syncNow();
    expect(a.outbox, isEmpty);
    expect(server.ops, hasLength(1));
    expect(sessionA.lastError, isNull);
    expect(sessionA.lastSyncedAt, isNotNull);
  });

  test('書いた直後に、自動で送られる', () async {
    sessionA.detach();
    sessionA = SyncSession(
      store: a,
      api: _api(server),
      autoPushDelay: const Duration(milliseconds: 30),
    )..attach();

    a.add(title: '牛乳を買う');
    expect(server.ops, isEmpty, reason: 'すぐには送らない（まとめて送る）');

    await _waitUntil(() => server.ops.isNotEmpty);
    expect(server.ops, hasLength(1));
    expect(a.outbox, isEmpty);
  });

  test('2回目以降の同期は、差分だけをもらう', () async {
    a.add(title: '牛乳を買う');
    a.add(title: '子供の靴を買う');
    final first = await sessionA.syncNow();
    expect(first.sent, 2);

    final quiet = await sessionA.syncNow();
    expect(quiet.received, 0);
    expect(quiet.sent, 0);
    expect(quiet.duplicates, 0);
    expect(quiet.empty, isTrue);

    final onB = await sessionB.syncNow();
    expect(onB.received, 2);

    final quietB = await sessionB.syncNow();
    expect(quietB.received, 0, reason: 'cursor を覚えているので、来ない');
  });

  test('読めないopが混ざっても、同期は止まらない', () async {
    a.add(title: '牛乳を買う');
    await sessionA.syncNow();

    server.injectedOps = <Map<String, Object?>>[
      <String, Object?>{'id': 'X:1', 'deviceId': 'X', 'lamport': 1, 'kind': 'add', 'issueId': 'X:1', 'at': '2026-10-06T08:00:00.000', 'data': <String, Object?>{}},
    ];

    final outcome = await sessionB.syncNow();
    expect(outcome.skipped, 1);
    expect(outcome.received, 1);
    expect(b.all, hasLength(1), reason: '読めたものは、ちゃんと入る');
    expect(_view(b), _view(a));
  });

  test('3台が交互に書いても、同期を回せば全員同じ画面になる', () async {
    final random = Random(20261006);
    final stores = <IssueStore>[_store('A'), _store('B'), _store('C')];
    final sessions = <SyncSession>[for (final store in stores) _session(store, server)];
    addTearDown(() {
      for (final session in sessions) {
        session.detach();
      }
    });

    var seq = 0;
    for (var step = 0; step < 60; step++) {
      final store = stores[random.nextInt(stores.length)];
      final open = store.openIssues;
      if (open.isEmpty || random.nextBool()) {
        store.add(
          title: '案件${seq++}',
          assigneeId: random.nextBool() ? 'me' : null,
          dueDate: DateTime(2026, 10).add(Duration(days: random.nextInt(10))),
          recurrence: random.nextBool() ? Recurrence.daily : Recurrence.none,
        );
      } else {
        final issue = open[random.nextInt(open.length)];
        switch (random.nextInt(4)) {
          case 0:
            store.complete(issue.id);
          case 1:
            store.comment(issue.id, 'メモ$step');
          case 2:
            store.setAssignee(issue.id, 'partner');
          case 3:
            store.setStatus(issue.id, IssueStatus.waiting);
        }
      }
      if (random.nextBool()) await sessions[random.nextInt(sessions.length)].syncNow();
    }

    // 全員を何周か同期させれば、必ず同じ状態になる。
    for (var round = 0; round < 3; round++) {
      for (final session in sessions) {
        await session.syncNow();
      }
    }

    final expected = _view(stores.first);
    expect(expected, isNotEmpty);
    for (final store in stores.skip(1)) {
      expect(_view(store), expected, reason: '${store.deviceId} が一致しない');
    }
    expect(server.ops, hasLength(stores.first.ops.length), reason: '全員が同じop集合を持つ');
  });
}

IssueStore _store(String deviceId) =>
    IssueStore(deviceId: deviceId, clock: () => DateTime(2026, 10, 6, 8));

SyncApi _api(OpsServer server) => SyncApi(
      baseUrl: server.baseUrl,
      householdId: 'hh_test00000000000000000000000',
      token: server.token,
    );

SyncSession _session(IssueStore store, OpsServer server) =>
    SyncSession(store: store, api: _api(server));

/// 画面に出ているものの要約。これが一致すれば、どの端末でも同じに見えている。
Map<String, String> _view(IssueStore store) => <String, String>{
      for (final issue in store.all)
        issue.id: <String>[
          issue.title,
          issue.status.name,
          issue.dueDate?.toIso8601String() ?? '-',
          issue.recurrence.label,
          issue.assigneeId ?? '-',
          issue.seriesKey,
          issue.events.where((event) => event.kind == EventKind.comment).map((event) => event.text).join(','),
          '${issue.events.length}',
        ].join('|'),
    };

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('待っていた状態にならなかった');
}
