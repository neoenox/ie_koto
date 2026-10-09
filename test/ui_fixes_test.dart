import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/household_sheet.dart';
import 'package:ie_koto/main.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/storage.dart';

/// UI/UXレビュー（#78〜#82）の回帰テスト。
void main() {
  Future<IssueStore> pumpWithIssue(WidgetTester tester, String title) async {
    final store = IssueStore();
    store.add(title: title);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    return store;
  }

  Future<void> openDetail(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets('#78 削除された詳細は空状態ともどるを出す', (tester) async {
    final store = await pumpWithIssue(tester, '消える依頼');
    await openDetail(tester, '消える依頼');
    expect(find.byKey(const ValueKey('detail-done')), findsOneWidget);

    store.remove(store.all.single.id);
    await tester.pumpAndSettle();

    expect(find.text('この1件はもうない'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'もどる'));
    await tester.pumpAndSettle();
    expect(find.text('家のこと'), findsOneWidget);
  });

  testWidgets('#79 詳細の完了はその場に残りもどすで戻せる', (tester) async {
    final store = await pumpWithIssue(tester, '終わらせる依頼');
    await openDetail(tester, '終わらせる依頼');

    await tester.tap(find.byKey(const ValueKey('detail-done')));
    await tester.pumpAndSettle();

    expect(store.byId(store.all.single.id)!.isDone, isTrue);
    // 詳細に留まっている（popしていない）。
    expect(find.text('おわったことにしました'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(SnackBar), matching: find.text('もどす')),
    );
    await tester.pumpAndSettle();
    expect(store.byId(store.all.single.id)!.isDone, isFalse);
  });

  testWidgets('#80 つながりをやめるは確認を挟む', (tester) async {
    Object? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showModalBottomSheet<Object?>(
                context: context,
                builder: (_) => const HouseholdSheet(
                  current: SyncCredentials(
                    baseUrl: 'https://ie-koto.example',
                    householdId: 'hh_test',
                    token: 'token',
                  ),
                ),
              );
            },
            child: const Text('開く'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('つながりをやめる'));
    await tester.pumpAndSettle();
    expect(find.text('つながりをやめますか？'), findsOneWidget);

    // やめない側を選ぶとシートに留まる。
    await tester.tap(find.text('つづける'));
    await tester.pumpAndSettle();
    expect(find.text('つながりをやめますか？'), findsNothing);
    expect(find.text('つながりをやめる'), findsOneWidget);

    // 確認してやめると HouseholdLeave が返る。
    await tester.tap(find.text('つながりをやめる'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('やめる'));
    await tester.pumpAndSettle();
    expect(result, isA<HouseholdLeave>());
  });

  testWidgets('#81 一覧行は一続きのラベルで読める', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const IeKotoApp());
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel(RegExp(r'牛乳を買う、.+')), findsOneWidget);
  });

  testWidgets('#82 名簿欄に表示名ラベルがある', (tester) async {
    final store = IssueStore();
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('household-open')));
    await tester.pumpAndSettle();

    final label = '${store.members.first.name}の表示名';
    expect(find.text(label), findsOneWidget);
  });

  testWidgets('#84 初回は案内で追加・完了・もどすまで進める', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final store = IssueStore();
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();

    // 初回だけ案内が出る。
    expect(find.text('いまは何もない'), findsOneWidget);
    expect(find.text('はじめの2ステップ'), findsOneWidget);
    expect(find.byKey(const ValueKey('empty-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('empty-household')), findsOneWidget);

    // 追加する→打ってEnterで登録され、案内は消える。
    await tester.tap(find.byKey(const ValueKey('empty-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('composer-field')),
      'はじめての追加',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('はじめての追加'), findsOneWidget);
    expect(find.text('いまは何もない'), findsNothing);

    // ホームでおわった→もどすで戻せる。
    await tester.tap(find.byKey(const ValueKey('done-はじめての追加')));
    await tester.pumpAndSettle();
    expect(store.byId(store.all.single.id)!.isDone, isTrue);
    await tester.tap(find.byKey(const ValueKey('undo-はじめての追加')));
    await tester.pumpAndSettle();
    expect(store.byId(store.all.single.id)!.isDone, isFalse);
  });

  testWidgets('#84 つなげるまでは手順が出る', (tester) async {
    final store = IssueStore();
    final issue = store.add(title: '消した依頼');
    store.remove(issue.id);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();

    expect(find.text('いまは何もない'), findsOneWidget);
    expect(find.text('はじめの2ステップ'), findsOneWidget);
    expect(find.byKey(const ValueKey('empty-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('empty-household')), findsOneWidget);
  });

  testWidgets('#89 まっさら起動の名簿は自分だけ', (tester) async {
    final store = IssueStore(startAlone: true);
    expect(store.members.map((m) => m.name).toList(), ['自分']);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();
    expect(find.text('パートナー'), findsNothing);
    expect(find.text('だれでも'), findsOneWidget);
  });

  testWidgets('手順からシートへ移ると追加欄は重ならない', (tester) async {
    final store = IssueStore();
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('empty-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('composer-field')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('empty-household')));
    await tester.pumpAndSettle();
    expect(find.text('家族とつなげる'), findsWidgets);
    expect(find.byKey(const ValueKey('composer-field')), findsNothing);
  });

  testWidgets('1件入れた後もつなげる案内は残る', (tester) async {
    final store = IssueStore();
    store.add(title: '最初の1件');
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();

    expect(find.text('最初の1件'), findsOneWidget);
    expect(find.byKey(const ValueKey('empty-household')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('empty-household')));
    await tester.pumpAndSettle();
    expect(find.text('あたらしくつくる'), findsOneWidget);
  });

  testWidgets('V2-2 詳細の完了後は常設のもどすで戻せる', (tester) async {
    final store = IssueStore();
    store.add(title: '終わらせる依頼');
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('終わらせる依頼'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('detail-done')));
    await tester.pumpAndSettle();
    expect(store.all.single.isDone, isTrue);

    // Snackbarを消しても詳細のもどすが残る。
    ScaffoldMessenger.of(
      tester.element(find.text('終わらせる依頼')),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.text('おわったことにしました'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('detail-undo')));
    await tester.pumpAndSettle();
    expect(store.all.single.isDone, isFalse);
  });
}
