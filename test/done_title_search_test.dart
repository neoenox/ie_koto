import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/done_page.dart';
import 'package:ie_koto/detail_page.dart';
import 'package:ie_koto/store.dart';

void main() {
  testWidgets('completed title search matches Japanese substrings and clears', (
    tester,
  ) async {
    final store = IssueStore(clock: () => DateTime(2026, 10, 9, 12));
    final water = store.add(title: '水道修理');
    final second = store.add(title: '水道修理の確認');
    final papers = store.add(title: '保育園の書類');
    store.add(title: '水道修理予定'); // Uncompleted items must never match.
    for (final id in [water.id, second.id, papers.id]) {
      store.complete(id);
    }

    await tester.pumpWidget(MaterialApp(home: DonePage(store: store)));
    expect(find.text('水道修理'), findsOneWidget);
    expect(find.text('水道修理の確認'), findsOneWidget);
    expect(find.text('保育園の書類'), findsOneWidget);
    expect(find.text('水道修理予定'), findsNothing);

    final input = find.byKey(const ValueKey('done-title-search'));
    await tester.enterText(input, '水道');
    await tester.pumpAndSettle();
    expect(find.text('水道修理'), findsOneWidget);
    expect(find.text('水道修理の確認'), findsOneWidget);
    expect(find.text('保育園の書類'), findsNothing);
    expect(find.text('水道修理予定'), findsNothing);

    await tester.enterText(input, '該当なし');
    await tester.pumpAndSettle();
    expect(find.text('一致する用事はありません'), findsOneWidget);
    await tester.tap(find.byTooltip('検索をクリア'));
    await tester.pumpAndSettle();
    expect(find.text('一致する用事はありません'), findsNothing);
    expect(find.text('保育園の書類'), findsOneWidget);
  });

  testWidgets('search reacts to local store changes and navigates to details', (
    tester,
  ) async {
    final store = IssueStore(clock: () => DateTime(2026, 10, 9, 12));
    final done = store.add(title: '洗濯機を修理');
    store.complete(done.id);
    await tester.pumpWidget(MaterialApp(home: DonePage(store: store)));

    final input = find.byKey(const ValueKey('done-title-search'));
    await tester.enterText(input, '修理');
    await tester.pumpAndSettle();
    await tester.tap(find.text('洗濯機を修理'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, '修理');

    store.remove(done.id);
    await tester.pumpAndSettle();
    expect(find.text('まだおわったものはない'), findsOneWidget);
    expect(find.text('洗濯機を修理'), findsNothing);
  });

  testWidgets('empty completion history has no unnecessary search field', (
    tester,
  ) async {
    final store = IssueStore();
    await tester.pumpWidget(MaterialApp(home: DonePage(store: store)));
    expect(find.text('まだおわったものはない'), findsOneWidget);
    expect(find.byKey(const ValueKey('done-title-search')), findsNothing);
  });
}
