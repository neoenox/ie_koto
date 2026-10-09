import 'storage.dart';

/// 同期の設定。ホームの世帯名から開くシートでも決められる。
/// ビルド時に渡したもの（--dart-define）があれば、それが最優先（設計の手順3の残り）。
///
/// ```bash
/// flutter run -d web-server --web-port 8080 \
///   --dart-define=IE_KOTO_API=http://127.0.0.1:8799 \
///   --dart-define=IE_KOTO_HOUSEHOLD=hh_... \
///   --dart-define=IE_KOTO_TOKEN=...
/// ```
///
/// 渡さなければ同期しない（1人で使う形のまま。サーバーにも一切つながらない）。
/// **一度渡すと端末に残る**ので、次の起動からは渡さなくてよい（[SyncCredentials]）。
/// 世帯の作り方は [server/README.md](../../server/README.md)。
class SyncConfig {
  const SyncConfig._();

  static const String _baseUrl = String.fromEnvironment('IE_KOTO_API');
  static const String _household = String.fromEnvironment('IE_KOTO_HOUSEHOLD');
  static const String _token = String.fromEnvironment('IE_KOTO_TOKEN');

  /// ビルドのときに渡されているか。
  static bool get configured =>
      _baseUrl.isNotEmpty && _household.isNotEmpty && _token.length >= 32;

  /// 使う設定を決める。**渡したもの（`--dart-define`）が最優先。**
  /// 渡していなければ、端末に残しておいたものを使う（渡した設定は、最初の同期で残る）。
  ///
  /// 世帯が変わったら cursor は 0 に戻す（前に見ていた世帯の位置を指したままにしない）。
  static SyncCredentials? resolve(
    Storage? storage, {
    String baseUrl = _baseUrl,
    String household = _household,
    String token = _token,
  }) {
    final saved = storage?.load().sync;
    if (baseUrl.isEmpty || household.isEmpty || token.length < 32) return saved;

    final url = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final same =
        saved != null &&
        saved.baseUrl == url &&
        saved.householdId == household &&
        saved.token == token;
    return SyncCredentials(
      baseUrl: url,
      householdId: household,
      token: token,
      cursor: same ? saved.cursor : 0,
    );
  }
}
