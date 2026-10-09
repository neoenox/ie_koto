import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/main.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/widgets.dart';
import 'package:ie_koto/sync/log.dart';

Op remote(int clock) => Op(
  deviceId: 'remote',
  lamport: clock,
  kind: OpKind.add,
  issueId: 'remote:$clock',
  at: DateTime(2026, 10, 9),
  data: {'title': '既存の依頼'},
);

void main() {
  testWidgets('ホーム完了の上限拒否は行と未完了を維持する', (tester) async {
    final store = IssueStore(clock: () => DateTime(2026, 10, 9))
      ..receive([remote(2147483647)]);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('おわった'));
    await tester.pumpAndSettle();
    expect(store.all.single.isDone, isFalse);
    expect(store.ops, hasLength(1));
    expect(find.text('既存の依頼'), findsOneWidget);
    expect(find.text(ClockExhaustedException().message), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ホーム取り消しの上限拒否は完了を維持する', (tester) async {
    final store = IssueStore(clock: () => DateTime(2026, 10, 9));
    final issue = store.add(title: '取り消せない完了');
    store.complete(issue.id);
    store.receive([remote(2147483647)]);
    final before = List<Op>.of(store.ops);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('もどす'));
    await tester.pumpAndSettle();
    expect(store.byId(issue.id)!.isDone, isTrue);
    expect(store.ops, before);
    expect(find.text('取り消せない完了'), findsOneWidget);
    expect(find.text(ClockExhaustedException().message), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('正常な日付と曜日の保存は選択画面を閉じる', (tester) async {
    final store = IssueStore(clock: () => DateTime(2026, 10, 9))
      ..receive([remote(1)]);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('既存の依頼'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('いつまで'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日付を選ぶ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(store.all.single.dueDate, DateTime(2026, 10, 15));
    await tester.tap(find.text('くりかえし'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('月'));
    await tester.tap(find.text('木'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('この曜日で毎週にする'));
    await tester.pumpAndSettle();
    expect(find.text('この曜日で毎週にする'), findsNothing);
    expect(store.all.single.recurrence.weekdays, containsAll([1, 4]));
    expect(store.ops, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('上限拒否でもカスタム日付を再表示して保持する', (tester) async {
    final store = IssueStore(clock: () => DateTime(2026, 10, 9))
      ..receive([remote(2147483647)]);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('既存の依頼'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('いつまで'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日付を選ぶ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(
      tester
          .widget<DatePickerDialog>(find.byType(DatePickerDialog))
          .initialDate,
      DateTime(2026, 10, 15),
    );
    expect(store.all.single.dueDate, isNull);
    expect(store.ops, hasLength(1));
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(store.ops, hasLength(1));
  });

  testWidgets('上限拒否でも曜日選択を閉じず保持する', (tester) async {
    final store = IssueStore()..receive([remote(2147483647)]);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('既存の依頼'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('くりかえし'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('月'));
    await tester.tap(find.text('木'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('この曜日で毎週にする'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('この曜日で毎週にする'), findsOneWidget);
    final selectedDays = tester
        .widgetList<MiniChip>(find.byType(MiniChip))
        .where((chip) => chip.selected)
        .map((chip) => chip.label);
    expect(selectedDays, containsAll(['月', '木']));
    expect(store.all.single.recurrence.isNone, isTrue);
    expect(store.ops, hasLength(1));
  });

  testWidgets('上限拒否でも追加入力を保持して理由を表示する', (tester) async {
    final store = IssueStore()..receive([remote(2147483647)]);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('composer-field')),
      '消さない入力',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('消さない入力'), findsOneWidget);
    expect(find.textContaining('記録の上限に達したため変更できません'), findsOneWidget);
    expect(store.all, hasLength(1));
  });

  testWidgets('上限拒否でもコメント入力を保持して理由を表示する', (tester) async {
    final store = IssueStore()..receive([remote(2147483647)]);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('既存の依頼'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '消さないコメント');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('detail-comment-send')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('消さないコメント'), findsOneWidget);
    expect(find.textContaining('記録の上限に達したため変更できません'), findsOneWidget);
    expect(store.ops, hasLength(1));
  });

  testWidgets('上限拒否の完了は詳細を閉じず状態を変えない', (tester) async {
    final store = IssueStore()..receive([remote(2147483647)]);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('既存の依頼'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('detail-done')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('detail-done')), findsOneWidget);
    expect(find.textContaining('記録の上限に達したため変更できません'), findsOneWidget);
    expect(store.all.single.isDone, isFalse);
    expect(store.ops, hasLength(1));
  });

  testWidgets('上限拒否の削除は詳細を閉じず依頼を残す', (tester) async {
    final store = IssueStore()..receive([remote(2147483647)]);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('既存の依頼'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('そのほか'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('detail-done')), findsOneWidget);
    expect(find.textContaining('記録の上限に達したため変更できません'), findsOneWidget);
    expect(store.all, hasLength(1));
    expect(store.ops, hasLength(1));
  });

  testWidgets('上限拒否の名前変更はダイアログと入力を残す', (tester) async {
    final store = IssueStore()..receive([remote(2147483647)]);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('既存の依頼'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('そのほか'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('名前を変更'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '残す名前',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('残す名前'), findsOneWidget);
    expect(store.all.single.title, '既存の依頼');
    expect(store.ops, hasLength(1));
  });

  test('時計上限で直接書込みを拒否しログと送信待ちを変えない', () {
    final device = Device('local')..receive([remote(2147483647)]);
    final before = List<Op>.of(device.log);
    expect(
      () => device.write(
        OpKind.comment,
        before.single.issueId,
        data: {'text': '残したい入力'},
      ),
      throwsStateError,
    );
    expect(device.lamport, 2147483647);
    expect(device.log, before);
    expect(device.outbox, isEmpty);
  });

  test('複数opの追加は残り1枠なら部分書込みせず拒否する', () {
    final store = IssueStore(deviceId: 'local');
    store.receive([remote(2147483646)]);
    final before = List<Op>.of(store.ops);
    expect(
      () => store.add(title: '新規', status: IssueStatus.doing),
      throwsStateError,
    );
    expect(store.ops, before);
    expect(store.all, hasLength(1));
  });

  test('完了から保留への2op変更は残り1枠なら完了を維持する', () {
    final store = IssueStore(deviceId: 'local');
    final issue = store.add(title: '完了済み');
    store.complete(issue.id);
    store.receive([remote(2147483646)]);
    final before = List<Op>.of(store.ops);
    expect(
      () => store.setStatus(issue.id, IssueStatus.waiting),
      throwsA(isA<ClockExhaustedException>()),
    );
    expect(store.ops, before);
    expect(store.byId(issue.id)!.isDone, isTrue);
    store.rename(issue.id, '最後の枠で名前変更');
    expect(store.ops.last.id, 'local:2147483647');
    expect(store.byId(issue.id)!.isDone, isTrue);
  });

  test('settleの複数の次回生成は残り1枠なら全体を取り消す', () {
    final store = IssueStore(deviceId: 'local');
    final at = DateTime(2026, 10, 9);
    store.receive([
      for (var n = 1; n <= 2; n++) ...[
        Op(
          deviceId: 'remote',
          lamport: n,
          kind: OpKind.add,
          issueId: 'task$n',
          at: at,
          data: {'title': '毎日$n', 'recurrence': Recurrence.daily},
        ),
        Op(
          deviceId: 'remote',
          lamport: n + 2,
          kind: OpKind.complete,
          issueId: 'task$n',
          at: at,
        ),
      ],
      remote(2147483646),
    ]);
    final before = List<Op>.of(store.ops);
    final count = store.all.length;
    expect(() => store.settle(), throwsA(isA<ClockExhaustedException>()));
    expect(store.ops, before);
    expect(store.all, hasLength(count));
    expect(store.byId('task1')!.isDone, isTrue);
    expect(store.byId('task2')!.isDone, isTrue);
    // 片方だけ次回を生成して保存することはない。
    expect(store.all.where((issue) => !issue.isDone), hasLength(1));
  });

  test('定期完了と次の依頼は残り1枠なら全体を拒否する', () {
    final store = IssueStore(deviceId: 'local');
    final issue = store.add(title: '毎日', recurrence: Recurrence.daily);
    store.receive([remote(2147483646)]);
    final before = List<Op>.of(store.ops);
    expect(() => store.complete(issue.id), throwsStateError);
    expect(store.ops, before);
    expect(store.byId(issue.id)!.isDone, isFalse);
  });

  test('途中拒否でID索引・壁時計・既存送信待ちを戻し最後の枠を再利用できる', () {
    final device = Device('local');
    final pending = device.write(OpKind.add, 'local:1', data: {'title': '未送信'});
    device.receive([remote(2147483646)]);
    final before = List<Op>.of(device.log);
    expect(
      () => device.writeAtomically(() {
        device.write(
          OpKind.comment,
          pending.issueId,
          at: DateTime(2099),
          data: {'text': '取り消す'},
        );
        device.write(OpKind.comment, pending.issueId, data: {'text': '枠不足'});
      }),
      throwsA(isA<ClockExhaustedException>()),
    );
    expect(device.log, before);
    expect(device.outbox, [pending]);
    expect(device.lamport, 2147483646);
    expect(device.nextOpId(), 'local:2147483647');
    final retry = device.write(
      OpKind.comment,
      pending.issueId,
      data: {'text': '保存する'},
    );
    expect(retry.id, 'local:2147483647');
    expect(retry.at, pending.at.add(const Duration(minutes: 1)));
    expect(device.outbox, [pending, retry]);
    device.receive([retry]);
    expect(
      device.log,
      hasLength(before.length + 1),
      reason: '取り消したIDを再利用しても重複受信は畳む',
    );
  });

  test('取り消したIDはknown索引に残らず受信できる', () {
    final device = Device('local')..receive([remote(2147483646)]);
    late Op rolledBack;
    expect(
      () => device.writeAtomically(() {
        rolledBack = device.write(
          OpKind.comment,
          'remote:2147483646',
          data: {'text': '取消対象'},
        );
        device.write(OpKind.comment, 'remote:2147483646');
      }),
      throwsA(isA<ClockExhaustedException>()),
    );
    device.receive([rolledBack, rolledBack]);
    expect(device.log, hasLength(2));
    expect(device.log.last, rolledBack);
    expect(device.outbox, isEmpty);
  });

  test('単一opは最後の1枠へ正常に書ける', () {
    final device = Device('local')..receive([remote(2147483646)]);
    final written = device.write(
      OpKind.comment,
      'remote:2147483646',
      data: {'text': '最後の正常操作'},
    );
    expect(written.lamport, 2147483647);
    expect(device.outbox.single, written);
  });
}
