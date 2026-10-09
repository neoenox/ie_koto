import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/log.dart';

import 'support/ops_server.dart';

/// 同期APIの送受信を、**実際のHTTP**（本物のソケット）で確かめる。
/// サーバー役はテストの中の物真似（[OpsServer]）。本物は server/ の Cloudflare Worker。
void main() {
  late OpsServer server;
  late SyncApi api;

  setUp(() async {
    server = OpsServer();
    await server.start();
    api = SyncApi(
      baseUrl: server.baseUrl,
      householdId: 'hh_test00000000000000000000000',
      token: server.token,
    );
  });

  tearDown(() async {
    api.close();
    await server.stop();
  });

  test('送って、もらう（日本語と絵文字もそのまま）', () async {
    final op = Op(
      deviceId: 'A',
      lamport: 1,
      kind: OpKind.add,
      issueId: 'A:1',
      at: DateTime(2026, 10, 6, 8),
      data: <String, Object?>{
        'title': 'お風呂そうじ 🛁',
        'dueDate': DateTime(2026, 10, 7),
        'recurrence': Recurrence.daily,
      },
    );

    final pushed = await api.push(<Op>[op]);
    expect(pushed.accepted, 1);
    expect(pushed.duplicates, 0);

    final page = await api.pull(since: 0);
    expect(page.cursor, 1);
    expect(page.skipped, 0);
    expect(page.ops, hasLength(1));
    expect(page.ops.single.data['title'], 'お風呂そうじ 🛁');
    expect(page.ops.single.data['dueDate'], DateTime(2026, 10, 7));
    expect((page.ops.single.data['recurrence'] as Recurrence).label, '毎日');

    // cursor から先は空。
    final again = await api.pull(since: page.cursor);
    expect(again.ops, isEmpty);
    expect(again.cursor, 1);
  });

  test('二重送信しても増えない（op_idが主キー）', () async {
    final op = Op(
      deviceId: 'A',
      lamport: 1,
      kind: OpKind.add,
      issueId: 'A:1',
      at: DateTime(2026, 10, 6),
      data: <String, Object?>{'title': '牛乳'},
    );

    await api.push(<Op>[op]);
    final second = await api.push(<Op>[op]);

    expect(second.accepted, 0);
    expect(second.duplicates, 1);
    expect(server.ops, hasLength(1));
    expect((await api.pull(since: 0)).ops, hasLength(1));
  });

  test('ページング: limitで分けて受け取り、cursorが続きを指す', () async {
    api.close();
    api = SyncApi(
      baseUrl: server.baseUrl,
      householdId: 'hh_test00000000000000000000000',
      token: server.token,
      pageLimit: 2,
    );

    await api.push(<Op>[
      for (var i = 1; i <= 5; i++)
        Op(
          deviceId: 'A',
          lamport: i,
          kind: OpKind.comment,
          issueId: 'A:1',
          at: DateTime(2026, 10, 6),
          data: <String, Object?>{'text': 'メモ$i'},
        ),
    ]);

    final collected = <Op>[];
    var cursor = 0;
    for (var round = 0; round < 10; round++) {
      final page = await api.pull(since: cursor);
      collected.addAll(page.ops);
      expect(page.cursor, greaterThanOrEqualTo(cursor));
      cursor = page.cursor;
      if (page.ops.isEmpty) break;
    }

    expect(collected.map((op) => op.id), <String>[
      'A:1',
      'A:2',
      'A:3',
      'A:4',
      'A:5',
    ]);
    expect(server.pulls, greaterThan(1), reason: 'limit を守って分けて取る');
  });

  test('一度に送れる数を超えたら、分けて送る', () async {
    final ops = <Op>[
      for (var i = 1; i <= SyncApi.maxOpsPerPost + 50; i++)
        Op(
          deviceId: 'A',
          lamport: i,
          kind: OpKind.comment,
          issueId: 'A:1',
          at: DateTime(2026, 10, 6),
          data: <String, Object?>{'text': 'メモ$i'},
        ),
    ];

    final result = await api.push(ops);

    expect(result.accepted, ops.length);
    expect(server.posts, 2, reason: '200件ずつに分ける');
    expect(server.ops, hasLength(ops.length), reason: '1件も落ちていない');
    expect((await api.pull(since: 0)).ops, hasLength(ops.length));
  });

  test('トークンが違えば unauthorized', () async {
    final wrong = SyncApi(
      baseUrl: server.baseUrl,
      householdId: 'hh_test00000000000000000000000',
      token: 'wrong-token-wrong-token-wrong-token-wrong',
    );
    addTearDown(wrong.close);

    await expectLater(
      wrong.pull(since: 0),
      throwsA(
        isA<SyncException>().having(
          (error) => error.code,
          'code',
          'unauthorized',
        ),
      ),
    );
    await expectLater(
      wrong.push(<Op>[
        Op(
          deviceId: 'A',
          lamport: 1,
          kind: OpKind.comment,
          issueId: 'A:1',
          at: DateTime(2026, 10, 6),
          data: <String, Object?>{'text': 'x'},
        ),
      ]),
      throwsA(
        isA<SyncException>().having(
          (error) => error.code,
          'code',
          'unauthorized',
        ),
      ),
    );
  });

  test('サーバーの失敗は、種類が分かる（server / bad_request / bad_response）', () async {
    server.forcedStatus = 500;
    await expectLater(
      api.pull(since: 0),
      throwsA(
        isA<SyncException>().having((error) => error.code, 'code', 'server'),
      ),
    );

    server.forcedStatus = 400;
    server.forcedBody = '{"error":"bad_ops"}';
    await expectLater(
      api.pull(since: 0),
      throwsA(
        isA<SyncException>().having(
          (error) => error.code,
          'code',
          'bad_request',
        ),
      ),
    );

    server.forcedStatus = 200;
    server.forcedBody = 'これはJSONではない';
    await expectLater(
      api.pull(since: 0),
      throwsA(
        isA<SyncException>().having(
          (error) => error.code,
          'code',
          'bad_response',
        ),
      ),
    );
  });

  test('サーバーが落ちていれば offline（送信待ちは消さない）', () async {
    await server.stop();
    await expectLater(
      api.pull(since: 0),
      throwsA(
        isA<SyncException>().having((error) => error.code, 'code', 'offline'),
      ),
    );
  });

  test('応答の途中で切れても offline（中途半端なopを受け取らない）', () async {
    await api.push(<Op>[
      Op(
        deviceId: 'A',
        lamport: 1,
        kind: OpKind.add,
        issueId: 'A:1',
        at: DateTime(2026, 10, 6),
        data: <String, Object?>{'title': '牛乳'},
      ),
    ]);
    server.cutResponse = true;

    await expectLater(
      api.pull(since: 0),
      throwsA(
        isA<SyncException>().having((error) => error.code, 'code', 'offline'),
      ),
    );
  });

  test('壊れたopが混ざっても、読めたものは受け取る', () async {
    await api.push(<Op>[
      Op(
        deviceId: 'A',
        lamport: 1,
        kind: OpKind.add,
        issueId: 'A:1',
        at: DateTime(2026, 10, 6),
        data: <String, Object?>{'title': '牛乳'},
      ),
    ]);
    server.injectedOps = <Map<String, Object?>>[
      <String, Object?>{
        'id': 'A:99',
        'deviceId': 'A',
        'lamport': 99,
        'kind': 'add',
        'issueId': 'A:99',
        'at': '2026-10-06T08:00:00.000',
        'data': <String, Object?>{},
      },
      <String, Object?>{
        'id': 'B:2',
        'deviceId': 'B',
        'lamport': 2,
        'kind': 'comment',
        'issueId': 'A:1',
        'at': '2026-10-06T09:00:00.000',
        'data': <String, Object?>{'text': 'あとから届いたメモ'},
      },
    ];

    final page = await api.pull(since: 1);
    expect(page.ops, hasLength(1));
    expect(page.ops.single.data['text'], 'あとから届いたメモ');
    expect(page.skipped, 1);
  });
}
