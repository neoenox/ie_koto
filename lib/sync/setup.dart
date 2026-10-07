import 'dart:math';

import 'storage.dart';

/// 世帯参加UIのための生成・検証ロジック（画面なしで検証できる部分）。
///
/// サーバー側の約束（server/src/index.js）と合わせる:
/// - 世帯id: `[A-Za-z0-9_-]{16,64}`
/// - トークン: 32文字以上（32バイトの乱数を想定）
/// - APIの場所: http/https のURL
class HouseholdSetup {
  const HouseholdSetup._();

  static final RegExp householdPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

  static const String _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  /// 新しい世帯id。`hh_` + 22文字（計25文字でサーバー規則を満たす）。
  static String newHouseholdId([Random? random]) {
    final r = random ?? Random.secure();
    final suffix = String.fromCharCodes(
      List<int>.generate(22, (_) => _alphabet.codeUnitAt(r.nextInt(_alphabet.length))),
    );
    return 'hh_$suffix';
  }

  /// 新しい世帯トークン。32バイトの乱数を16進64文字で表す。
  static String newToken([Random? random]) {
    final r = random ?? Random.secure();
    final bytes = List<int>.generate(32, (_) => r.nextInt(256));
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// APIの場所を整える。http/httpsでなければ null。
  static String? normalizeBaseUrl(String raw) {
    final trimmed = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return trimmed;
  }

  /// 世帯idの検証。問題なければ null。
  static String? validateHouseholdId(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return '世帯idを入れてください';
    if (!householdPattern.hasMatch(v)) return '16〜64文字の英数字・_-で入れてください';
    return null;
  }

  /// トークンの検証。問題なければ null。
  static String? validateToken(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return 'トークンを入れてください';
    if (v.length < 32) return '短すぎます（32文字以上）';
    if (RegExp(r'\s').hasMatch(v)) return '空白は入れられません';
    return null;
  }

  /// 保存済みと見比べてcursorを決める。世帯が変わったら0に戻す。
  static SyncCredentials buildCredentials({
    required String baseUrl,
    required String householdId,
    required String token,
    SyncCredentials? saved,
  }) {
    final same = saved != null &&
        saved.baseUrl == baseUrl &&
        saved.householdId == householdId &&
        saved.token == token;
    return SyncCredentials(
      baseUrl: baseUrl,
      householdId: householdId,
      token: token,
      cursor: same ? saved.cursor : 0,
    );
  }
}
