import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/detail_page.dart';
import 'package:ie_koto/household_sheet.dart';
import 'package:ie_koto/store.dart';

void main() {
  testWidgets('名前欄を移動しても、両方の名前が保存される', (tester) async {
    final store = IssueStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HouseholdSheet(current: null, store: store)),
      ),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    // 自分の行だけ編集できる。まず自分の名前を変える。
    await tester.enterText(fields.at(1), 'あき');
    await tester.tap(fields.at(0));
    await tester.pumpAndSettle();
    expect(store.memberById('me')!.name, 'あき');
    // 本人を切り替えて、もう1人の名前を変える。
    await tester.tap(find.widgetWithText(ChoiceChip, 'パートナー'));
    await tester.pumpAndSettle();
    await tester.enterText(fields.at(1), 'はる');
    await tester.tap(fields.at(0));
    await tester.pumpAndSettle();
    expect(store.memberById('me')!.name, 'あき');
    expect(store.memberById('partner')!.name, 'はる');
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
