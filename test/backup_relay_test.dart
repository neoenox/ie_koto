import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/session.dart';

import 'support/worker_server.dart';

/// #12: 別端末で読み込んだバックアップは送信待ちに残り、
/// 同期先の家と第三の端末に届く。再読み込み・再同期で重複しない。
///
/// 本物の Worker（server/src/index.js）と実際にHTTPで確かめる。
/// node が無い環境では飛ばす。
void main() {
  test('読み込んだ記録は中継され第三の端末に届く', () async {
    final worker = await WorkerServer.start();
    if (worker == null) return markTestSkipped('node が無いので飛ばす');
    addTearDown(worker.stop);

    final a = _store('devA');
    a.add(title: '引っ越し荷物');

    final b = _store('devB');
    expect(b.importJson(a.exportJson()), 1);
    expect(
      b.outbox.map((op) => op.id),
      contains(a.ops.single.id),
      reason: '読み込んだ記録は中継の送信待ちに残る',
    );

    final sessionB = _session(b, worker.baseUrl);
    final c = _store('devC');
    final sessionC = _session(c, worker.baseUrl);
    addTearDown(sessionB.detach);
    addTearDown(sessionC.detach);

    await sessionB.syncNow();
    await sessionC.syncNow();
    expect(c.all.map((issue) => issue.title), contains('引っ越し荷物'));

    // 再読み込み・再同期で重複しない。
    expect(b.importJson(a.exportJson()), 0, reason: '二重に読んでも増えない');
    await sessionB.syncNow();
    await sessionC.syncNow();
    expect(c.all.where((issue) => issue.title == '引っ越し荷物'), hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// 世帯idとトークンは、端末に保存する値（保存は手順1）。ここでは固定。
const String _household = 'hh_e2e0000000000000000000000000001';
const String _token = 'e2e-token-e2e-token-e2e-token-e2e-token-e2e';

IssueStore _store(String deviceId) {
  final store = IssueStore(
    deviceId: deviceId,
    clock: () => DateTime(2026, 10, 6, 8),
  );
  store.setMeId('me');
  return store;
}

SyncSession _session(IssueStore store, String baseUrl) => SyncSession(
  store: store,
  api: SyncApi(baseUrl: baseUrl, householdId: _household, token: _token),
);
