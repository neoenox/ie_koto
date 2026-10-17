import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/main.dart';
import 'package:ie_koto/store.dart';

void main() {
  testWidgets('#70 確定後のEnterで2件目を作らない（IMEの二重送信なし）', (tester) async {
    final store = IssueStore();
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('composer-field')),
      '牛乳を買う',
    );
    // 1回目のEnter（IME確定後の送信）で1件登録される。
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(store.all.length, 1);
    expect(store.all.single.title, '牛乳を買う');

    // 欄は空になっている。同じEnterがもう一度届いても増えない。
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(store.all.length, 1, reason: '二度目のEnterで重複登録しない');
    expect(find.text('やることを入力してください'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('#70 変換中（composing）の確定→Enterで1件だけ登録する', (tester) async {
    final store = IssueStore();
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();

    // 変換中（下線つき）: ひらがなの未確定文字列。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ぎゅうにゅう',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 0, end: 6),
      ),
    );
    await tester.pump();
    expect(store.all, isEmpty, reason: '変換中はまだ登録しない');

    // 変換を確定してからEnterを押す。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '牛乳を買う',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(store.all.length, 1);
    expect(store.all.single.title, '牛乳を買う');
    expect(tester.takeException(), isNull);
  });

  testWidgets('#70 追加ボタンの連打でも1件だけ登録する', (tester) async {
    final store = IssueStore();
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('composer-field')),
      'ゴミ出し',
    );
    final button = find.widgetWithText(FilledButton, '追加');
    await tester.tap(button);
    await tester.pumpAndSettle();
    // 1件目で欄が空になるため、続けて押しても増えない。
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(store.all.length, 1);
    expect(store.all.single.title, 'ゴミ出し');
    expect(tester.takeException(), isNull);
  });
}
