import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/session.dart';

import 'support/ops_server.dart';

/// #128 メンバー名の80文字上限が端末側で未検証で、長い名前が同期全体を止める。
void main() {
  group('#128 長さ上限の入口検証', () {
    test('追加は81文字で拒否し、名簿・保留を変えない', () {
      final store = IssueStore(deviceId: 'len-add');
      final long = List.filled(81, 'あ').join();
      expect(() => store.addMember(long), throwsArgumentError);
      expect(store.members.length, 2);
      expect(store.pendingMemberNames, isEmpty);
    });

    test('80文字は追加できる', () {
      final store = IssueStore(deviceId: 'len-ok');
      final ok = List.filled(80, 'あ').join();
      final member = store.addMember(ok);
      expect(member.name, ok);
      expect(store.pendingMemberNames[member.id], ok);
    });

    test('改名は81文字で変えず、80文字は変えられる', () {
      final store = IssueStore(deviceId: 'len-rename');
      store.setMeId('me');
      final long = List.filled(81, 'あ').join();
      expect(store.renameMember('me', long), isFalse);
      expect(store.memberById('me')!.name, '自分');
      expect(store.pendingMemberNames.containsKey('me'), isFalse);

      final ok = List.filled(80, 'あ').join();
      expect(store.renameMember('me', ok), isTrue);
      expect(store.memberById('me')!.name, ok);
    });
  });

  group('#128 長い保留名があっても操作opは同期する', () {
    late OpsServer server;
    late IssueStore store;
    late SyncSession session;

    setUp(() async {
      server = OpsServer();
      await server.start();
      store = IssueStore(deviceId: 'len-sync');
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

    test('長い保留名を送らず、追加のopは届く', () async {
      await session.syncNow();
      expect(store.pendingMemberNames, isEmpty);

      // 修正前の保存データに残っていた長い名前を想定して直接置く。
      const legacyId = 'mem_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final long = List.filled(81, 'あ').join();
      store.members.add(Member(legacyId, long));
      store.pendingMemberNames[legacyId] = long;

      final issue = store.add(title: '牛乳を買う');
      await session.syncNow();

      // 操作opはサーバーに届き、長い名前は送らない。
      expect(
        server.ops.any((op) => (op['issueId'] as String?) == issue.id),
        isTrue,
      );
      expect(server.members.containsKey(legacyId), isFalse);
      expect(store.pendingMemberNames[legacyId], long);
      expect(store.byId(issue.id), isNotNull);
    });

    test('長い名前の直し後も同期は健全', () async {
      await session.syncNow();
      store.renameMember('me', List.filled(80, 'あ').join());
      final issue = store.add(title: 'パンを買う');
      await session.syncNow();
      expect(store.pendingMemberNames, isEmpty);
      expect(
        server.ops.any((op) => (op['issueId'] as String?) == issue.id),
        isTrue,
      );
    });
  });
}
