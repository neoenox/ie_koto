import 'dart:async';

import '../store.dart';
import 'api.dart';
import 'storage.dart';

/// 1回の同期で起きたこと（「最終同期」の表示に使う）。
class SyncOutcome {
  const SyncOutcome({
    required this.sent,
    required this.duplicates,
    required this.received,
    required this.skipped,
  });

  /// 相手がまだ持っていなかったop（新しく預けた数）。
  final int sent;

  /// すでに預かっていたop（二重送信。増えていない）。
  final int duplicates;

  /// もらったop。
  final int received;

  /// 読めなくて捨てたop。
  final int skipped;

  bool get empty => sent == 0 && duplicates == 0 && received == 0;
}

/// ストアとサーバーをつなぐ（docs/SYNC_DESIGN.md の手順3）。
///
/// 送るのは `store.outbox`（自分が書いたop）。もらったら `store.receive` で突き合わせ、
/// 足りない「次の1件」を書いて、それも送る。
///
/// **リアルタイム購読はしない。** 取りに行くのは、起動時・復帰時・自分が書いた直後の3回だけ
/// （自分が書いた直後は [autoPushDelay] でまとめる）。
class SyncSession {
  SyncSession({
    required this.store,
    required this.api,
    this.autoPushDelay = const Duration(seconds: 2),
    this.storage,
    this.cursor = 0,
  });

  final IssueStore store;
  final SyncApi api;

  /// 端末の保存先。渡されなければ保存しない（テスト用の形）。
  final Storage? storage;

  /// 次にもらう位置。端末にも残すので、次の起動は差分だけで済む
  /// （0から取り直しても正しくなる設計）。
  int cursor;

  int _savedCursor = -1;

  /// 書いた直後に自動で送るまでの待ち。1文字ごとに送らないためのまとめ。
  final Duration autoPushDelay;

  DateTime? lastSyncedAt;
  Object? lastError;

  /// 差分を取り切るまでの上限。超えたら失敗にする（サーバーの不具合で回り続けないように）。
  static const int maxPages = 200;

  Future<SyncOutcome>? _inFlight;
  Timer? _timer;
  bool _attached = false;

  /// ストアの変更を拾って、書いた直後に自動で送る。
  void attach() {
    if (_attached) return;
    _attached = true;
    store.onLocalWrite = _schedule;
  }

  void detach() {
    _attached = false;
    store.onLocalWrite = null;
    _timer?.cancel();
    _timer = null;
  }

  /// 送るだけ（もらわない）。書いた直後の自動送信と、明示的な送信に使う。
  Future<PushResult> pushNow() async {
    final batch = store.outbox;
    if (batch.isEmpty) return PushResult.none;

    final result = await api.push(batch);
    // 送れたぶんだけを送信待ちから外す（送っている間に書いたものは残す）。
    store.markSent(batch);
    return result;
  }

  /// 送って、もらって、足りない「次の1件」を書いて、また送る。
  /// すでに走っていれば、その回に乗る（同じ仕事を2回しない）。
  Future<SyncOutcome> syncNow() {
    final running = _inFlight;
    if (running != null) return running;

    final future = _run();
    _inFlight = future;
    // 走り終わったら、次の呼び出しがまた走れるようにする。
    // （この行が作る future は誰も待たないので、失敗はここで受け止めておく。
    //   失敗は lastError に残っていて、次の同期でやり直せる）
    unawaited(future.then((_) {}, onError: (Object _) {}).whenComplete(() => _inFlight = null));
    return future;
  }

  Future<SyncOutcome> _run() async {
    try {
      var sent = 0;
      var duplicates = 0;

      final first = await pushNow();
      sent += first.accepted;
      duplicates += first.duplicates;

      final pulled = await _pullAll();
      store.settle(); // もらった完了から、足りない「次の1件」を書く

      final second = await pushNow(); // 生まれた「次の1件」を、その場で送る
      sent += second.accepted;
      duplicates += second.duplicates;

      // 世帯とトークンも残しておく（cursorが0のままでも、次からは渡さなくてよい）。
      _savedCursor = -1;
      _saveSync();

      lastSyncedAt = DateTime.now();
      lastError = null;
      return SyncOutcome(
        sent: sent,
        duplicates: duplicates,
        received: pulled.received,
        skipped: pulled.skipped,
      );
    } catch (error) {
      lastError = error;
      rethrow;
    }
  }

  /// cursor から先を、空が返るまで取り切る（ページングも応答の分割もここで吸収する）。
  Future<_Pulled> _pullAll() async {
    var received = 0;
    var skipped = 0;

    for (var page = 0; page < maxPages; page++) {
      final result = await api.pull(since: cursor);
      // 記録を取り込んで保存してから、そのページの位置を確定する。
      // 次の通信が失敗しても、cursorまでの記録が端末に残る。
      received += store.countNew(result.ops);
      if (result.ops.isNotEmpty) store.receive(result.ops);
      skipped += result.skipped;
      cursor = result.cursor;
      _saveSync();
      if (result.ops.isEmpty) return _Pulled(received, skipped);
    }
    throw SyncException('bad_response', '差分が終わらない（cursor=$cursor）');
  }

  /// 同期の設定（世帯・トークン・cursor）を端末に残す。
  /// ビルド時に渡した設定もここで残るので、次からは渡さなくてよい。
  void _saveSync() {
    final target = storage;
    if (target == null || _savedCursor == cursor) return;
    _savedCursor = cursor;
    target.saveSync(SyncCredentials(
      baseUrl: api.baseUrl,
      householdId: api.householdId,
      token: api.token,
      cursor: cursor,
    ));
  }

  /// 同期をやめて、接続を閉じる。
  void close() {
    detach();
    api.close();
  }

  void _schedule() {
    if (!_attached) return;
    _timer?.cancel();
    _timer = Timer(autoPushDelay, () => unawaited(_pushSafely()));
  }

  /// 自動送信は投げっぱなしにする。失敗は [lastError] に残して、次の同期でやり直す。
  Future<void> _pushSafely() async {
    try {
      await pushNow();
    } catch (error) {
      lastError = error;
    }
  }
}

class _Pulled {
  const _Pulled(this.received, this.skipped);

  final int received;
  final int skipped;
}
