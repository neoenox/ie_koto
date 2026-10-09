import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/session.dart';

import 'support/ops_server.dart';

/// 統合・削除の送り残しを、次回同期で家に届ける。サーバー役は [OpsServer]。
void main() {
  late OpsServer server;
  late IssueStore store;
  late SyncSession session;

  setUp(() async {
    server = OpsServer();
    await server.start();
    store = IssueStore(deviceId: 'push');
    store.setMeId('me');
    session = SyncSession(
      store: store,
      api: SyncApi(
        baseUrl: server.baseUrl,
        householdId: 'hh_test00000000000000000000000',
        token: server.token,
      ),
    );
  });

  tearDown(() async {
    session.detach();
    await server.stop();
  });

  test('統合は対応表として届き、送り残しが消える', () async {
    final keep = store.addMember('はる');
    final dup = store.addMember('はる');
    await session.syncNow();
    expect(store.pendingMemberNames, isEmpty);

    expect(store.mergeMembers(dup.id, keep.id), isTrue);
    await session.syncNow();

    expect(store.pendingMemberAliases, isEmpty);
    expect(server.legacyAliases[dup.id], keep.id);
    // 家からもらい直しても、旧行は戻らない。
    await session.syncNow();
    expect(store.members.where((m) => m.id == dup.id), isEmpty);
    expect(store.memberById(dup.id)!.id, keep.id);
  });

  test('削除は名簿から消え、送り残しが消える', () async {
    final other = store.addMember('おばあちゃん');
    await session.syncNow();

    expect(store.removeMember(other.id), isTrue);
    await session.syncNow();

    expect(store.pendingMemberRemovals, isEmpty);
    expect(server.members.containsKey(other.id), isFalse);
    await session.syncNow();
    expect(store.memberById(other.id), isNull);
  });
}
