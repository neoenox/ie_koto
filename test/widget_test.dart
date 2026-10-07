import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/main.dart';
import 'package:ie_koto/store.dart';

void main() {
  /// 実機に近い縦長の画面で見る（既定の800x600だと一覧の下が見えなくなる）。
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const IeKotoApp());
    await tester.pumpAndSettle();
  }

  testWidgets('ホームは今日とあとでだけを出す', (tester) async {
    await pumpApp(tester);
    expect(find.text('家のこと'), findsOneWidget);
    expect(find.text('今日'), findsOneWidget);
    expect(find.text('あとで'), findsOneWidget);
    expect(find.text('牛乳を買う'), findsOneWidget);
  });

  testWidgets('デモの案件がすべてホームに出る', (tester) async {
    await pumpApp(tester);
    // 定期の連なり（エアコン）も、opから組み上げた履歴が同じように並ぶ。
    for (final title in const [
      '牛乳を買う',
      '保育園の書類を書く',
      'お風呂そうじ',
      'ゴミ出し',
      'エアコンのフィルターそうじ',
      '子供の靴を買う',
      '廊下の電球を交換する',
      '水道から変な音がする',
    ]) {
      expect(find.text(title), findsOneWidget, reason: '$title がホームに出ていない');
    }
  });

  testWidgets('追加はタイトルだけでできる', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('composer-field')), 'トイレットペーパーを買う');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('トイレットペーパーを買う'), findsOneWidget);
  });

  testWidgets('未入力の追加は案内して、入力後はボタンで登録できる', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('composer-field'));
    await tester.enterText(field, '   ');
    await tester.tap(find.widgetWithText(FilledButton, '追加'));
    await tester.pumpAndSettle();
    expect(find.text('やることを入力してください'), findsOneWidget);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

    await tester.enterText(field, '追加ボタンで登録');
    await tester.pumpAndSettle();
    expect(find.text('やることを入力してください'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '追加'));
    await tester.pumpAndSettle();
    expect(find.text('追加ボタンで登録'), findsOneWidget);
  });

  testWidgets('完了は1タップ、もどすで戻せる', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('done-牛乳を買う')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('undo-牛乳を買う')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('undo-牛乳を買う')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('undo-牛乳を買う')), findsNothing);
    expect(find.text('牛乳を買う'), findsOneWidget);
  });

  testWidgets('完了したまま置いておくと、しばらくして一覧から消える', (tester) async {
    var now = DateTime(2026, 10, 6, 9);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(IeKotoApp(store: IssueStore.demo(clock: () => now)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('done-牛乳を買う')));
    await tester.pumpAndSettle();
    expect(find.text('牛乳を買う'), findsOneWidget);

    now = now.add(IssueStore.undoWindow + const Duration(seconds: 1));
    await tester.pump(IssueStore.undoWindow + const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('牛乳を買う'), findsNothing);
  });

  testWidgets('詳細にはこれまでのやりとりが出る', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('廊下の電球を交換する'));
    await tester.pumpAndSettle();
    expect(find.text('これまで'), findsOneWidget);
    expect(find.text('電球切れてた'), findsOneWidget);
    expect(find.text('だれが'), findsOneWidget);
    expect(find.text('くりかえし'), findsOneWidget);
  });

  testWidgets('定期案件は前回・前々回が残る', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('エアコンのフィルターそうじ'));
    await tester.pumpAndSettle();
    expect(find.textContaining('前回'), findsOneWidget);
    expect(find.textContaining('前々回'), findsOneWidget);
  });

  testWidgets('たくさんあっても、追加した行まで送って見えるようにする', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final store = IssueStore.demo(clock: () => DateTime(2026, 10, 6, 9));
    for (var i = 0; i < 25; i++) {
      store.add(title: '案件$i');
    }
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();

    // 今日の案件を足す。一覧の末尾（あとで）ではなく、上の「今日」に入る。
    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今日').last);
    await tester.enterText(find.byKey(const ValueKey('composer-field')), '今日の追加ぶん');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.text('今日の追加ぶん'));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(rect.top >= 0 && rect.bottom <= screen.height, isTrue, reason: '追加した行が画面内にある: $rect');
  });

  testWidgets('消すときは確かめる。やめるなら残り、消すなら一覧から無くなる', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('子供の靴を買う'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('そのほか'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('を削除しますか'), findsOneWidget);

    await tester.tap(find.text('やめる'));
    await tester.pumpAndSettle();
    expect(find.text('これまで'), findsOneWidget, reason: 'やめたら詳細に残る');

    await tester.tap(find.byTooltip('そのほか'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();
    expect(find.text('子供の靴を買う'), findsNothing);
  });

  testWidgets('追加・完了・取り消しの履歴にそれぞれの操作者を表示する', (tester) async {
    final store = IssueStore();
    final issue = store.add(title: '操作者の確認');
    store.setMeId('partner');
    store.complete(issue.id);
    store.setMeId('me');
    store.undoComplete(issue.id);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text(issue.title));
    await tester.pumpAndSettle();
    expect(find.text('操作：自分'), findsNWidgets(2));
    expect(find.text('操作：パートナー'), findsOneWidget);
  });

  testWidgets('ひとこと送信は案件を完了せず、独立した完了ボタンだけが完了する', (tester) async {
    final store = IssueStore();
    final issue = store.add(title: '送信と完了の確認');
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text(issue.title));
    await tester.pumpAndSettle();
    final send = find.byKey(const ValueKey('detail-comment-send'));
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '牛乳を買ってきます');
    await tester.pumpAndSettle();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.text('牛乳を買ってきます'), findsOneWidget);
    expect(store.byId(issue.id)!.isDone, isFalse);
    await tester.tap(find.byKey(const ValueKey('detail-done')));
    await tester.pumpAndSettle();
    expect(store.byId(issue.id)!.isDone, isTrue);
  });

  testWidgets('キーボードが出ても、「ひとこと」の入力欄はキーボードの上に見える', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('廊下の電球を交換する'));
    await tester.pumpAndSettle();

    // キーボードの高さ（物理ピクセル。1080x2400 の下から 800px = 約267dp）を出す。
    tester.view.viewInsets = const FakeViewPadding(bottom: 800);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final keyboardTop = screen.height - 800 / tester.view.devicePixelRatio;
    final field = tester.getRect(find.byType(TextField));
    expect(field.bottom <= keyboardTop, isTrue, reason: '入力欄($field)がキーボード(上端 $keyboardTop)に隠れている');
    expect(tester.getRect(find.byKey(const ValueKey('detail-comment-send'))).bottom <= keyboardTop, isTrue);
  });
}
