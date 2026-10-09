import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/household_sheet.dart';
import 'package:ie_koto/store.dart';

void main() {
  Future<void> showSheet(WidgetTester tester, IssueStore store) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showHouseholdSheet(
                context,
                current: null,
                store: store,
              ),
              child: const Text('家族設定'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('家族設定'));
    await tester.pumpAndSettle();
  }

  Finder memberInput(String id) => find.descendant(
    of: find.byKey(ValueKey(id)),
    matching: find.byType(TextField),
  );

  Future<void> enterName(
    WidgetTester tester,
    String memberId,
    String name,
  ) async {
    final field = memberInput(memberId);
    await tester.ensureVisible(field);
    await tester.enterText(field, name);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('other member rename requires confirmation and cancel rolls back', (
    tester,
  ) async {
    final store = IssueStore();
    expect(store.meId, 'me');
    await showSheet(tester, store);
    await enterName(tester, 'partner', '新しい相手の名前');

    expect(find.text('ほかの人の名前を変えますか？'), findsOneWidget);
    expect(store.memberById('partner')!.name, 'パートナー');
    await tester.tap(find.text('やめる'));
    await tester.pumpAndSettle();
    expect(store.memberById('partner')!.name, 'パートナー');
    expect(tester.widget<TextField>(memberInput('partner')).controller!.text,
        'パートナー');

    await enterName(tester, 'partner', '新しい相手の名前');
    expect(store.memberById('partner')!.name, 'パートナー');
    await tester.tap(find.byKey(const ValueKey('confirm-other-member-rename')));
    await tester.pumpAndSettle();
    expect(store.memberById('partner')!.name, '新しい相手の名前');
  });

  testWidgets('editing own name does not require another-person confirmation', (
    tester,
  ) async {
    final store = IssueStore();
    await showSheet(tester, store);
    await enterName(tester, 'me', '自分の新しい名前');
    expect(find.text('ほかの人の名前を変えますか？'), findsNothing);
    expect(store.memberById('me')!.name, '自分の新しい名前');
  });
}
