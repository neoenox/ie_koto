import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/session.dart';
import 'package:ie_koto/sync/log.dart';

class ControlledApi extends SyncApi {
  ControlledApi()
    : super(baseUrl: 'http://localhost', householdId: 'house', token: 'token');
  int pulls = 0;
  bool fail = false;
  Completer<void>? gate;
  List<Op> incoming = [];
  final List<Op> sent = [];
  @override
  Future<MemberDirectory> migrateAndGetMembers(Map<String, String> names) =>
      getMembers();
  @override
  Future<MemberDirectory> getMembers() async {
    await gate?.future;
    if (fail) throw SyncException('offline');
    return const MemberDirectory(
      members: [Member('me', '自分'), Member('partner', 'パートナー')],
      aliases: {},
    );
  }

  @override
  Future<void> saveMember(Member member) async {}
  @override
  Future<PushResult> push(List<Op> ops) async {
    if (fail) throw SyncException('offline');
    sent.addAll(ops);
    return PushResult(accepted: ops.length, duplicates: 0);
  }

  @override
  Future<PullPage> pull({required int since}) async {
    pulls++;
    if (fail) throw SyncException('offline');
    final ops = incoming;
    incoming = [];
    return PullPage(cursor: since + ops.length, ops: ops, skipped: 0);
  }
}

void main() {
  testWidgets('背景中の編集は送信待ちに残り、前面復帰で送信する', (tester) async {
    final store = IssueStore(deviceId: 'A');
    final api = ControlledApi();
    final session = SyncSession(store: store, api: api)..attach();
    addTearDown(session.close);
    session.startForegroundSync();
    await tester.pump();
    session.stopForegroundSync();
    final pulls = api.pulls;
    final issue = store.add(title: '背景中に残る変更');
    await tester.pump(const Duration(seconds: 30));
    expect(api.pulls, pulls);
    expect(api.sent, isEmpty);
    expect(session.hasPendingChanges, isTrue);
    session.startForegroundSync();
    await tester.pump();
    expect(api.sent.single.issueId, issue.id);
    expect(session.hasPendingChanges, isFalse);
    expect(api.pulls, greaterThan(pulls));
    session.close();
  });

  testWidgets('前面の定期同期が受信し、停止中は取得せず、復帰すると即取得する', (tester) async {
    final store = IssueStore(deviceId: 'B');
    final api = ControlledApi();
    final session = SyncSession(store: store, api: api)..attach();
    addTearDown(session.close);
    session.startForegroundSync();
    await tester.pump();
    final a = IssueStore(deviceId: 'A');
    final issue = a.add(title: '家族からの用事');
    api.incoming = a.ops;
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(store.byId(issue.id)?.title, '家族からの用事');
    session.stopForegroundSync();
    final pulls = api.pulls;
    await tester.pump(const Duration(seconds: 30));
    expect(api.pulls, pulls);
    session.startForegroundSync();
    await tester.pump();
    expect(api.pulls, greaterThan(pulls));
    session.close();
  });

  testWidgets('定期同期・手動同期・編集を重ねても多重実行せず、次の回で未送信を送る', (tester) async {
    final store = IssueStore(deviceId: 'A');
    final api = ControlledApi()..gate = Completer<void>();
    final session = SyncSession(store: store, api: api)..attach();
    addTearDown(session.close);
    session.startForegroundSync();
    final running = session.syncNow();
    expect(identical(running, session.syncNow()), isTrue);
    expect(session.isSyncing, isTrue);
    store.add(title: '通信中の編集');
    await tester.pump(const Duration(seconds: 20));
    expect(api.pulls, 0);
    api.gate!.complete();
    await tester.pump();
    await running;
    expect(api.sent, hasLength(1));
    expect(session.isSyncing, isFalse);
    session.close();
  });

  testWidgets('同期失敗は未送信を保持し、次の定期同期で自動復旧する', (tester) async {
    final store = IssueStore(deviceId: 'A');
    final api = ControlledApi()..fail = true;
    final session = SyncSession(store: store, api: api)..attach();
    addTearDown(session.close);
    store.add(title: 'オフラインの用事');
    session.startForegroundSync();
    await tester.pump();
    expect(session.lastError, isNotNull);
    expect(session.hasPendingChanges, isTrue);
    api.fail = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));
    await tester.pump();
    expect(session.lastError, isNull);
    expect(session.hasPendingChanges, isFalse);
    expect(api.sent, hasLength(1));
    session.close();
  });

  testWidgets('close後の応答は記録にもcursorにも反映しない', (tester) async {
    final store = IssueStore(deviceId: 'B');
    final api = ControlledApi()..gate = Completer<void>();
    final a = IssueStore(deviceId: 'A');
    a.add(title: '旧世帯の用事');
    api.incoming = a.ops;
    final session = SyncSession(store: store, api: api)..attach();
    session.startForegroundSync();
    session.close();
    api.gate!.complete();
    await tester.pump();
    expect(store.all, isEmpty);
    expect(session.cursor, 0);
    expect(api.pulls, 0);
  });
}
