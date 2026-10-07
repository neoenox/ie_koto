import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../model.dart';
import 'log.dart';
import 'wire.dart';

/// 同期APIの失敗。UIは [code] だけ見ればよい。
class SyncException implements Exception {
  SyncException(this.code, [this.detail]);

  /// offline（電波が無い・サーバーが落ちている）／ unauthorized（トークンが違う）／
  /// bad_request／ server／ bad_response
  final String code;
  final String? detail;

  @override
  String toString() =>
      'SyncException($code${detail == null ? '' : ': $detail'})';
}

/// 1回ぶんの受信。
class PullPage {
  const PullPage({
    required this.cursor,
    required this.ops,
    required this.skipped,
  });

  /// 次にもらう位置（サーバー採番の挿入順）。
  final int cursor;
  final List<Op> ops;

  /// 読めなくて捨てた数。
  final int skipped;
}

/// 1回ぶんの送信。
class PushResult {
  const PushResult({required this.accepted, required this.duplicates});

  /// サーバーが新しく預かった数。
  final int accepted;

  /// すでに預かっていた数（二重送信。op_id が主キーなので増えない）。
  final int duplicates;

  int get total => accepted + duplicates;

  static const PushResult none = PushResult(accepted: 0, duplicates: 0);
}

/// 同期サーバーとのやり取り（docs/SYNC_DESIGN.md §3）。
///
///   `GET  /ops?household=<id>&since=<cursor>[&limit=<n>]`  … 増分をもらう
///   `POST /ops  {"household": "<id>", "ops": [...]}`       … 自分のopを送る
///
/// どちらも `Authorization: Bearer <世帯トークン>` が要る。
/// 判定はサーバーに任せ、ここは「送る・もらう・失敗を種類分けする」だけ。
class SyncApi {
  SyncApi({
    required String baseUrl,
    required this.householdId,
    required this.token,
    http.Client? client,
    this.pageLimit,
    this.issueId,
  }) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
       _client = client ?? http.Client();

  /// 例: `https://ie-koto.example.workers.dev`。
  final String baseUrl;

  /// 世帯id（招待リンクに埋め込む乱数）。
  final String householdId;

  /// 世帯トークン（32バイトの乱数）。
  final String token;

  /// 1回にもらう上限。サーバーの既定より小さくしたいときだけ指定する。
  final int? pageLimit;

  /// この1件のopだけをもらう（1件リンクのページ用）。
  /// 世帯の全部を相手のブラウザに置かないために使う。
  final String? issueId;

  final http.Client _client;

  /// サーバーが1回のPOSTで受け取る上限（server/src/ops.js と合わせる）。
  static const int maxOpsPerPost = 200;

  static const Duration timeout = Duration(seconds: 20);

  Future<PullPage> pull({required int since}) async {
    final uri = _uri(<String, String>{
      'household': householdId,
      'since': '$since',
      if (pageLimit != null) 'limit': '$pageLimit',
      'issue': ?issueId,
    });
    final body = _jsonObject(
      await _send(() => _client.get(uri, headers: _headers)),
    );

    final decoded = decodeOps(body['ops']);
    final cursor = body['cursor'];
    return PullPage(
      cursor: cursor is num ? cursor.toInt() : since,
      ops: decoded.ops,
      skipped: decoded.skipped,
    );
  }

  Future<MemberDirectory> migrateAndGetMembers(
    Map<String, String> legacyNames,
  ) async {
    final response = await _send(
      () => _client.post(
        Uri.parse('$baseUrl/household/members/migrate'),
        headers: _headers,
        body: jsonEncode(<String, Object?>{
          'household': householdId,
          'legacyMembers': [
            for (final id in const ['me', 'partner'])
              {
                'id': id,
                'name': legacyNames[id] ?? (id == 'me' ? '自分' : 'パートナー'),
              },
          ],
        }),
      ),
    );
    return _decodeMemberDirectory(response);
  }

  Future<MemberDirectory> getMembers() async {
    final response = await _send(
      () => _client.get(_householdUri('/household/members'), headers: _headers),
    );
    return _decodeMemberDirectory(response);
  }

  Future<void> saveMember(Member member) async {
    await _send(
      () => _client.post(
        Uri.parse('$baseUrl/household/members'),
        headers: _headers,
        body: jsonEncode(<String, Object?>{
          'household': householdId,
          'id': member.id,
          'name': member.name,
        }),
      ),
    );
  }

