import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/detail_page.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/store.dart';

void main() {
  testWidgets('previous and penultimate completions open their own details',
      (tester) async {
    final store = IssueStore.demo(clock: () => DateTime(2026, 10, 6, 9));
    final active = store.openIssues.firstWhere(
      (issue) => issue.title.startsWith('エアコン'),
    );
    final previous = store.seriesHistory(active.seriesKey);
    expect(previous, hasLength(2));

    await tester.pumpWidget(
      MaterialApp(home: DetailPage(store: store, issueId: active.id)),
    );
    await tester.pumpAndSettle();

    final first = find.byKey(ValueKey('series-history-${previous.first.id}'));
    final second = find.byKey(ValueKey('series-history-${previous.last.id}'));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(tester.widget<DetailPage>(find.byType(DetailPage)).issueId,
        previous.first.id);
    // A past completion cannot link forward to the current unfinished task.
    expect(find.byKey(ValueKey('series-history-${active.id}')), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<DetailPage>(find.byType(DetailPage)).issueId,
        active.id);

    await tester.tap(second);
    await tester.pumpAndSettle();
    expect(tester.widget<DetailPage>(find.byType(DetailPage)).issueId,
        previous.last.id);
  });

  testWidgets('no previous completion shows only guidance', (tester) async {
    final store = IssueStore(clock: () => DateTime(2026, 10, 9, 12));
    final fresh = store.add(title: '毎日の掃除', recurrence: Recurrence.daily);
    await tester.pumpWidget(
      MaterialApp(home: DetailPage(store: store, issueId: fresh.id)),
    );
    expect(find.text('前回はまだ'), findsOneWidget);
    expect(find.byKey(ValueKey('series-history-${fresh.id}')), findsNothing);
  });

  testWidgets('deleted previous completion is not offered as a history link',
      (tester) async {
    final store = IssueStore.demo(clock: () => DateTime(2026, 10, 6, 9));
    final active = store.openIssues.firstWhere(
      (issue) => issue.title.startsWith('エアコン'),
    );
    final previous = store.seriesHistory(active.seriesKey);
    final deleted = previous.first.id;
    store.remove(deleted);

    await tester.pumpWidget(
      MaterialApp(home: DetailPage(store: store, issueId: active.id)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('series-history-$deleted')), findsNothing);
    expect(
      find.byKey(ValueKey('series-history-${previous.last.id}')),
      findsOneWidget,
    );
  });
}
