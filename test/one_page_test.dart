import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/one_link.dart';
import 'package:ie_koto/one_page.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/log.dart';
import 'package:ie_koto/sync/wire.dart';

/// 1件リンクを開いた**相手の画面**（アプリを入れていない人）。
///
/// できることは2つだけ: 中身を見る、「やる」を押す。押したら担当のopが1つ書かれて送られる。
/// 端末には何も残さない（[Storage] を渡さないので、開くたびに新しい端末idで始まる）。
///
/// HTTPは差し替える（本物のサーバー越しの道は test/one_link_worker_e2e_test.dart）。
void main() {
  const token = 'h8Qw3ZrT9xYb2LmN4PvC6SdF7GhJ1KlZ3XcV5BnM7Qa';
  const household = 'hh_e2e0000000000000000000000000000';

  OneLink linkFor(String issueId) => OneLink(
    baseUrl: 'https://ie-koto.example.workers.dev',
    householdId: household,
    token: token,
    issueId: issueId,
  );

  Future<void> pump(WidgetTester tester, _Server server, String issueId) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final api = SyncApi(
      baseUrl: 'https://ie-koto.example.workers.dev',
      householdId: household,
      token: token,
      issueId: issueId,
      client: server.client,
    );
    addTearDown(api.close);

    // 開くたびに別のページとして立ち上げる（本番も、リンクを開くたびに最初から始まる）。
    await tester.pumpWidget(
      MaterialApp(
        home: OnePage(
          key: UniqueKey(),
          link: linkFor(issueId),
          api: api,
          clock: () => DateTime(2026, 10, 6, 8),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('時計上限では引受けを保存・送信せず理由を案内する', (tester) async {
    final server = _Server()
      ..seed(_add('remote', 2147483647, 'remote:2147483647', '上限の依頼'));
    await pump(tester, server, 'remote:2147483647');
    await tester.tap(find.byKey(const ValueKey('one-take')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('記録の上限に達したため変更できません'), findsOneWidget);
    expect(find.byKey(const ValueKey('one-take')), findsOneWidget);
    expect(server.posted, isEmpty);
    expect(find.text('引き受けました。送った人にも伝わります'), findsNothing);
  });

  testWidgets('1件だけ見えて、「やる」で担当を引き受けられる', (tester) async {
    final server = _Server()
      ..seed(
        _add(
          'devA',
          1,
          'devA:1',
          'トイレットペーパーを買う',
          dueDate: DateTime(2026, 10, 6),
        ),
      )
      // 世帯のほかの案件。相手のブラウザには置かない（引いてこない）。
      ..seed(_add('devA', 2, 'devA:2', '車のオイル交換'));

    await pump(tester, server, 'devA:1');

    expect(find.text('トイレットペーパーを買う'), findsOneWidget);
    expect(find.text('車のオイル交換'), findsNothing, reason: '1件リンクは1件だけ');
    expect(find.text('今日・だれでも'), findsOneWidget);
    expect(find.byKey(const ValueKey('one-take')), findsOneWidget);
    expect(find.byKey(const ValueKey('one-later')), findsOneWidget);

    // その1件のopだけを聞いている。
    expect(server.requested, isNotEmpty);
    for (final uri in server.requested) {
      expect(uri.path, '/ops');
      expect(uri.queryParameters['issue'], 'devA:1');
      expect(uri.queryParameters['household'], household);
    }

    await tester.tap(find.byKey(const ValueKey('one-take')));
    await tester.pumpAndSettle();

    expect(find.text('引き受けました。送った人にも伝わります'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('one-take')),
      findsNothing,
      reason: '2回は押させない',
    );
    expect(find.text('今日・だれでも'), findsNothing);
    expect(find.text('今日・自分'), findsOneWidget, reason: '開いた人から見て「自分」');

    expect(server.posted, hasLength(1), reason: '送るのは1回・1件');
    final op = server.posted.single.single;
    expect(op['kind'], 'assignee');
    expect(op['issueId'], 'devA:1');
    expect((op['data']! as Map)['assigneeId'], 'partner');
    // 相手の端末idは、開くたびに新しくなる（保存しないので、世帯のidとぶつからない長さ）。
    expect(op['deviceId'], isNot('dev'), reason: '端末に残したidを使ってはいけない');
    expect((op['deviceId']! as String).startsWith('g'), isTrue);
    expect((op['deviceId']! as String).length, greaterThanOrEqualTo(12));
  });

  testWidgets('世帯のだれかの担当になっている1件を、「自分」と呼ばない', (tester) async {
    // 持ち主が担当の案件（世帯の呼び名では「自分」）。開いた人から見れば「ほかの人」。
    final server = _Server()
      ..seed(
        _add(
          'devA',
          1,
          'devA:1',
          '牛乳を買う',
          dueDate: DateTime(2026, 10, 6),
          assigneeId: 'me',
        ),
      );

    await pump(tester, server, 'devA:1');

    expect(find.text('今日・ほかの人'), findsOneWidget);
    expect(find.text('今日・自分'), findsNothing, reason: '開いた人の案件ではない');
    expect(find.byKey(const ValueKey('one-take')), findsOneWidget);
  });

  testWidgets('「あとで」は、何も書かない・何も送らない', (tester) async {
    final server = _Server()..seed(_add('devA', 1, 'devA:1', 'トイレットペーパーを買う'));

    await pump(tester, server, 'devA:1');
    await tester.tap(find.byKey(const ValueKey('one-later')));
    await tester.pumpAndSettle();

    expect(find.text('また今度で大丈夫です'), findsOneWidget);
    expect(server.posted, isEmpty);
    expect(
      server.ops.where((op) => op['kind'] == 'assignee'),
      isEmpty,
      reason: '担当は変わらない',
    );
  });

  testWidgets('もう終わっている1件には、押せるものを出さない', (tester) async {
    final server = _Server()
      ..seed(_add('devA', 1, 'devA:1', 'トイレットペーパーを買う'))
      ..seed(_op('devA', 2, OpKind.complete, 'devA:1'));

    await pump(tester, server, 'devA:1');

    expect(find.text('トイレットペーパーを買う'), findsOneWidget);
    expect(find.text('もう終わっています'), findsOneWidget);
    expect(find.byKey(const ValueKey('one-take')), findsNothing);
    expect(server.posted, isEmpty);
  });

  testWidgets('もう無い1件は、そう言って終わる', (tester) async {
    final server = _Server()..seed(_add('devA', 1, 'devA:2', '車のオイル交換'));

    await pump(tester, server, 'devA:1');

    expect(find.text('この1件は、もう終わったか消えています'), findsOneWidget);
    expect(find.byKey(const ValueKey('one-take')), findsNothing);
  });

  testWidgets('つながらないときは、そう言って「もう一度」を出す', (tester) async {
    final server = _Server()
      ..seed(_add('devA', 1, 'devA:1', 'トイレットペーパーを買う'))
      ..failPull = 503;

    await pump(tester, server, 'devA:1');

    expect(find.textContaining('つながりませんでした'), findsOneWidget);
    expect(find.byKey(const ValueKey('one-retry')), findsOneWidget);

    // 電波が戻って、押し直せば中身が出る。
    server.failPull = null;
    await tester.tap(find.byKey(const ValueKey('one-retry')));
    await tester.pumpAndSettle();

    expect(find.text('トイレットペーパーを買う'), findsOneWidget);
    expect(find.byKey(const ValueKey('one-take')), findsOneWidget);
  });

  testWidgets('引き受けたあとで送れなかったら、書いたことは残して、もう一度送れる', (tester) async {
    final server = _Server()
      ..seed(_add('devA', 1, 'devA:1', 'トイレットペーパーを買う'))
      ..failPush = 500;

    await pump(tester, server, 'devA:1');
    await tester.tap(find.byKey(const ValueKey('one-take')));
    await tester.pumpAndSettle();

    expect(find.text('引き受けました。いまは送れませんでした'), findsOneWidget);
    expect(find.byKey(const ValueKey('one-retry-send')), findsOneWidget);
    expect(
      server.ops.where((op) => op['kind'] == 'assignee'),
      isEmpty,
      reason: 'サーバーには届いていない',
    );

    // 送れるようになったら、押し直すだけで届く。
    server.failPush = null;
    await tester.tap(find.byKey(const ValueKey('one-retry-send')));
    await tester.pumpAndSettle();

    expect(find.text('引き受けました。送った人にも伝わります'), findsOneWidget);
    expect(server.posted, hasLength(1), reason: '送り直すのは1回・1件だけ');
    expect(server.posted.single, hasLength(1), reason: '押し直しで担当のopを増やさない');
    expect(
      (server.posted.single.single['data']! as Map)['assigneeId'],
      'partner',
    );
    expect(server.ops.where((op) => op['kind'] == 'assignee'), hasLength(1));
  });

  testWidgets('開くたびに別の端末として始まる（端末に何も残さない）', (tester) async {
    Future<String> openAndTake() async {
      // 相手のブラウザは毎回まっさら（保存しないので、前の相手のものは残っていない）。
      final server = _Server()..seed(_add('devA', 1, 'devA:1', 'トイレットペーパーを買う'));
      await pump(tester, server, 'devA:1');
      await tester.tap(find.byKey(const ValueKey('one-take')));
      await tester.pumpAndSettle();
      return server.posted.single.single['deviceId']! as String;
    }

    final first = await openAndTake();
    final second = await openAndTake(); // 同じリンクを、別の人が開いた

    expect(first, isNot(second), reason: '開くたびに新しい端末id。前の相手のidを使い回さない');
    expect(<String>{first, second}.where((id) => id == 'dev'), isEmpty);
  });
}

/// 案件のopを1つ作る。
Map<String, Object?> _op(
  String deviceId,
  int lamport,
  OpKind kind,
  String issueId, {
  Map<String, Object?>? data,
}) => encodeOp(
  Op(
    deviceId: deviceId,
    lamport: lamport,
    kind: kind,
    issueId: issueId,
    at: DateTime(2026, 10, 6, 7, 30),
    data: data,
  ),
);

Map<String, Object?> _add(
  String deviceId,
  int lamport,
  String issueId,
  String title, {
  DateTime? dueDate,
  String? assigneeId,
}) => _op(
  deviceId,
  lamport,
  OpKind.add,
  issueId,
  data: <String, Object?>{
    'title': title,
    'assigneeId': assigneeId,
    'dueDate': dueDate,
    'recurrence': Recurrence.none,
    'seriesId': issueId,
  },
);

/// サーバーの代わり（本物は server/）。**絞り込み（issue=）も真似る。**
/// 契約そのものは server/test/worker.test.mjs が見ている。
class _Server {
  final List<Map<String, Object?>> ops = <Map<String, Object?>>[];

  /// 送られてきた便（opの束）。POSTごとに1つ。
  final List<List<Map<String, Object?>>> posted =
      <List<Map<String, Object?>>>[];

  /// アプリが実際に聞いてきたURL。
  final List<Uri> requested = <Uri>[];

  int? failPull;
  int? failPush;

  void seed(Map<String, Object?> op) => ops.add(op);

  http.Client get client => MockClient((request) async {
    final issue = request.url.queryParameters['issue'];

    if (request.method == 'GET') {
      requested.add(request.url);
      if (failPull != null) {
        return http.Response('{"error":"internal"}', failPull!);
      }

      final available = ops
          .where((op) => issue == null || op['issueId'] == issue)
          .toList();
      final since =
          int.tryParse(request.url.queryParameters['since'] ?? '0') ?? 0;
      final start = since < 0 || since > available.length
          ? available.length
          : since;
      final page = available.sublist(start);
      return http.Response(
        jsonEncode(<String, Object?>{
          'cursor': start + page.length,
          'ops': page,
          'skipped': 0,
        }),
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
    }

    if (request.method == 'POST') {
      if (failPush != null) {
        return http.Response('{"error":"internal"}', failPush!);
      }
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final incoming = (body['ops']! as List<Object?>)
          .cast<Map<String, Object?>>();
      var accepted = 0;
      for (final op in incoming) {
        if (ops.any((stored) => stored['id'] == op['id'])) continue;
        ops.add(op);
        accepted += 1;
      }
      posted.add(incoming);
      return http.Response(
        jsonEncode(<String, Object?>{
          'cursor': ops.length,
          'accepted': accepted,
          'duplicates': incoming.length - accepted,
        }),
        200,
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
    }

    return http.Response('{"error":"method_not_allowed"}', 405);
  });
}
