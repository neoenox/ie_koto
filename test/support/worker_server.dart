import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// テストの中で**本物の Worker**（server/src/index.js）を動かす。
///
/// server/test/serve.mjs が、Worker の fetch をそのまま Node の HTTP サーバーに載せる
/// （D1 だけを node:sqlite で真似る）。だから Dart のクライアント → HTTP → Worker → SQLite まで、
/// 本番と同じ道を通る。違いは Cloudflare の上で動いていないことだけ。
///
/// node が無い環境では [start] が null を返す（呼んだ側が飛ばす）。
class WorkerServer {
  WorkerServer._(this._process, this.baseUrl);

  final Process _process;

  /// 例: `http://127.0.0.1:53123`。
  final String baseUrl;

  static Future<WorkerServer?> start({String database = ':memory:'}) async {
    if (!await _nodeAvailable()) return null;

    final process = await Process.start(
      'node',
      <String>['--experimental-sqlite', 'test/serve.mjs', '--port', '0', '--db', database],
      workingDirectory: 'server',
    );

    final ready = Completer<int>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final match = RegExp(r'^PORT=(\d+)$').firstMatch(line.trim());
      if (match != null && !ready.isCompleted) ready.complete(int.parse(match.group(1)!));
    });
    // 読み捨てないと、パイプが詰まって止まることがある。
    process.stderr.listen((_) {});

    final int port;
    try {
      port = await ready.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      process.kill();
      throw StateError('ローカルのWorkerが起動しなかった');
    }

    return WorkerServer._(process, 'http://127.0.0.1:$port');
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode;
  }

  static Future<bool> _nodeAvailable() async {
    try {
      final result = await Process.run('node', <String>['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
