import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/home_page.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/session.dart';
import 'package:ie_koto/sync/storage.dart';
import 'foreground_sync_test.dart' show ControlledApi;
import 'support/memory_store.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('文字$scale倍で送信待ち・同期失敗・再試行・成功を表示する', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = IssueStore(
        deviceId: 'A',
        storage: DeviceStorage(MemoryStore()),
      );
      final api = ControlledApi()..fail = true;
      final session = SyncSession(store: store, api: api);
      store.add(title: '牛乳を買う');
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(store: store, session: session),
        ),
      );
      expect(find.text('端末に保存済み・送信待ち'), findsOneWidget);
      try {
        await session.syncNow();
      } catch (_) {}
      await tester.pump();
      expect(find.textContaining('同期できません'), findsOneWidget);
      api.fail = false;
      await tester.tap(find.text('再試行'));
      await tester.pump();
      await tester.pump();
      expect(find.text('サーバーと同期済み'), findsOneWidget);
      expect(find.textContaining('既読'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      session.close();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('単独利用では同期状態を表示しない', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(store: IssueStore(deviceId: 'A')),
      ),
    );
    expect(find.byKey(const ValueKey('sync-status')), findsNothing);
  });
}
