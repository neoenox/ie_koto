import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/session.dart';
import 'package:ie_koto/sync/storage.dart';
import 'package:ie_koto/sync/wire.dart';

import 'support/memory_store.dart';

class RejectingStore extends MemoryStore {
  bool reject = false;

  @override
  void write(String key, String? value) {
    if (reject) throw StateError('保存拒否');
    super.write(key, value);
  }
}

void main() {
  test('受信opの保存失敗ではcursorを進めず再試行で重複なく復旧する', () async {
    final kv = RejectingStore();
    final storage = DeviceStorage(kv);
    final store = IssueStore(deviceId: 'A', storage: storage);
    final remote = IssueStore(deviceId: 'B')..add(title: '受信保存を再試行');
    final requestedCursors = <int>[];
    var rejectPageSave = true;
    final api = SyncApi(
      baseUrl: 'https://example.test',
      householdId: 'household12345678',
      token: 'x' * 32,
      client: MockClient((request) async {
        if (request.url.path.contains('/household/members')) {
          return http.Response('{"members":[],"aliases":{}}', 200);
        }
        if (request.method == 'POST') {
          return http.Response('{"cursor":1}', 200);
        }
        final since = int.parse(request.url.queryParameters['since']!);
        requestedCursors.add(since);
        kv.reject = rejectPageSave;
        return http.Response(
          jsonEncode({
            'cursor': 1,
            'ops': since == 0 ? encodeOps(remote.ops) : [],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final session = SyncSession(store: store, api: api, storage: storage);
    try {
      await expectLater(session.syncNow(), throwsA(isA<StateError>()));
      expect(session.cursor, 0);
      expect(storage.lastSaveError, isNotNull);
      expect(DeviceStorage(kv).load().ops, isEmpty);
      expect(requestedCursors, [0]);
      rejectPageSave = false;
      kv.reject = false;
      await session.syncNow();
      await storage.flush();
      expect(requestedCursors, [0, 0, 1]);
      expect(session.cursor, 1);
      final restored = IssueStore(storage: DeviceStorage(kv));
      expect(restored.all.single.title, '受信保存を再試行');
      expect(restored.ops, hasLength(1));
      expect(DeviceStorage(kv).load().sync!.cursor, 1);
      expect(storage.lastSaveError, isNull);
    } finally {
      session.close();
    }
  });
  test('受信の次ページが失敗しても、確定したcursorまでの記録は再起動後に残る', () async {
    final kv = MemoryStore();
    final storage = DeviceStorage(kv);
    final store = IssueStore(deviceId: 'A', storage: storage);
    final remote = IssueStore(deviceId: 'B')..add(title: '失ってはいけない記録');
    http.Response memberMigration() => http.Response(
      jsonEncode({
        'members': [
          {'id': 'mem_11111111111111111111111111111111', 'name': '自分'},
          {'id': 'mem_22222222222222222222222222222222', 'name': 'パートナー'},
        ],
        'aliases': {
          'me': 'mem_11111111111111111111111111111111',
          'partner': 'mem_22222222222222222222222222222222',
        },
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    final failedApi = SyncApi(
      baseUrl: 'https://example.test',
      householdId: 'household12345678',
      token: 'x' * 32,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/household/members/migrate')) {
          return memberMigration();
        }
        final since = int.parse(request.url.queryParameters['since']!);
        if (since == 0) {
          return http.Response(
            jsonEncode({'cursor': 1, 'ops': encodeOps(remote.ops)}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 500);
      }),
    );
    final session = SyncSession(store: store, api: failedApi, storage: storage);
    await expectLater(session.syncNow(), throwsA(isA<SyncException>()));
    session.close();

    final reopenedStorage = DeviceStorage(kv);
    final reopened = IssueStore(storage: reopenedStorage);
    final saved = reopenedStorage.load().sync!;
    expect(saved.cursor, 1);
    expect(reopened.all.single.title, '失ってはいけない記録');
    final api = SyncApi(
      baseUrl: saved.baseUrl,
      householdId: saved.householdId,
      token: saved.token,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/household/members/migrate')) {
          return memberMigration();
        }
        expect(request.url.queryParameters['since'], '1');
        return http.Response('{"cursor":1,"ops":[]}', 200);
      }),
    );
    final recovered = SyncSession(
      store: reopened,
      api: api,
      storage: reopenedStorage,
      cursor: saved.cursor,
    );
    final outcome = await recovered.syncNow();
    expect(outcome.received, 0);
    expect(reopened.all.single.title, '失ってはいけない記録');
    recovered.close();
  });
}
