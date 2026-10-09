import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/session.dart';

import 'support/ops_server.dart';

/// 失敗した同期が次回を壊さない。サーバー役は [OpsServer]。
void main() {
  late OpsServer server;
  late IssueStore store;
  late SyncSession session;

  setUp(() async {
    server = OpsServer();
    await server.start();
    store = IssueStore(deviceId: 'retry');
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

  test('失敗の後も次の同期は走り、送り残しが届く', () async {
    store.add(title: '牛乳を買う');

    server.forcedStatus = 500;
    server.forcedBody = '{"error":"forced"}';
    await expectLater(session.syncNow(), throwsA(isA<Exception>()));
    expect(store.outbox, isNotEmpty, reason: '送れなかった分は残る');

    server.forcedStatus = null;
    final retry = await session.syncNow();
    expect(retry.sent, 1);
    expect(store.outbox, isEmpty);
  });
}
