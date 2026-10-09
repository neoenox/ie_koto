import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/detail_page.dart';
import 'package:ie_koto/household_sheet.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/storage.dart';

void main() {
  testWidgets('removed detail has an explanation and a way back', (tester) async {
    final store = IssueStore();
    final issue = store.add(title: '消された用事');
    await tester.pumpWidget(
      MaterialApp(home: DetailPage(store: store, issueId: issue.id)),
    );
    await tester.pumpAndSettle();
    store.remove(issue.id);
    await tester.pumpAndSettle();
    expect(find.text('このやることはもうありません'), findsOneWidget);
    expect(find.text('もどる'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });

  testWidgets('detail completion remains visible and can be undone', (tester) async {
    final store = IssueStore();
    final issue = store.add(title: '完了の確認');
    await tester.pumpWidget(
      MaterialApp(home: DetailPage(store: store, issueId: issue.id)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('detail-done')));
    await tester.pump();
    expect(store.byId(issue.id)!.isDone, isTrue);
    expect(find.text('完了の確認'), findsOneWidget);
    await tester.tap(find.text('もどす'));
    await tester.pump();
    expect(store.byId(issue.id)!.isDone, isFalse);
  });

  testWidgets('leaving a household requires confirmation', (tester) async {
    Object? result;
    const credentials = SyncCredentials(
      baseUrl: 'https://example.invalid',
      householdId: 'test-household-123456',
      token: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showHouseholdSheet(
                  context,
                  current: credentials,
                );
              },
              child: const Text('設定を開く'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('設定を開く'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('つながりをやめる'));
    await tester.pumpAndSettle();
    expect(find.text('つながりをやめますか？'), findsOneWidget);
    expect(result, isNull);
    await tester.tap(find.text('やめる'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.tap(find.text('つながりをやめる'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-leave')));
    await tester.pumpAndSettle();
    expect(result, isA<HouseholdLeave>());
  });

  testWidgets('member name fields have unique accessible labels', (tester) async {
    final store = IssueStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HouseholdSheet(current: null, store: store)),
      ),
    );
    await tester.pumpAndSettle();
    final labels = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((field) => field.decoration?.labelText)
        .toList();
    expect(labels, contains('自分の表示名'));
    expect(labels, contains('パートナーの表示名'));
  });
}
