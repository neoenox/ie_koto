import 'dart:math';

import '../model.dart';

/// 同期の設計を、サーバーなしで確かめるための参照実装。
/// アプリ本体（IssueStore）はまだこの上に載っていない。載せ替えの手順は docs/SYNC_DESIGN.md。
///
/// 方針:
/// - 端末はオフラインで書きたい放題書く（追記のみ・消さない）
/// - あとで突き合わせる（merge）と、どの端末でも同じ結果になる（project）
/// - 「次の1件」の id を、元になった完了opから決定的に導く（`next:<opId>`）
///   → 2台が別々に完了しても、同じ id になるので1件に畳まれる

enum OpKind { add, rename, assignee, due, recurrence, status, comment, complete, reopen, delete }

class Op {
  Op({
    required this.deviceId,
    required this.lamport,
    required this.kind,
    required this.issueId,
    required this.at,
    Map<String, Object?>? data,
    this.derivedFrom,
    this.memberId,
  })  : id = '$deviceId:$lamport',
        data = data == null ? const <String, Object?>{} : Map.unmodifiable(data);

  /// 端末ごとに一意。端末idと論理時計の組で決まる。
  final String id;
  final String deviceId;

  /// 論理時計（Lamport）。端末の時計がずれても順序が壊れないようにする。
  final int lamport;

  final OpKind kind;
  final String issueId;

  /// 端末の時刻。表示にだけ使う。
  final DateTime at;

  final Map<String, Object?> data;

  /// 自動生成された「次の1件」なら、元になった完了opのid。
  final String? derivedFrom;

  /// 書いた人（member_id）。古いopには入っていない（nullのまま）。
  final String? memberId;

  @override
  String toString() => '$id ${kind.name}($issueId)';
}

/// 1台の端末。オフラインで書き、あとで送る。
class Device {
  static String newId() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
  Device(this.id);

  final String id;

  int _lamport = 0;
  DateTime _clock = DateTime.fromMillisecondsSinceEpoch(0);

  /// サーバーが確認した、自分のopの最大の論理時計（端末に残す）。
  /// これより後の自分のopが「まだ送っていないもの」になる。
  int _pushedThrough = 0;

  /// 送信待ち。同期できたら消す。
  final List<Op> outbox = <Op>[];

  /// 受け取ったop（自分のぶんも含む）。
  final List<Op> log = <Op>[];

  /// すでに持っているopのid。同じopを何度もらっても増やさないための索引
  /// （毎回 log をなめると、保存から戻すときに2乗の時間がかかる）。
  final Set<String> _known = <String>{};

  int get lamport => _lamport;
  int get pushedThrough => _pushedThrough;

  /// 次に書くopのid。案件idは、それを生んだopのidから取る（端末をまたいでも衝突しない）。
  /// 書き込みの直前に呼んで、そのopをそのまま書くこと。
  String nextOpId() => '$id:${_lamport + 1}';

  Op write(
    OpKind kind,
    String issueId, {
    Map<String, Object?>? data,
    String? derivedFrom,
    DateTime? at,
    String? memberId,
  }) {
    _lamport += 1;
    final now = at ?? _clock.add(const Duration(minutes: 1));
    _clock = now;
    final op = Op(
      deviceId: id,
      lamport: _lamport,
      kind: kind,
      issueId: issueId,
      at: now,
      data: data,
      derivedFrom: derivedFrom,
      memberId: memberId,
    );
    log.add(op);
    _known.add(op.id);
    outbox.add(op);
    return op;
  }

  /// 相手のopを受け取る。論理時計を進める。同じopは1つに畳む。
  void receive(Iterable<Op> incoming) {
    for (final op in incoming) {
      if (!_known.add(op.id)) continue;
      log.add(op);
      if (op.lamport > _lamport) _lamport = op.lamport;
    }
  }

  /// 端末に残しておいたものから戻す（設計の手順1）。
  ///
  /// 送信待ちは「自分が書いたopのうち、サーバーが確認していないもの」だけ。
  /// 相手のopは送り返さないし、確認済みの自分のopも送り直さない。
  void restore(Iterable<Op> saved, {int pushedThrough = 0}) {
    receive(saved);
    _pushedThrough = pushedThrough < 0 ? 0 : pushedThrough;
    outbox
      ..clear()
      ..addAll(log.where((op) => op.deviceId == id && op.lamport > _pushedThrough));
  }

  /// 相手に送るぶんを取り出す。
  List<Op> takeOutbox() {
    final ops = List<Op>.unmodifiable(outbox);
    outbox.clear();
    return ops;
  }

