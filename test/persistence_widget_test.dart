import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/main.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/storage.dart';

import 'support/memory_store.dart';

/// 保存から開いたときの画面（[persistence_test.dart] は保存の中身と同期の設定）。
///
/// HTTPを使うテストと同じファイルに置かないこと
/// （`testWidgets` を1つでも含むファイルでは、テスト用の仕組みが実HTTPを塞いでしまう）。
void main() {
  testWidgets('保存から開くと、デモを入れ直さず、残しておいたものが出る', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final device = MemoryStore();
    final first = IssueStore(
      deviceId: 'A',
      clock: _clock,
      storage: DeviceStorage(device),
    );
    first.add(title: 'トイレットペーパーを買う', dueDate: DateTime(2026, 10, 6));
    expect(first.all, hasLength(1));

    // アプリを開き直したのと同じ（同じ置き場を読み直す）。
    await tester.pumpWidget(
      IeKotoApp(
        store: IssueStore(clock: _clock, storage: DeviceStorage(device)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('トイレットペーパーを買う'), findsOneWidget);
    expect(find.text('牛乳を買う'), findsNothing, reason: 'デモは初回だけ');
  });

  testWidgets('初回は、これまでどおりデモが入った状態で始まる', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final device = MemoryStore();
    await tester.pumpWidget(
      IeKotoApp(
        store: IssueStore.demo(clock: _clock, storage: DeviceStorage(device)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('牛乳を買う'), findsOneWidget);
    expect(DeviceStorage(device).load().ops, isNotEmpty, reason: '初回のデモは端末に残る');
  });
}

DateTime _clock() => DateTime(2026, 10, 6, 8);
