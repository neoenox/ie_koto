import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/detail_page.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/one_link.dart';
import 'package:ie_koto/store.dart';

/// 送る側: 詳細画面の「そのほか」→「リンクを送る」（[DetailPage]）。
///
/// 送るのは、アプリを入れていない相手。だから**リンク1本**に、
/// どの世帯の・どの1件を・誰として引き受けるかが入っている必要がある。
///
/// （相手が開いたときの画面は test/one_page_test.dart、本物のサーバー越しは
///   test/one_link_worker_e2e_test.dart）
void main() {
  const token = 'h8Qw3ZrT9xYb2LmN4PvC6SdF7GhJ1KlZ3XcV5BnM7Qa';

  /// クリップボードに渡された文字を捕まえる（実際にはコピーしない）。
  late List<String> copied;
  setUp(() {
    copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<Issue> pumpDetail(WidgetTester tester, {required bool withLink}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final store = IssueStore(deviceId: 'devA', clock: () => DateTime(2026, 10, 6, 8));
    final issue = store.add(title: 'トイレットペーパーを買う', dueDate: DateTime(2026, 10, 6));

    await tester.pumpWidget(MaterialApp(
      home: DetailPage(
        store: store,
        issueId: issue.id,
        linkFor: withLink
            ? (target) async => OneLink(
                  baseUrl: 'https://ie-koto.example.workers.dev',
                  householdId: 'hh_e2e0000000000000000000000000000',
                  token: token,
                  issueId: target.id,
                ).text
            : null,
      ),
    ));
    await tester.pumpAndSettle();
    return issue;
  }

  testWidgets('リンクを送る: 相手がブラウザで開けるURLがクリップボードに入る', (tester) async {
    final issue = await pumpDetail(tester, withLink: true);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('リンクを送る'), findsOneWidget);

    await tester.tap(find.text('リンクを送る'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    final url = Uri.parse(copied.single);
    expect(url.host, 'ie-koto.example.workers.dev');

    // 開いた相手が、その1件だけを見られるURLになっている。
    final opened = OneLink.fromUri(url);
    expect(opened, isNotNull);
    expect(opened!.issueId, issue.id);
    expect(opened.token, token);
    expect(url.fragment, contains(token), reason: 'トークンは断片（サーバーに送られない）');

    // 押した人にも、何が起きたか伝える。
    expect(find.text('リンクをコピーしました。相手はブラウザで開けます'), findsOneWidget);
  });

  testWidgets('同期の設定が無いときは、送るリンクを出さない（1人で使う形のまま）', (tester) async {
    await pumpDetail(tester, withLink: false);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(find.text('リンクを送る'), findsNothing);
    expect(find.text('名前を直す'), findsOneWidget, reason: 'ほかの項目はこれまでどおり');
    expect(copied, isEmpty);
  });
}