  /// 送るぶんを見る（消さない）。送れたら [markSent] で外す。
  /// 送る途中で失敗しても送信待ちが消えないので、次の同期でやり直せる。
  List<Op> peekOutbox() => List<Op>.unmodifiable(outbox);

  /// 送れたopだけを送信待ちから外す。
  /// op_id が主キーなので、二重に送っても増えない（server/src/ops.js）。
  void markSent(Iterable<Op> ops) {
    final sent = ops.map((op) => op.id).toSet();
    outbox.removeWhere((op) => sent.contains(op.id));
    // 自分のopがどこまで届いたかを覚えておく（端末に残すのは呼ぶ側）。
    for (final op in ops) {
      if (op.deviceId == id && op.lamport > _pushedThrough) _pushedThrough = op.lamport;
    }
  }
}

/// 突き合わせた結果の1件。
class Task {
  Task(this.id);

  final String id;
  String title = '';
  String? assigneeId;
  DateTime? dueDate;
  Recurrence recurrence = Recurrence.none;
  IssueStatus status = IssueStatus.open;
  bool deleted = false;
  String? seriesId;

  /// 自動生成された1件なら、元になった完了opのid。
  String? derivedFrom;

  /// 「次の1件」なのに、元の完了が取り消されている場合。画面には出さない。
  bool orphaned = false;

  /// 同じ系列の中で、もっと新しい1件に追い越されている場合。画面には出さない。
  /// 端末が増分同期でopを取りこぼすと系列のつながりが切れて、元の案件と次の1件が
  /// 同時に見えてしまう。データが欠けているだけなので、見える範囲で新しい方を残す。
  bool superseded = false;

  /// この案件を作ったopが、並びの中で何番目か。親から先に判定するために使う。
  int addOrder = -1;

  /// 自動生成された1件の、元になった案件のid。
  String? originIssueId;

  /// いま有効な完了op。取り消されていれば null。
  String? standingCompletionOpId;

  /// この完了から生まれた「次の1件」のid。
  String? get generatedNextId =>
      standingCompletionOpId == null ? null : nextIssueId(standingCompletionOpId!);

  /// いま有効な完了の時刻（端末の時計。表示と次回の計算にだけ使う）。
  DateTime? get completedAt {
    final standing = standingCompletionOpId;
    if (standing == null) return null;
    for (final op in history) {
      if (op.id == standing) return op.at;
    }
    return null;
  }

  final List<String> comments = <String>[];
  final List<Op> history = <Op>[];

  bool get isOpen => !deleted && !orphaned && !superseded && status != IssueStatus.done;
  bool get isDerived => derivedFrom != null;
  bool get isVisible => !deleted && !orphaned && !superseded;
}

/// 「次の1件」のid。ここが決定的であることが、2台で重複しない理由。
String nextIssueId(String completionOpId) => 'next:$completionOpId';

/// opの並び順。論理時計 → 端末id → op id。どの端末でも同じ並びになる。
int compareOps(Op a, Op b) {
  final byLamport = a.lamport.compareTo(b.lamport);
  if (byLamport != 0) return byLamport;
  final byDevice = a.deviceId.compareTo(b.deviceId);
  if (byDevice != 0) return byDevice;
  return a.id.compareTo(b.id);
}

/// 2つのlogを突き合わせる。同じopは1つに畳む。
List<Op> mergeOps(Iterable<Op> a, Iterable<Op> b) {
  final byId = <String, Op>{};
  for (final op in a) {
    byId[op.id] = op;
  }
  for (final op in b) {
    byId[op.id] = op;
  }
  return byId.values.toList()..sort(compareOps);
}

