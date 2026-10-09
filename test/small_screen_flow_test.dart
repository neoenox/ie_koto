import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/main.dart';
import 'package:ie_koto/store.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('文字$scale倍・キーボード表示でも追加欄がoverflowしない', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = IssueStore();
      await tester.pumpWidget(IeKotoApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('追加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('明日'));
      await tester.tap(find.text(store.memberLabel(store.members.first.id)!));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('明日'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'キーボード確認',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final issue = store.all.single;
      expect(issue.assigneeId, store.members.first.id);
      final today = store.today;
      expect(issue.dueDate, DateTime(today.year, today.month, today.day + 1));
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(find.text('明日'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  for (final scale in [1.0, 2.0]) {
    testWidgets('320px・文字$scale倍で追加・詳細・コメント・設定にoverflowがない', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = IssueStore();
      await tester.pumpWidget(IeKotoApp(store: store));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'ホーム');
      await tester.tap(find.text('追加'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '追加');
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byKey(const ValueKey('composer-field'))),
        ).scale(16),
        16 * scale,
        reason: '実際の入力欄に文字拡大が届いている',
      );
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        '牛乳を買う',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '登録後');
      await tester.tap(find.text('牛乳を買う'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '詳細');
      await tester.enterText(find.byType(TextField), '低脂肪でお願いします');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'コメント入力');
      await tester.tap(find.byKey(const ValueKey('detail-comment-send')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'コメント送信');
      await tester.tap(find.byTooltip('もどる'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('household-open')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '世帯設定');
    });
  }
}
