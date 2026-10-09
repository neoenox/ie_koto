import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/detail_page.dart';
import 'package:ie_koto/household_sheet.dart';
import 'package:ie_koto/store.dart';

void main() {
  testWidgets('自分の名前は移動時に保存され、他人の名前は確認後に保存される', (tester) async {
    final store = IssueStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HouseholdSheet(current: null, store: store)),
      ),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), 'あき');
    await tester.tap(fields.at(2));
    await tester.pumpAndSettle();
    expect(store.members.first.name, 'あき');
    await tester.enterText(fields.at(2), 'はる');
    await tester.tap(find.text('この端末を使う人'));
    await tester.pumpAndSettle();
    expect(store.members.first.name, 'あき');
    expect(store.members[1].name, 'パートナー');
    expect(find.text('ほかの人の名前を変えますか？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-other-member-rename')));
    await tester.pumpAndSettle();
    expect(store.members[1].name, 'はる');
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(360, 800), const Size(320, 568)]) {
    testWidgets('小さい画面 $size でも最後のくりかえしを選べる', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = IssueStore();
      final issue = store.add(title: 'くりかえし確認');
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(store: store, issueId: issue.id),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('くりかえし'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final lastOption = find.text('終わってから60日ごと');
      await tester.ensureVisible(lastOption);
      await tester.pumpAndSettle();
      await tester.tap(lastOption);
      await tester.pumpAndSettle();
      expect(store.byId(issue.id)!.recurrence.everyDays, 60);
      expect(tester.takeException(), isNull);
    });
  }
}
