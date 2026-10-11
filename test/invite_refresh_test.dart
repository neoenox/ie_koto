import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/household_sheet.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/storage.dart';

/// #9: 同じシートを開いたままトークンを作り直すと、
/// 直後の招待リンクは新しいトークンで参加できる。
void main() {
  testWidgets('再発行した直後の招待は新しいトークンで参加できる', (tester) async {
    const oldToken = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const newToken = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const creds = SyncCredentials(
      baseUrl: 'http://localhost:9',
      householdId: 'h',
      token: oldToken,
    );
    final copied = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance;
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => messenger.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final store = IssueStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HouseholdSheet(
            current: creds,
            store: store,
            onRotateToken: () async => newToken,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('トークン・削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('トークンを作り直す'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('作り直す'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('招待リンクをコピー'));
    await tester.pumpAndSettle();
    expect(copied, hasLength(1));
    expect(copied.single, contains(newToken));
    expect(copied.single, isNot(contains(oldToken)));
    expect(tester.takeException(), isNull);
  });
}
