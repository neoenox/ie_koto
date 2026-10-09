import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ie_koto/main.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/session.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const baseUrl = String.fromEnvironment('E2E_API_URL');

  testWidgets('2人の依頼・担当・会話・オフライン完了・名前共有', (tester) async {
    expect(baseUrl, isNotEmpty, reason: 'E2E_API_URL にローカルWorkerを指定する');
    final household = 'hh_e2e${DateTime.now().microsecondsSinceEpoch}';
    final a = IssueStore(deviceId: 'e2eA');
    final b = IssueStore(deviceId: 'e2eB');
    b.setMeId('partner');
    SyncSession session(IssueStore store, String url) => SyncSession(
      store: store,
      api: SyncApi(
        baseUrl: url,
        householdId: household,
        token: 'e2e-token-not-for-production-0123456789',
      ),
    );
    final sa = session(a, baseUrl);
    final sb = session(b, baseUrl);
    addTearDown(sa.close);
    addTearDown(sb.close);
    Future<void> show(IssueStore store) async {
      debugPrint('E2E show ${store.meId}');
      await tester.pumpWidget(IeKotoApp(key: UniqueKey(), store: store));
      await tester.pumpAndSettle();
    }

    // HTTPとセッション終了処理を実時間のzoneで完了させる。
    Future<void> sync(SyncSession session) async {
      await tester.runAsync(() async {
        await session.syncNow();
        await Future<void>.delayed(Duration.zero);
      });
    }

    Future<void> detail() async {
      await tester.tap(find.text('E2E 家族の買い物'));
      await tester.pumpAndSettle();
    }

    Future<void> comment(String text) async {
      debugPrint('E2E comment: $text');
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('detail-comment-send')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(text),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(text), findsOneWidget);
    }

    await show(a);
    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('composer-field')),
      'E2E 家族の買い物',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await sync(sa);
    await sync(sb);
    await show(b);
    await detail();
    await tester.tap(find.text('だれが'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自分').last);
    await tester.pumpAndSettle();
    final id = b.all.single.id;
    expect(b.byId(id)!.assigneeId, b.meId);
    await comment('帰りに買ってくるね');
    await sync(sb);
    await sync(sa);
    await show(a);
    await detail();
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('帰りに買ってくるね'), findsOneWidget);
    expect(a.byId(id)!.assigneeId, b.meId);
    await comment('ありがとう、低脂肪で');
    await sync(sa);
    await sync(sb);
    await show(b);
    await detail();
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('ありがとう、低脂肪で'), findsOneWidget);
    final messages = b
        .byId(id)!
        .events
        .where((e) => e.text == '帰りに買ってくるね' || e.text == 'ありがとう、低脂肪で')
        .toList();
    expect(messages.map((e) => e.actorId).toSet(), {a.meId, b.meId});

    // 実際に接続できないAPIで同期を試し、未送信データが保持されることも検証。
    final offline = session(b, 'http://127.0.0.1:1');
    addTearDown(offline.close);
    await comment('買えたよ（オフライン）');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('detail-done')),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('detail-done')));
    await tester.pumpAndSettle();
    debugPrint('E2E offline sync');
    Object? failure;
    await tester.runAsync(() async {
      try {
        await offline.syncNow();
      } catch (error) {
        failure = error;
      }
    });
    expect(failure, isA<SyncException>());
    debugPrint('E2E reconnect');
    expect(b.outbox, isNotEmpty);
    expect(a.byId(id)!.isDone, isFalse);
    await sync(sb);
    await sync(sa);
    expect(a.byId(id)!.isDone, isTrue);
    expect(b.outbox, isEmpty);
    await sync(sb);
    await sync(sa);
    expect(
      a.byId(id)!.events.where((e) => e.text == '買えたよ（オフライン）'),
      hasLength(1),
    );

    await show(a);
    await tester.tap(find.byKey(const ValueKey('household-open')));
    await tester.pumpAndSettle();
    final name = find.descendant(
      of: find.byKey(ValueKey(a.meId)),
      matching: find.byType(TextField),
    );
    await tester.ensureVisible(name);
    await tester.enterText(name, 'あき');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final meA = a.meId;
    final meB = b.meId;
    await sync(sa);
    await sync(sb);
    expect(b.members.firstWhere((m) => m.id == meA).name, 'あき');
    expect(a.meId, meA);
    expect(b.meId, meB);
    expect(meA, isNot(meB));
    await show(b);
    await tester.tap(find.byKey(const ValueKey('household-open')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'あき'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
