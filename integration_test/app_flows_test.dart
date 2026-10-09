import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ie_koto/main.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestDevice implements KeyValueStore {
  _TestDevice(this.prefs, this.prefix);
  final SharedPreferences prefs;
  final String prefix;

  @override
  String? read(String key) => prefs.getString('$prefix$key');

  @override
  void write(String key, String? value) {
    if (value == null) {
      prefs.remove('$prefix$key');
    } else {
      prefs.setString('$prefix$key', value);
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('追加・コメント・完了取り消し・設定が端末保存から復元される', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // テスト専用の保存領域。通常の利用データを消さない。
    final prefs = await SharedPreferences.getInstance();
    final scope = 'e2e_${DateTime.now().microsecondsSinceEpoch}.';
    final device = _TestDevice(prefs, scope);
    addTearDown(() async {
      for (final key in prefs.getKeys().where((key) => key.startsWith(scope))) {
        await prefs.remove(key);
      }
    });
    final storage = DeviceStorage(device);
    final store = IssueStore(storage: storage);
    await tester.pumpWidget(IeKotoApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('追加'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('composer-field')),
      'E2E 牛乳を買う',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('とじる'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('E2E 牛乳を買う'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '低脂肪でお願いします');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('detail-comment-send')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('低脂肪でお願いします'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('低脂肪でお願いします'), findsOneWidget);
    expect(store.all.single.isDone, isFalse);
    await tester.tap(find.byTooltip('もどる'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('done-E2E 牛乳を買う')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('undo-E2E 牛乳を買う')));
    await tester.pumpAndSettle();
    expect(store.all.single.isDone, isFalse);
    await tester.tap(find.byKey(const ValueKey('household-open')));
    await tester.pumpAndSettle();
    Finder nameField(String id) => find.descendant(
      of: find.byKey(ValueKey(id)),
      matching: find.byType(TextField),
    );
    final first = nameField(store.members[0].id);
    final second = nameField(store.members[1].id);
    await tester.ensureVisible(first);
    await tester.enterText(first, 'あき');
    await tester.ensureVisible(second);
    await tester.tap(second);
    await tester.pumpAndSettle();
    await tester.enterText(second, 'はる');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    final reopened = IssueStore(
      storage: DeviceStorage(_TestDevice(prefs, scope)),
    );
    await tester.pumpWidget(IeKotoApp(store: reopened));
    await tester.pumpAndSettle();
    expect(find.text('E2E 牛乳を買う'), findsOneWidget);
    expect(reopened.members.map((m) => m.name), containsAll(['あき', 'はる']));
    await tester.tap(find.text('E2E 牛乳を買う'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('低脂肪でお願いします'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('低脂肪でお願いします'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('くりかえし'),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(320, 568));
    await tester.pumpAndSettle();
    await tester.tap(find.text('くりかえし'));
    await tester.pumpAndSettle();
    final lastOption = find.text('終わってから60日ごと');
    await tester.ensureVisible(lastOption);
    await tester.tap(lastOption);
    await tester.pumpAndSettle();
    expect(reopened.all.single.recurrence.everyDays, 60);
    expect(tester.takeException(), isNull);
  });
}
