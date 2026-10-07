import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/one_link.dart';

/// 「1件リンク」のURL（docs/SYNC_DESIGN.md §2）。
///
/// 相手はアプリを入れていないので、リンク1本に「どの世帯の・どの1件を・誰として引き受けるか」が
/// 全部入っている必要がある。しかも**その中身はサーバーに送られてはいけない**（断片に入れる）。
void main() {
  const token = 'h8Qw3ZrT9xYb2LmN4PvC6SdF7GhJ1KlZ3XcV5BnM7Qa';

  OneLink build({String baseUrl = 'https://ie-koto.example.workers.dev', String? api}) => OneLink(
        baseUrl: baseUrl,
        apiUrl: api,
        householdId: 'hh_e2e0000000000000000000000000000',
        token: token,
        issueId: 'devA:1',
      );

  test('送ったリンクを開くと、同じものが読める（往復）', () {
    final link = build();
    final opened = Uri.parse(link.text);

    final read = OneLink.fromUri(opened);
    expect(read, isNotNull);
    expect(read!.householdId, 'hh_e2e0000000000000000000000000000');
    expect(read.token, token);
    expect(read.issueId, 'devA:1', reason: '「devA:1」の「:」が壊れない');
    expect(read.memberId, 'partner', reason: '相手は自分の名前を持たないので、送った側が決める');
    expect(read.baseUrl, 'https://ie-koto.example.workers.dev');
  });

  test('世帯トークンは断片に入る（サーバーのログに残らない）', () {
    final opened = Uri.parse(build().text);

    expect(opened.fragment, startsWith('one?'));
    expect(opened.fragment, contains(token));
    expect(opened.query, isEmpty, reason: '問い合わせ部分は必ずサーバーに送られる');
    expect(opened.queryParameters, isEmpty);
    // サーバーが受け取るのは、断片を落としたこの部分だけ。
    expect(opened.removeFragment().toString(), 'https://ie-koto.example.workers.dev');
    expect(opened.removeFragment().toString(), isNot(contains(token)));
  });

  test('APIが別の場所にあるとき（開発中）だけ、その場所もリンクに入る', () {
    const page = 'http://127.0.0.1:8791';
    const api = 'http://127.0.0.1:8799';

    final dev = Uri.parse(build(baseUrl: page, api: api).text);
    expect(OneLink.fromUri(dev)!.baseUrl, api);

    // 本番は同じドメインなので、書かなくてよい。開いたページの場所をそのまま使う。
    final live = Uri.parse(build(baseUrl: 'https://ie-koto.example.workers.dev').text);
    expect(OneLink.fromUri(live)!.baseUrl, 'https://ie-koto.example.workers.dev');
    expect(live.fragment, isNot(contains('api=')));
  });

  test('1件リンクでないURLは、ただのアプリのURLとして扱う', () {
    expect(OneLink.fromUri(Uri.parse('http://127.0.0.1:8791/')), isNull);
    expect(OneLink.fromUri(Uri.parse('http://127.0.0.1:8791/#/today')), isNull);
    expect(
      OneLink.fromUri(Uri.parse('file:///C:/ie_koto/index.html#one?i=devA:1&h=hh_e2e0000000000000000000000000000&t=$token')),
      isNull,
      reason: 'http(s)でなければ、開いた場所をAPIとして使えない',
    );
  });

  test('欠けたリンクは、途中まで動くのではなく、読まない', () {
    String link(String params) => 'https://ie-koto.example.workers.dev/#one?$params';

    final ok = 'i=devA:1&h=hh_e2e0000000000000000000000000000&t=$token&m=partner';

    expect(OneLink.fromUri(Uri.parse(link('h=hh_e2e0000000000000000000000000000&t=$token'))), isNull,
        reason: 'どの1件か分からない');
    expect(OneLink.fromUri(Uri.parse(link('i=devA:1&t=$token'))), isNull, reason: 'どの世帯か分からない');
    expect(
      OneLink.fromUri(Uri.parse(link('i=devA:1&h=hh_e2e0000000000000000000000000000&t=h8Qw3ZrT9xYb2LmN4PvC6S'))),
      isNull,
      reason: '切れたトークンでは、サーバーが断るだけ（開いても何も出ない）',
    );

    final read = OneLink.fromUri(Uri.parse(link(ok)));
    expect(read, isNotNull);
    expect(read!.token, token);
  });
}
