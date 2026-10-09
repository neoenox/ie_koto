import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/join_link.dart';
import 'package:ie_koto/main.dart';

const _token = 'abcdefghijklmnopqrstuvwxyz0123456789AB';

void main() {
  test('参加リンクは往復できる', () {
    const link = JoinLink(
      baseUrl: 'https://example.workers.dev',
      householdId: 'hh_abcdefghijklmnopqrstuv',
      token: _token,
    );
    final text = link.text;
    final opened = Uri.parse(text);
    expect(opened.fragment, startsWith('join?'));

    final parsed = JoinLink.fromUri(Uri.parse(text));
    expect(parsed, isNotNull);
    expect(parsed!.baseUrl, 'https://example.workers.dev');
    expect(parsed.householdId, 'hh_abcdefghijklmnopqrstuv');
    expect(parsed.token, _token);
    expect(parsed.apiBaseUrl, 'https://example.workers.dev');
  });

  test('開発中のAPI場所も運べる', () {
    const link = JoinLink(
      baseUrl: 'http://127.0.0.1:8094',
      apiUrl: 'http://127.0.0.1:8799',
      householdId: 'hh_abcdefghijklmnopqrstuv',
      token: _token,
    );
    final parsed = JoinLink.fromUri(Uri.parse(link.text));
    expect(parsed, isNotNull);
    expect(parsed!.apiBaseUrl, 'http://127.0.0.1:8799');
  });

  test('欠け・短いトークン・別形式は読まない', () {
    expect(
      JoinLink.fromUri(
        Uri.parse('https://example.workers.dev/#join?h=&t=$_token'),
      ),
      isNull,
    );
    expect(
      JoinLink.fromUri(
        Uri.parse('https://example.workers.dev/#join?h=hh_x&t=short'),
      ),
      isNull,
    );
    expect(
      JoinLink.fromUri(
        Uri.parse('https://example.workers.dev/#one?i=x&h=y&t=$_token'),
      ),
      isNull,
      reason: '1件リンクは参加リンクとして読まない',
    );
    expect(JoinLink.fromUri(Uri.parse('https://example.workers.dev/')), isNull);
  });

  testWidgets('参加リンクで開くと3値入りのシートが出る', (tester) async {
    const join = JoinLink(
      baseUrl: 'https://example.workers.dev',
      householdId: 'hh_abcdefghijklmnopqrstuv',
      token: _token,
    );
    await tester.pumpWidget(const IeKotoApp(joinLink: join));
    await tester.pumpAndSettle();

    // 「はいる」側が開き、3値が入っている。
    expect(find.text('はいっている家にはいる'), findsOneWidget);
    final fields = find.byType(TextField);
    expect(
      tester.widget<TextField>(fields.at(1)).controller!.text,
      'hh_abcdefghijklmnopqrstuv',
    );
    expect(tester.widget<TextField>(fields.at(2)).controller!.text, _token);
  });
}
