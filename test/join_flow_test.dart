import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/join_link.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/session.dart';

import 'support/ops_server.dart';

/// 参加リンク→参加→同期→名簿共有の通し。サーバー役は [OpsServer]。
void main() {
  late OpsServer server;

  setUp(() async {
    server = OpsServer();
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  SyncSession sessionFor(IssueStore store) => SyncSession(
    store: store,
    api: SyncApi(
      baseUrl: server.baseUrl,
      householdId: 'hh_test00000000000000000000000',
      token: server.token,
    ),
  );

  test('参加リンクで入った端末に名簿と用事が共有される', () async {
    // 先にいる端末：人を追加して同期する。
    final host = IssueStore(deviceId: 'host');
    host.setMeId('me');
    host.addMember('はる');
    final hostSession = sessionFor(host);
    await hostSession.syncNow();
    hostSession.detach();

    // 招待リンクを作って、別端末で開く。
    const householdId = 'hh_test00000000000000000000000';
    final link = JoinLink(
      baseUrl: server.baseUrl,
      householdId: householdId,
      token: server.token,
    );
    final parsed = JoinLink.fromUri(Uri.parse(link.text))!;
    expect(parsed.householdId, householdId);

    // 参加：3値で同期を始める。
    final guest = IssueStore(deviceId: 'guest');
    final guestSession = SyncSession(
      store: guest,
      api: SyncApi(
        baseUrl: parsed.apiBaseUrl,
        householdId: parsed.householdId,
        token: parsed.token,
      ),
    );
    await guestSession.syncNow();

    // 名簿が共有され、本人を選べる。
    expect(guest.members.map((m) => m.name), contains('はる'));
    guest.setMeId(guest.members.firstWhere((m) => m.name == 'はる').id);
    expect(guest.meExplicit, isTrue);

    // 用事も共有される。
    host.add(title: '牛乳を買う');
    await hostSession.syncNow();
    await guestSession.syncNow();
    expect(guest.all.map((i) => i.title), contains('牛乳を買う'));

    guestSession.detach();
  });
}
