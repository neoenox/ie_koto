import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/household_sheet.dart';
import 'package:ie_koto/join_link.dart';
import 'package:ie_koto/sync/setup.dart';

const token = 'abcdefghijklmnopqrstuvwxyz0123456789';
const household = 'hh_abcdefghijklmnopqrstuv';
const invite = '場所 https://example.com\n世帯 $household\nトークン $token';

void main() {
  test('招待文とリンクを一度で読み取り、不正な設定を拒否する', () {
    final legacy = HouseholdSetup.parseInvite(invite)!;
    expect(legacy.baseUrl, 'https://example.com');
    expect(legacy.householdId, household);
    expect(legacy.token, token);
    final link = JoinLink(
      baseUrl: 'https://app.example.com',
      apiUrl: 'https://api.example.com',
      householdId: household,
      token: token,
    );
    expect(
      HouseholdSetup.parseInvite(link.text)!.baseUrl,
      'https://api.example.com',
    );
    for (final invalid in [
      '',
      '招待ではありません',
      invite.replaceAll(token, 'short'),
      invite.replaceAll(household, 'short'),
      invite.replaceAll('https:', 'file:'),
      'https://example.com/#join?h=x&t=%',
      'http:broken#join?h=$household&t=$token',
      link.text.replaceAll('https%3A', 'javascript%3A'),
    ]) {
      expect(HouseholdSetup.parseInvite(invalid), isNull, reason: invalid);
    }
  });

  for (final size in [const Size(360, 800), const Size(320, 568)]) {
    testWidgets('招待の貼り付けと確認だけで参加できる $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': invite} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Object? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showHouseholdSheet(context, current: null);
                },
                child: const Text('開く'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('はいっている家にはいる'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.text('招待を貼り付ける'));
      await tester.pumpAndSettle();
      expect(find.text('招待を読み込みました'), findsOneWidget);
      expect(result, isNull);
      await tester.ensureVisible(find.text('この家に入る'));
      await tester.tap(find.text('この家に入る'));
      await tester.pumpAndSettle();
      expect(result, isA<HouseholdResult>());
      expect((result as HouseholdResult).token, token);
      expect(tester.takeException(), isNull);
    });
  }
}
