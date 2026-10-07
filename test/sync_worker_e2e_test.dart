import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/log.dart';
import 'package:ie_koto/sync/session.dart';

import 'support/worker_server.dart';

/// **本物の Worker**（server/src/index.js）と、実際にHTTPで同期する。
///
/// 起動は [WorkerServer]（server/test/serve.mjs）。node が無い環境では飛ばす。
void main() {
  test('2台が実際に同期して、同じ画面になり、完了すると次の1件が1つだけ出る', () async {
    final worker = await WorkerServer.start();
    if (worker == null) return markTestSkipped('node が無いので飛ばす');
    addTearDown(worker.stop);

    final a = _store('devA');
    final b = _store('devB');
    final sessionA = _session(a, worker.baseUrl);
    final sessionB = _session(b, worker.baseUrl);

    // Aが定期案件を足して送る。
    final bath = a.add(title: 'お風呂そうじ 🛁', dueDate: DateTime(2026, 10, 6), recurrence: Recurrence.daily);
    final first = await sessionA.syncNow();
    expect(first.sent, 1);
    expect(first.received, 0);

    // Bはまだ何も知らない。同期すると、もらえる。
    final onB = await sessionB.syncNow();
    expect(onB.received, 1);
    expect(b.byId(bath.id)?.title, 'お風呂そうじ 🛁');
    expect(b.byId(bath.id)?.recurrence.label, '毎日');
    expect(b.outbox, isEmpty, reason: 'もらったopを送り返さない');
    expect(_view(b), _view(a));

    // Bが完了すると、Aにも同じ「次の1件」が出る。
    b.complete(bath.id);
    await sessionB.syncNow();
    await sessionA.syncNow();

    final nextId = nextIssueId(b.ops.firstWhere((op) => op.kind == OpKind.complete).id);
    expect(nextId, startsWith('next:devB:'));
    expect(a.openIssues.map((issue) => issue.id), <String>[nextId]);
    expect(b.openIssues.map((issue) => issue.id), <String>[nextId]);
    expect(a.byId(nextId)?.dueDate, DateTime(2026, 10, 7));
    expect(_view(b), _view(a));

    // 2回目の同期は、もう何も運ばない（cursorの先だけを見ている）。
    final quiet = await sessionA.syncNow();
    expect(quiet.empty, isTrue);
    expect(quiet.skipped, 0);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Workerのページング越しでも、最後には全部そろう', () async {
    final worker = await WorkerServer.start();
    if (worker == null) return markTestSkipped('node が無いので飛ばす');
    addTearDown(worker.stop);

    final a = _store('devA');
    final sessionA = _session(a, worker.baseUrl);
    final b = _store('devB');
    final sessionB = _session(b, worker.baseUrl, pageLimit: 2);

    for (var i = 0; i < 7; i++) {
      a.add(title: '案件$i');
    }
    await sessionA.syncNow();
    expect(a.outbox, isEmpty);

    final outcome = await sessionB.syncNow();
    expect(outcome.received, 7, reason: 'limit=2 でも、空が返るまで取り切る');
    expect(b.all, hasLength(7));
    expect(_view(b), _view(a));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Workerは、同じopを二重に預からない', () async {
    final worker = await WorkerServer.start();
    if (worker == null) return markTestSkipped('node が無いので飛ばす');
    addTearDown(worker.stop);

    final a = _store('devA');
    final sessionA = _session(a, worker.baseUrl);
    final api = SyncApi(baseUrl: worker.baseUrl, householdId: _household, token: _token);
    addTearDown(api.close);

    final milk = a.add(title: '牛乳を買う');
    await sessionA.syncNow();

    final first = await api.pull(since: 0);
    expect(first.ops, hasLength(1));
    expect(first.ops.single.issueId, milk.id);

    // 同じopをもう一度、直接送る（電波が切れて、送れたか分からなかったときと同じ）。
    final duplicate = await api.push(a.ops);
    expect(duplicate.accepted, 0);
    expect(duplicate.duplicates, a.ops.length);

    final again = await api.pull(since: 0);
    expect(again.ops, hasLength(first.ops.length), reason: '増えない');
    expect(again.cursor, first.cursor, reason: 'cursorも進まない');

    // トークンが違えば、本物のWorkerも断る。
    final stranger = SyncApi(baseUrl: worker.baseUrl, householdId: _household, token: 'stranger-token-stranger-token-stranger-token');
    addTearDown(stranger.close);
    await expectLater(
      stranger.pull(since: 0),
      throwsA(isA<SyncException>().having((error) => error.code, 'code', 'unauthorized')),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// 世帯idとトークンは、端末に保存する値（保存は手順1）。ここでは固定。
const String _household = 'hh_e2e0000000000000000000000000000';
const String _token = 'e2e-token-e2e-token-e2e-token-e2e-token-e2e';

IssueStore _store(String deviceId) =>
    IssueStore(deviceId: deviceId, clock: () => DateTime(2026, 10, 6, 8));

SyncSession _session(IssueStore store, String baseUrl, {int? pageLimit}) => SyncSession(
      store: store,
      api: SyncApi(baseUrl: baseUrl, householdId: _household, token: _token, pageLimit: pageLimit),
    );

Map<String, String> _view(IssueStore store) => <String, String>{
      for (final issue in store.all)
        issue.id: <String>[
          issue.title,
          issue.status.name,
          issue.dueDate?.toIso8601String() ?? '-',
          issue.recurrence.label,
          issue.assigneeId ?? '-',
          issue.seriesKey,
        ].join('|'),
    };