/// opの並びから、いまの状態を組み立てる。同じop集合なら、どの端末でも同じ結果になる。
Map<String, Task> project(Iterable<Op> ops) {
  final ordered = ops.toList()..sort(compareOps);
  final tasks = <String, Task>{};

  for (var index = 0; index < ordered.length; index++) {
    final op = ordered[index];
    final task = tasks.putIfAbsent(op.issueId, () => Task(op.issueId));
    task.history.add(op);

    switch (op.kind) {
      case OpKind.add:
        if (task.title.isEmpty) {
          task.addOrder = index;
          task.title = (op.data['title'] as String?) ?? '';
          task.recurrence = (op.data['recurrence'] as Recurrence?) ?? Recurrence.none;
          task.dueDate = op.data['dueDate'] as DateTime?;
          task.assigneeId = op.data['assigneeId'] as String?;
          task.seriesId = (op.data['seriesId'] as String?) ?? op.issueId;
          task.derivedFrom = op.derivedFrom;
          task.originIssueId = op.data['originIssueId'] as String?;
        }
      case OpKind.rename:
        task.title = (op.data['title'] as String?) ?? task.title;
      case OpKind.assignee:
        task.assigneeId = op.data['assigneeId'] as String?;
      case OpKind.due:
        task.dueDate = op.data['dueDate'] as DateTime?;
      case OpKind.recurrence:
        task.recurrence = (op.data['recurrence'] as Recurrence?) ?? Recurrence.none;
      case OpKind.comment:
        final text = op.data['text'] as String?;
        if (text != null && text.isNotEmpty) task.comments.add(text);
      case OpKind.status:
        final status = op.data['status'] as IssueStatus?;
        if (status != null && status != IssueStatus.done) {
          task.status = status;
          // 完了でなくなったなら、完了は取り消されたのと同じ。
          // これをやらないと、元に戻した案件と自動生成された次の1件が同時に見えてしまう。
          task.standingCompletionOpId = null;
        }
      case OpKind.complete:
        // 2台が別々に完了しても、有効な完了は最初の1つだけ。
        if (task.standingCompletionOpId == null) {
          task.standingCompletionOpId = op.id;
          task.status = IssueStatus.done;
        }
      case OpKind.reopen:
        task.standingCompletionOpId = null;
        task.status = IssueStatus.open;
      case OpKind.delete:
        task.deleted = true;
    }
  }

  // 元の完了が取り消されている「次の1件」は、最初から無かったものとして見えなくする。
  // 消すopは書かない（書くと、あとから古い完了opが届いて再び必要になったときに戻せない）。
  // 作られた順に見ることで、連鎖（元を失った1件から更に生まれた1件）にも伝わる。
  // 元の案件が消されていても、完了が有効なら次の1件は残す（過去の記録を消しても連なりは続く）。
  final derived = tasks.values.where((t) => t.isDerived).toList()
    ..sort((a, b) => a.addOrder.compareTo(b.addOrder));
  for (final task in derived) {
    final origin = tasks[task.originIssueId];
    final alive = origin != null && !origin.orphaned && origin.standingCompletionOpId == task.derivedFrom;
    task.orphaned = !alive;
  }

  // 同じ系列（同じ定期案件）では、見えている中でいちばん新しい1件だけを「いまの1件」とする。
  // 全件そろっていれば、古い1件はすでに完了しているので何も起きない。
  // 増分同期でopが欠けたときだけ、追い越された古い1件が未完了のまま残るので、それを隠す。
  // addOrder は因果順に増える（親の完了opより、次の1件のaddの方が必ず後になる）ので、
  // いちばん大きい addOrder が系列の先頭になる。
  final bySeries = <String, List<Task>>{};
  for (final task in tasks.values.where((t) => t.isVisible)) {
    bySeries.putIfAbsent(task.seriesId ?? task.id, () => <Task>[]).add(task);
  }
  for (final group in bySeries.values) {
    if (group.length < 2) continue;
    var head = group.first;
    for (final task in group) {
      if (task.addOrder > head.addOrder) head = task;
    }
    for (final task in group) {
      if (identical(task, head) || task.status == IssueStatus.done) continue;
      task.superseded = true;
    }
  }

  return tasks;
}

/// 突き合わせた結果から、まだ足りていないopを導いて書く。書くものが無ければ何もしない。
///
/// 有効な完了があるのに「次の1件」がまだ存在しないときだけ作る。
/// すでにあるものは、見えていても・消されていても、触らない
/// （利用者が「これは要らない」と消したものを勝手に作り直さないため）。
/// 見えなくなった派生案件も消さない（射影が隠すので、書くと戻せなくなる）。
/// 追い越された1件（`superseded`）も、系列の先頭ではないので何も書かない。
/// どちらの端末が書いても、指す先の案件idは同じ（`next:<opId>`）なので重複しない。
List<Op> writeMissingFollowUps(
  Map<String, Task> tasks,
  Device device, {
  DateTime? at,
}) {
  final writes = <Op>[];

  for (final task in tasks.values) {
    // 元が消されていても、完了が有効なら連なりは続ける（射影と同じ規則）。
    if (task.orphaned || task.superseded) continue;
    final completion = task.standingCompletionOpId;
    if (completion == null || task.recurrence.isNone) continue;

    final nextId = nextIssueId(completion);
    if (tasks[nextId] != null) continue;

    final completedAt = task.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final due = task.recurrence.nextDue(completedAt: completedAt, previousDue: task.dueDate);
    writes.add(device.write(
      OpKind.add,
      nextId,
      data: <String, Object?>{
        'title': task.title,
        'dueDate': due,
        'assigneeId': task.assigneeId,
        'recurrence': task.recurrence,
        'seriesId': task.seriesId ?? task.id,
        'originIssueId': task.id,
      },
      derivedFrom: completion,
      at: at,
    ));
  }

  return writes;
}
