/// 「参加リンク」（1件リンクと同型）。
///
/// 家族を世帯に招くためのURL。開くと参加欄に3値が自動で入る。
/// アプリを入れていない相手でも、ブラウザで開けば参加欄まで進める。
///
/// 形（断片に入れる。**断片はサーバーに送られない**ので、トークンがログに残らない）:
///
/// ```
/// https://<アプリとAPIのドメイン>/#join?h=<世帯id>&t=<世帯トークン>
/// ```
///
/// 開発中はアプリとAPIのポートが違うので、`&api=<APIのURL>` を足せる
/// （無ければ、開いたページと同じドメインをAPIとして使う。本番は同じドメインに置く）。
class JoinLink {
  const JoinLink({
    required this.baseUrl,
    required this.householdId,
    required this.token,
    this.apiUrl,
  });

  /// アプリ（Webビルド）が乗っているドメイン。開いた人が最初に触る場所。
  final String baseUrl;

  final String householdId;
  final String token;

  /// アプリとAPIが違う場所にあるとき（開発中）だけ入る。
  /// 本番は同じドメインに置くので、リンクに書く必要がない。
  final String? apiUrl;

  /// 参加に使うAPIの場所。
  String get apiBaseUrl => apiUrl ?? baseUrl;

  static const String prefix = 'join?';

  /// 送るURL・QRに入れるURL。
  String get text {
    final params = <String, String>{
      'h': householdId,
      't': token,
      'api': ?apiUrl,
    };
    return Uri.parse(baseUrl)
        .replace(fragment: '$prefix${Uri(queryParameters: params).query}')
        .toString();
  }

  /// 開かれたURLから読む。参加リンクでない・欠けている・短いトークンなら null。
  static JoinLink? fromUri(Uri uri) {
    final fragment = uri.fragment;
    if (!fragment.startsWith(prefix)) return null;

    final params = Uri.splitQueryString(fragment.substring(prefix.length));
    final householdId = params['h'] ?? '';
    final token = params['t'] ?? '';
    if (householdId.isEmpty) return null;
    // トークンは32バイトの乱数。短いものは設定ミスとして弾く（サーバーも断る）。
    if (token.length < 32) return null;

    // アプリの場所は開いたページ自身。APIは書いてあればそれを使う。
    final baseUrl = _originOf(uri);
    if (baseUrl.isEmpty) return null;

    return JoinLink(
      baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
      householdId: householdId,
      token: token,
      apiUrl: params['api'],
    );
  }

  /// 開いたページ自身の場所（http/https のときだけ）。
  static String _originOf(Uri uri) =>
      uri.scheme == 'http' || uri.scheme == 'https' ? uri.origin : '';
}
