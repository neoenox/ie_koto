import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// テストの中で動くサーバー役。**本物は server/（Cloudflare Workers + D1）。**
///
/// 契約（docs/SYNC_DESIGN.md §3）だけを真似る:
///   `GET  /ops?household=<id>&since=<cursor>[&limit=<n>]`
///   `POST /ops  {"household": "<id>", "ops": [...]}`
///
/// 本物との違いは、世帯が1つしか無いことと、保存先がメモリなことだけ。
class OpsServer {
  OpsServer({this.token = 'test-token-test-token-test-token-test-token'});

  final String token;
  final List<Map<String, Object?>> ops = <Map<String, Object?>>[];
  final Map<String, String> legacyAliases = <String, String>{};
  final Map<String, String> members = <String, String>{};

  HttpServer? _server;

  /// POST を受けた回数（分割送信の確認に使う）。
  int posts = 0;

  /// GET を受けた回数。
  int pulls = 0;

  /// わざと失敗させたいとき。
  int? forcedStatus;
  String? forcedBody;

  /// 応答の途中で切る（電波が切れた時と同じ）。
  bool cutResponse = false;

  /// 応答に混ぜるop（壊れたopを混ぜて、捨てられるか見るため）。
  List<Map<String, Object?>> injectedOps = <Map<String, Object?>>[];

  bool authRequired = true;

  int get cursor => ops.length;

  String get baseUrl => 'http://127.0.0.1:${_server!.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _serve() async {
    final server = _server;
    if (server == null) return;
    await for (final request in server) {
      try {
        await _handle(request);
      } catch (_) {
        // 途中で切ったときなど。
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('access-control-allow-origin', '*');
    response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );

    if (forcedStatus != null) {
      response.statusCode = forcedStatus!;
      response.write(forcedBody ?? '{"error":"forced"}');
      await response.close();
      return;
    }

    if (authRequired &&
        request.headers.value('authorization') != 'Bearer $token') {
      response.statusCode = 401;
      response.write('{"error":"unauthorized"}');
      await response.close();
      return;
    }

    if (request.uri.path == '/household/members/migrate' &&
        request.method == 'POST') {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>;
      final candidates = body['legacyMembers'] as List<Object?>? ?? const [];
      for (final legacyId in const ['me', 'partner']) {
        legacyAliases.putIfAbsent(
          legacyId,
          () => legacyId == 'me'
              ? 'mem_11111111111111111111111111111111'
              : 'mem_22222222222222222222222222222222',
        );
        final candidate = candidates.cast<Map<Object?, Object?>>().where(
          (m) => m['id'] == legacyId,
        );
        final name = candidate.isEmpty
            ? (legacyId == 'me' ? '自分' : 'パートナー')
            : candidate.first['name'] as String;
        members.putIfAbsent(legacyAliases[legacyId]!, () => name);
      }
      response.write(jsonEncode(_memberDirectory()));
      await response.close();
      return;
    }

    if (request.uri.path == '/household/members' && request.method == 'GET') {
      response.write(jsonEncode(_memberDirectory()));
      await response.close();
      return;
    }

    if (request.uri.path == '/household/members' && request.method == 'POST') {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>;
      members[body['id']! as String] = body['name']! as String;
      response.write(jsonEncode(body));
      await response.close();
      return;
    }

    if (request.uri.path == '/household/members/merge' &&
        request.method == 'POST') {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>;
      final from = body['from'] as String? ?? '';
      final into = body['into'] as String? ?? '';
      if (from.isEmpty ||
          into.isEmpty ||
          from == into ||
          !members.containsKey(from) ||
          !members.containsKey(into)) {
        response.statusCode = 400;
        response.write('{"error":"bad_member"}');
        await response.close();
        return;
      }
      legacyAliases[from] = into;
      members.remove(from);
      response.write(jsonEncode(_memberDirectory()));
      await response.close();
      return;
    }

    if (request.uri.path == '/household/members/remove' &&
        request.method == 'POST') {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>;
      final id = body['id'] as String? ?? '';
      if (id.isEmpty) {
        response.statusCode = 400;
        response.write('{"error":"bad_member"}');
        await response.close();
        return;
      }
      members.remove(id);
      response.write(jsonEncode(_memberDirectory()));
      await response.close();
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/ops') {
      posts += 1;
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>;
      final incoming = body['ops']! as List<Object?>;
      var accepted = 0;
      var duplicates = 0;
      for (final raw in incoming) {
        final op = (raw! as Map<Object?, Object?>).cast<String, Object?>();
        final id = op['id'] as String;
        if (ops.any((stored) => stored['id'] == id)) {
          duplicates += 1;
          continue;
        }
        ops.add(op);
        accepted += 1;
      }
      response.write(
        jsonEncode(<String, Object?>{
          'cursor': cursor,
          'accepted': accepted,
          'duplicates': duplicates,
        }),
      );
      await response.close();
      return;
    }

    if (request.method == 'GET' && request.uri.path == '/ops') {
      pulls += 1;

      if (cutResponse) {
        final socket = await response.detachSocket();
        socket.write(
          'HTTP/1.1 200 OK\r\ncontent-type: application/json; charset=utf-8\r\ncontent-length: 4080\r\n\r\n{"cursor":0,"ops":[',
        );
        await socket.flush();
        socket.destroy();
        return;
      }

      final since =
          int.tryParse(request.uri.queryParameters['since'] ?? '0') ?? 0;
      final limitRaw = request.uri.queryParameters['limit'];
      final limit = limitRaw == null ? null : int.tryParse(limitRaw);

      final available = <Map<String, Object?>>[...ops, ...injectedOps];
      final start = since < 0
          ? 0
          : (since > available.length ? available.length : since);
      final rest = available.sublist(start);
      final page = limit == null || limit <= 0
          ? rest
          : rest.take(limit).toList();
      final cursor = page.isEmpty
          ? (since > available.length ? available.length : since)
          : since + page.length;

      response.write(
        jsonEncode(<String, Object?>{
          'cursor': cursor,
          'ops': page,
          'skipped': 0,
        }),
      );
      await response.close();
      return;
    }

    response.statusCode = 404;
    response.write('{"error":"not_found"}');
    await response.close();
  }

  Map<String, Object?> _memberDirectory() => <String, Object?>{
    'members': [
      for (final entry in members.entries)
        {'id': entry.key, 'name': entry.value},
    ],
    'aliases': legacyAliases,
  };
}
