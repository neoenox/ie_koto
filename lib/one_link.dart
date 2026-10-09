/// 「1件リンク」（docs/SYNC_DESIGN.md §2）。
///
/// アプリを入れていない相手に、**ブラウザで1件だけ見せて「やる」を押してもらう**ためのURL。
/// LINEで送ったURLを開けば、中身が見えて、担当を引き受けられる。アプリの存在を知ってもらう導線も兼ねる。
///
/// 形（断片に入れる。**断片はサーバーに送られない**ので、トークンがログに残らない）:
///
/// ```
/// https://<アプリとAPIのドメイン>/#one?i=<案件id>&h=<世帯id>&t=<世帯トークン>&m=<メンバー>
/// ```
///
/// 開発中はアプリとAPIのポートが違うので、`&api=<APIのURL>` を足せる
/// （無ければ、開いたページと同じドメインをAPIとして使う。本番は同じドメインに置く）。
///
/// `&e=<期限の時刻>` を付けると、その時刻を過ぎたリンクは読まない
/// （無ければ無期限。URLを持っている人はいつまでも押せる問題への対応）。
class OneLink {
  const OneLink({
    required this.baseUrl,
    required this.householdId,
    required this.token,
    required this.issueId,
    this.memberId = 'partner',
    this.apiUrl,
    this.expiresAt,
  });

  /// アプリ（Webビルド）とAPIが乗っているドメイン。開いた人が最初に触る場所。
  final String baseUrl;

  final String householdId;
  final String token;
  final String issueId;

  /// 「やる」を押した人を、どのメンバーとして記録するか。
  /// 相手は自分の名前を持っていないので、リンクを送った側が決めておく。
  final String memberId;

  /// アプリとAPIが違う場所にあるとき（開発中）だけ入る。
  /// 本番は同じドメインに置くので、リンクに書く必要がない。
  final String? apiUrl;

  /// 期限。過ぎたリンクは読まない。nullなら無期限（古いリンクとの互換）。
  final DateTime? expiresAt;

  static const String prefix = 'one?';

  /// 送るURL。
  String get text {
    final params = <String, String>{
      'i': issueId,
      'h': householdId,
      't': token,
      'm': memberId,
      'api': ?apiUrl,
      if (expiresAt != null) 'e': '${expiresAt!.millisecondsSinceEpoch}',
    };
    return Uri.parse(baseUrl)
        .replace(fragment: '$prefix${Uri(queryParameters: params).query}')
        .toString();
  }

  /// 開かれたURLから読む。1件リンクでない・欠けている・期限切れなら null。
  static OneLink? fromUri(Uri uri, {DateTime? now}) {
    final fragment = uri.fragment;
    if (!fragment.startsWith(prefix)) return null;

    final params = Uri.splitQueryString(fragment.substring(prefix.length));
    final issueId = params['i'] ?? '';
    final householdId = params['h'] ?? '';
    final token = params['t'] ?? '';
    final memberId = params['m'] ?? 'partner';
    if (issueId.isEmpty || householdId.isEmpty) return null;
    // トークンは32バイトの乱数。短いものは設定ミスとして弾く（サーバーも断る）。
    if (token.length < 32) return null;

    final expiresAt = _expiresOf(params['e']);
    if (params.containsKey('e') && expiresAt == null) return null;
    if (expiresAt != null && !(now ?? DateTime.now()).isBefore(expiresAt)) {
      return null;
    }

    final baseUrl = params['api'] ?? _originOf(uri);
    if (baseUrl.isEmpty) return null;

    return OneLink(
      baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
      householdId: householdId,
      token: token,
      issueId: issueId,
      memberId: memberId,
      expiresAt: expiresAt,
    );
  }

  static DateTime? _expiresOf(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final millis = int.tryParse(raw);
    if (millis == null || millis < 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// 開いたページ自身の場所（http/https のときだけ）。
  static String _originOf(Uri uri) =>
      uri.scheme == 'http' || uri.scheme == 'https' ? uri.origin : '';
}
