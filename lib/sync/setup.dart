import 'dart:math';

import '../join_link.dart';
import 'storage.dart';

/// 世帯参加UIのための生成・検証ロジック（画面なしで検証できる部分）。
///
/// サーバー側の約束（server/src/index.js）と合わせる:
/// - 世帯id: `[A-Za-z0-9_-]{16,64}`
/// - トークン: 32文字以上（32バイトの乱数を想定）
/// - APIの場所: http/https のURL
class HouseholdSetup {
  const HouseholdSetup._();

  /// コピーされた招待リンク、または従来の3行の招待文を読む。
  static SyncCredentials? parseInvite(String raw) {
    final text = raw.trim();
    String? base;
    String? household;
    String? token;
    try {
      final uri = Uri.tryParse(text);
      final link = uri == null || !uri.hasAuthority || uri.host.isEmpty
          ? null
          : JoinLink.fromUri(uri);
      if (link != null) {
        base = link.apiBaseUrl;
        household = link.householdId;
        token = link.token;
      } else {
        final values = <String, String>{};
        for (final line in text.split(RegExp(r'\r?\n'))) {
          final match = RegExp(
            r'^(場所|世帯|トークン)\s+(.+)$',
          ).firstMatch(line.trim());
          if (match == null || values.containsKey(match[1])) return null;
          values[match[1]!] = match[2]!;
        }
        base = values['場所'];
        household = values['世帯'];
        token = values['トークン'];
      }
      final normalized = normalizeBaseUrl(base ?? '');
      if (normalized == null ||
          validateHouseholdId(household ?? '') != null ||
          validateToken(token ?? '') != null) {
        return null;
      }
      return SyncCredentials(
        baseUrl: normalized,
        householdId: household!.trim(),
        token: token!.trim(),
      );
    } on FormatException {
      return null;
    }
  }

  static final RegExp householdPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

  static const String _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  /// 新しい世帯id。`hh_` + 22文字（計25文字でサーバー規則を満たす）。
  static String newHouseholdId([Random? random]) {
    final r = random ?? Random.secure();
    final suffix = String.fromCharCodes(
      List<int>.generate(
        22,
        (_) => _alphabet.codeUnitAt(r.nextInt(_alphabet.length)),
      ),
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
    final same =
        saved != null &&
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