  MemberDirectory _decodeMemberDirectory(http.Response response) {
    final body = _jsonObject(response);
    final rawMembers = body['members'];
    final rawAliases = body['aliases'];
    if (rawMembers is! List || rawAliases is! Map) {
      throw SyncException('bad_response');
    }
    final members = <Member>[];
    for (final raw in rawMembers) {
      if (raw is! Map || raw['id'] is! String || raw['name'] is! String) {
        throw SyncException('bad_response');
      }
      members.add(Member(raw['id'] as String, raw['name'] as String));
    }
    final aliases = <String, String>{};
    for (final entry in rawAliases.entries) {
      if (entry.key is String && entry.value is String) {
        aliases[entry.key as String] = entry.value as String;
      }
    }
    return MemberDirectory(members: members, aliases: aliases);
  }

  Uri _householdUri(String path) => Uri.parse(
    '$baseUrl$path',
  ).replace(queryParameters: {'household': householdId});

  /// 送る。上限を超えるぶんは分けて送る。
  ///
  /// 途中で失敗したら、その便までのぶんも含めて**何も送れなかったことにする**
  /// （送信待ちは消さない）。op_id が主キーなので、二重に送っても増えない。
  Future<PushResult> push(List<Op> ops) async {
    if (ops.isEmpty) return PushResult.none;

    var accepted = 0;
    var duplicates = 0;
    for (var start = 0; start < ops.length; start += maxOpsPerPost) {
      final batch = ops.sublist(
        start,
        math.min(start + maxOpsPerPost, ops.length),
      );
      final body = _jsonObject(
        await _send(
          () => _client.post(
            _uri(const <String, String>{}),
            headers: _headers,
            body: jsonEncode(<String, Object?>{
              'household': householdId,
              'ops': encodeOps(batch),
            }),
          ),
        ),
      );
      accepted += _intOf(body['accepted']);
      duplicates += _intOf(body['duplicates']);
    }
    return PushResult(accepted: accepted, duplicates: duplicates);
  }

  /// 世帯を消す（opと世帯の行。端末の記録は残る）。
  Future<void> deleteHousehold() async {
    final uri = _uri(<String, String>{'household': householdId});
    await _send(() => _client.delete(uri, headers: _headers));
  }

  /// トークンを作り直す。古いトークンで認証し、新しいトークンに置き換える。
  Future<void> rotateToken(String newToken) async {
    final uri = Uri.parse('$baseUrl/household/rotate');
    await _send(
      () => _client.post(
        uri,
        headers: _headers,
        body: jsonEncode(<String, Object?>{
          'household': householdId,
          'token': newToken,
        }),
      ),
    );
  }

  /// Issue an expiring key that is restricted by the server to one issue.
  Future<String> createShareToken({
    required String issueId,
    required String memberId,
    required DateTime expiresAt,
  }) async {
    final response = await _send(
      () => _client.post(
        Uri.parse('$baseUrl/household/share'),
        headers: _headers,
        body: jsonEncode(<String, Object?>{
          'household': householdId,
          'issue': issueId,
          'member': memberId,
          'expiresAt': expiresAt.toUtc().toIso8601String(),
        }),
      ),
    );
    final body = _jsonObject(response);
    final token = body['token'];
    if (token is! String || token.length < 32) {
      throw SyncException('bad_response');
    }
    return token;
  }

  void close() => _client.close();

  Map<String, String> get _headers => <String, String>{
    'authorization': 'Bearer $token',
    'content-type': 'application/json; charset=utf-8',
  };

  Uri _uri(Map<String, String> query) => Uri.parse(
    '$baseUrl/ops',
  ).replace(queryParameters: query.isEmpty ? null : query);

  Future<http.Response> _send(Future<http.Response> Function() send) async {
    final http.Response response;
    try {
      response = await send().timeout(timeout);
    } on TimeoutException catch (error) {
      throw SyncException('offline', 'timeout: $error');
    } on http.ClientException catch (error) {
      throw SyncException('offline', '$error');
    } catch (error) {
      // io でも web でも、届かないときは同じ扱いにする（dart:io は web で import できない）。
      throw SyncException('offline', '$error');
    }

    if (response.statusCode == 401) throw SyncException('unauthorized');
    if (response.statusCode >= 500) {
      throw SyncException('server', '${response.statusCode}');
    }
    if (response.statusCode >= 400) {
      throw SyncException(
        'bad_request',
        '${response.statusCode} ${_text(response)}',
      );
    }
    if (response.statusCode != 200) {
      throw SyncException('bad_response', '${response.statusCode}');
    }
    return response;
  }

  /// 応答は必ず UTF-8 として読む（charset の書き忘れで日本語が壊れないように）。
  Map<String, Object?> _jsonObject(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        return <String, Object?>{
          for (final entry in decoded.entries) '${entry.key}': entry.value,
        };
      }
    } catch (_) {
      // 下で bad_response にする。
    }
    throw SyncException(
      'bad_response',
      '${response.statusCode} ${_text(response)}',
    );
  }

  String _text(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes);
    } catch (_) {
      return '';
    }
  }

  int _intOf(Object? value) => value is num ? value.toInt() : 0;
}
