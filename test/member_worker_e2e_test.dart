import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/session.dart';

import 'support/worker_server.dart';

/// 統合・削除を**本物の Worker**（server/src/index.js）と実際にHTTPで確かめる。
///
/// 起動は [WorkerServer]（server/test/serve.mjs）。node が無い環境では飛ばす。
void main() {
  test('統合は家に届き、別端末にも旧IDのまま見える', () async {
    final worker = await WorkerServer.start();
    if (worker == null) return markTestSkipped('node が無いので飛ばす');
    addTearDown(worker.stop);

    final a = _store('devA');
    final b = _store('devB');
    final sessionA = _session(a, worker.baseUrl);
    final sessionB = _session(b, worker.baseUrl);
    addTearDown(sessionA.detach);
    addTearDown(sessionB.detach);

    // Aが重複した「はる」を足して送る。
    final keep = a.addMember('はる');
    final dup = a.addMember('はる');
    final issue = a.add(title: '掃除');
    a.setAssignee(issue.id, dup.id);
    await sessionA.syncNow();
    await sessionB.syncNow();
    expect(b.members.map((m) => m.name), contains('はる'));

    // Aがまとめると、家とBにも届く。旧担当の見え方は残る。
    expect(a.mergeMembers(dup.id, keep.id), isTrue);
    await sessionA.syncNow();
    await sessionB.syncNow();
    expect(b.members.where((m) => m.id == dup.id), isEmpty);
    expect(
      b.assigneeWord(b.byId(issue.id)!.assigneeId),
      'はる',
      reason: '旧IDの担当は対応表で引き継ぐ',
    );

    // 家からもらい直しても旧行は戻らない。
    await sessionB.syncNow();
    expect(b.members.where((m) => m.id == dup.id), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('削除は家に届き、別端末の名簿からも消える', () async {
    final worker = await WorkerServer.start();
    if (worker == null) return markTestSkipped('node が無いので飛ばす');
    addTearDown(worker.stop);

    final a = _store('devA');
    final b = _store('devB');
    final sessionA = _session(a, worker.baseUrl);
    final sessionB = _session(b, worker.baseUrl);
    addTearDown(sessionA.detach);
    addTearDown(sessionB.detach);

    final other = a.addMember('おばあちゃん');
    await sessionA.syncNow();
    await sessionB.syncNow();
    expect(b.memberById(other.id)?.name, 'おばあちゃん');

    expect(a.removeMember(other.id), isTrue);
    await sessionA.syncNow();
    await sessionB.syncNow();
    expect(b.memberById(other.id), isNull);
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
