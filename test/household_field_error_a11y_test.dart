import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/household_sheet.dart';
import 'package:ie_koto/sync/setup.dart';

void main() {
  Future<void> submit(WidgetTester tester, String label) async {
    final button = find.text(label);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('invalid create URL is attached to the focused field and clears on edit',
      (tester) async {
    Object? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showHouseholdSheet(context, current: null);
              },
              child: const Text('設定'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();

    await submit(tester, 'つくる');
    final url = find.byKey(const ValueKey('household-base-field'));
    expect(tester.widget<TextField>(url).decoration!.errorText, isNotNull);
    expect(tester.widget<TextField>(url).focusNode!.hasFocus, isTrue);
    expect(result, isNull);

    await tester.enterText(url, 'https://api.example.com');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(url).decoration!.errorText, isNull);
    await submit(tester, 'つくる');
    expect(result, isA<HouseholdResult>());
  });

  testWidgets('join focuses the exact invalid field and succeeds after editing',
      (tester) async {
    Object? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showHouseholdSheet(context, current: null);
              },
              child: const Text('設定'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('はいっている家にはいる'));
    await tester.pumpAndSettle();

    final url = find.byKey(const ValueKey('household-base-field'));
    final household = find.byKey(const ValueKey('household-id-field'));
    final token = find.byKey(const ValueKey('household-token-field'));
    await tester.enterText(url, 'https://api.example.com');

    await submit(tester, 'はいる');
    expect(tester.widget<TextField>(household).decoration!.errorText, isNotNull);
    expect(tester.widget<TextField>(household).focusNode!.hasFocus, isTrue);

    await tester.enterText(household, HouseholdSetup.newHouseholdId());
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(household).decoration!.errorText, isNull);

    await submit(tester, 'はいる');
    expect(tester.widget<TextField>(token).decoration!.errorText, isNotNull);
    expect(tester.widget<TextField>(token).focusNode!.hasFocus, isTrue);

    await tester.enterText(token, HouseholdSetup.newToken());
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(token).decoration!.errorText, isNull);
    await submit(tester, 'はいる');
    expect(result, isA<HouseholdResult>());
  });
}
