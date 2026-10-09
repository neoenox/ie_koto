import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'model.dart';
import 'sync/log.dart';
import 'sync/storage.dart';
import 'sync/wire.dart';

/// 画面が見る形（Issue）を、op log の射影から組み立てる。
///
/// 変更はすべて op として追記し、射影し直してから画面に渡す。
/// こうすると、定期の次の1件も取り消しも、決定的なid（`next:<完了opId>`）で決まる。
/// 書いたopは端末に残す（[Storage]）ので、閉じても消えない。
class IssueStore extends ChangeNotifier {
  /// 保存があれば、そこから戻す（opの列・端末id・送信済みの位置）。無ければ空で始める。
  factory IssueStore({
    DateTime Function()? clock,
    String householdName = 'わが家',
    String? deviceId,
    Storage? storage,
    List<Member>? members,
    String? initialMeId,
    Map<String, String> legacyMemberAliases = const {},
    bool startAlone = false,
  }) {
    final saved = storage?.load();
    final savedNames = saved?.memberNames ?? const <String, String>{};
    final pendingNames = saved?.pendingMemberNames ?? const <String, String>{};
    // memberNames自体を名簿として復元する。初期2人への上書きだけでは
    // 共有IDと追加メンバーがオフライン起動で消えてしまう。
    final base =
        members ??
        (savedNames.isNotEmpty
            ? [
                for (final entry in savedNames.entries)
                  Member(entry.key, entry.value),
              ]
            : startAlone
            ? const [Member('me', '自分')]
            : const [Member('me', '自分'), Member('partner', 'パートナー')]);
    final named = <String, Member>{
      for (final m in base)
        m.id: Member(m.id, pendingNames[m.id] ?? savedNames[m.id] ?? m.name),
      for (final entry in pendingNames.entries)
        entry.key: Member(entry.key, entry.value),
    }.values.toList();
    final store = IssueStore._(
      clock: clock,
      householdName: householdName,
      // 一度決めた端末idは、次からもそれを使う（opのidが変わらないように）。
      deviceId: saved == null || saved.deviceId.isEmpty
          ? deviceId ?? Device.newId()
          : saved.deviceId == 'dev' && deviceId == null
          ? Device.newId()
          : saved.deviceId,
      storage: storage,
      members: named,
      legacyMemberAliases: {...?saved?.memberAliases, ...legacyMemberAliases},
      pendingMemberNames: Map<String, String>.of(
        saved?.pendingMemberNames ?? const {},
      ),
      pendingMemberAliases: Map<String, String>.of(
        saved?.pendingMemberAliases ?? const {},
      ),
      pendingMemberRemovals: Set<String>.of(
        saved?.pendingMemberRemovals ?? const <String>{},
      ),
    );
    if (initialMeId != null && initialMeId.isNotEmpty) {
      store.meId = store.canonicalMemberId(initialMeId);
      store.meExplicit = true;
    } else if (saved != null && saved.meId.isNotEmpty) {
      store.meId = store.canonicalMemberId(saved.meId);
      store.meExplicit = true;
    }
    store._restore(saved ?? const SavedState());
    return store;
  }

  IssueStore._({
    DateTime Function()? clock,
    required this.householdName,
    required this.deviceId,
    required this.storage,
    required this.members,
    required Map<String, String> legacyMemberAliases,
    required this.pendingMemberNames,
    required this.pendingMemberAliases,
    required this.pendingMemberRemovals,
  }) : legacyMemberAliases = Map<String, String>.of(legacyMemberAliases),
       _device = Device(deviceId),
       _clock = clock ?? DateTime.now {
    // 初回起動で決まった端末idを、その場で残す。
    storage?.saveDeviceId(deviceId);
  }

  /// 端末の見分け。案件idとopのidが、端末をまたいでも衝突しないようにする。
  /// 初回起動で決めて、以後は端末に残したものを使う（[Storage]）。
  final String deviceId;

  /// 端末の保存先。渡されなければ保存しない（テスト用の形）。
  final Storage? storage;

  /// 端末に残してあるopの数（log の先頭から何件までが端末にあるか）。増えたときだけ足す。
  int _savedOps = 0;

  final DateTime Function() _clock;

  /// この端末。オフラインで書き、あとで送る（送信は手順3）。
  final Device _device;

  /// 射影し直した、画面に見えるものだけ。並びは作られた順。
  final List<Issue> _issues = <Issue>[];

  /// 完了直後の取り消しができる時間。過ぎたら一覧から消える。
  static const Duration undoWindow = Duration(seconds: 6);

  final String householdName;

  /// 世帯メンバー。表示名は世帯で共有する。
  final List<Member> members;
  String meId = 'me';

  /// この端末を使う人を、明示的に選んだかどうか。
  /// 選ばないまま世帯に参加すると、別端末と「同じ人」になる事故が起きる。
  bool meExplicit = false;
  final Map<String, String> legacyMemberAliases;
  final Map<String, String> pendingMemberNames;

  /// まだ家に送っていない統合（旧ID → 残すID）。送信は手順3。
  final Map<String, String> pendingMemberAliases;

  /// まだ家に送っていない削除（ID）。送信は手順3。
  final Set<String> pendingMemberRemovals;

  /// 表示名の正規化。前後の半角・全角空白を落とす。
  static String normalizeMemberName(String name) =>
      name.replaceAll(RegExp(r'^[\s　]+|[\s　]+$'), '');

  /// 関係の呼び名は人の名前として使えない。鏡表示（自分のIDだけ「自分」）と衝突する。
  static bool isReservedMemberName(String name) {
    final normalized = normalizeMemberName(name);
    return normalized == '自分' || normalized == 'パートナー';
  }

  Future<void> Function(Member member)? onMemberWrite;

  /// この端末を使う人を変える。端末に残る（同期しない）。
  void setMeId(String id) {
    id = canonicalMemberId(id);
    if (id.isEmpty) return;
    meExplicit = true;
    if (id == meId) return;
    meId = id;
    if (!members.any((m) => m.id == id)) {
      members.add(Member(id, id));
    }
    storage?.saveMeId(id);
    _rebuild();
    notifyListeners();
  }

  /// 自分の表示名だけ変えられる。他人の名前は変えられない。
  /// 空・予約名（自分／パートナー）も変えられない。変えたら true。
  bool renameMember(String id, String name) {
    id = canonicalMemberId(id);
    if (id != canonicalMemberId(meId)) return false;
    final trimmed = normalizeMemberName(name);
    if (trimmed.isEmpty || isReservedMemberName(trimmed)) return false;
    final index = members.indexWhere((m) => m.id == id);
    if (index < 0) return false;
    if (members[index].name == trimmed) return true;
    members[index] = Member(id, trimmed);
    storage?.saveMemberNames({for (final m in members) m.id: m.name});
    _markMemberPending(members[index]);
    notifyListeners();
    return true;
  }

  Member addMember(String name) {
    final trimmed = normalizeMemberName(name);
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', '名前を入れてください');
    }
    if (isReservedMemberName(trimmed)) {
      throw ArgumentError.value(name, 'name', '「自分」「パートナー」は使えません。なまえ等を入れてください');
    }
    final member = Member('mem_${Device.newId()}', trimmed);
    members.add(member);
    storage?.saveMemberNames({for (final m in members) m.id: m.name});
    _markMemberPending(member);
    notifyListeners();
    return member;
  }

  /// 同じ人物IDで書いた端末の一覧。2台以上なら重複利用の疑い。
  Map<String, Set<String>> get memberDevices {
    final map = <String, Set<String>>{};
    for (final op in ops) {
      final member = op.memberId;
      if (member == null || member.isEmpty) continue;
      map
          .putIfAbsent(canonicalMemberId(member), () => <String>{})
          .add(op.deviceId);
    }
    return map;
  }

  /// 重複利用の疑いがある人物の表示。なければ空。
  List<String> get duplicateMemberLabels => [
    for (final entry in memberDevices.entries)
      if (entry.value.length > 1) assigneeWord(entry.key),
  ];

  /// 未完了の案件を担当しているかどうか。
  bool hasOpenAssignment(String id) {
    id = canonicalMemberId(id);
    return _issues.any(
      (issue) =>
          !issue.isDone &&
          issue.assigneeId != null &&
          canonicalMemberId(issue.assigneeId!) == id,
    );
  }

  /// 重複した人をまとめる。旧IDは対応表に残し、担当・履歴の見え方は維持する。
  /// 担当中の人でもまとめられる（対応表で引き継ぐ）。削除とはここが違う。
  /// 家への送信は手順3（[SyncSession] が pendingMemberAliases を送る）。
  /// 自分・存在しないIDはまとめられない。
  bool mergeMembers(String fromId, String intoId) {
    fromId = canonicalMemberId(fromId);
    intoId = canonicalMemberId(intoId);
    if (fromId == intoId) return false;
    if (fromId == canonicalMemberId(meId)) return false;
    if (memberById(fromId) == null || memberById(intoId) == null) {
      return false;
    }
    legacyMemberAliases[fromId] = intoId;
    pendingMemberAliases[fromId] = intoId;
    members.removeWhere((m) => m.id == fromId);
    pendingMemberNames.remove(fromId);
    storage?.saveMemberAliases(legacyMemberAliases);
    storage?.savePendingMemberAliases(pendingMemberAliases);
    storage?.saveMemberNames({for (final m in members) m.id: m.name});
    storage?.savePendingMemberNames(pendingMemberNames);
    meId = canonicalMemberId(meId);
    _rebuild();
    notifyListeners();
    return true;
  }

  /// 使っていない人を名簿から外す。未完了の担当・自分は外せない。
  bool removeMember(String id) {
    id = canonicalMemberId(id);
    if (memberById(id) == null) return false;
    if (id == canonicalMemberId(meId)) return false;
    if (hasOpenAssignment(id)) return false;
    members.removeWhere((m) => m.id == id);
    pendingMemberNames.remove(id);
    pendingMemberRemovals.add(id);
    storage?.saveMemberNames({for (final m in members) m.id: m.name});
    storage?.savePendingMemberNames(pendingMemberNames);
    storage?.savePendingMemberRemovals(pendingMemberRemovals);
    _rebuild();
    notifyListeners();
    return true;
  }

  /// 送り残した削除を消す（送信済み）。
  void markMemberRemovalSynced(String id) {
    if (!pendingMemberRemovals.remove(id)) return;
    storage?.savePendingMemberRemovals(pendingMemberRemovals);
    notifyListeners();
  }

  /// 送り残した統合を消す（送信済み）。
  void markMemberAliasSynced(String fromId) {
    if (pendingMemberAliases.remove(fromId) == null) return;
    storage?.savePendingMemberAliases(pendingMemberAliases);
    notifyListeners();
  }

  void _markMemberPending(Member member) {
    pendingMemberNames[member.id] = member.name;
    storage?.savePendingMemberNames(pendingMemberNames);
    onMemberWrite?.call(member);
  }

  void markMemberSynced(String id) {
    pendingMemberNames.remove(id);
    storage?.savePendingMemberNames(pendingMemberNames);
    notifyListeners();
  }

  Map<String, String> get legacyMemberNames => {
    for (final id in const ['me', 'partner'])
      if (memberById(id) != null) id: memberById(id)!.name,
  };

  String canonicalMemberId(String id) => legacyMemberAliases[id] ?? id;

  void applyMemberDirectory(MemberDirectory directory) {
    applyMemberAliases(directory.aliases);
    members
      ..clear()
      ..addAll(
        {
          for (final m in directory.members)
            // 家に削除が届くまで、外した人は出さない。
            if (!pendingMemberRemovals.contains(m.id))
              m.id: Member(m.id, pendingMemberNames[m.id] ?? m.name),
          for (final entry in pendingMemberNames.entries)
            entry.key: Member(entry.key, entry.value),
        }.values,
      );
    if (members.isEmpty) members.add(Member(meId, '自分'));
    if (!members.any((member) => member.id == meId)) {
      members.add(Member(meId, '自分'));
    }
    storage?.saveMemberNames({
      for (final member in members) member.id: member.name,
    });
    _rebuild();
    notifyListeners();
  }

  void applyMemberAliases(Map<String, String> aliases) {
    final oldMembers = List<Member>.of(members);
    final previousMe = meId;
    legacyMemberAliases
      ..clear()
      ..addAll(aliases);
    meId = canonicalMemberId(previousMe);
    for (final member in oldMembers) {
      final canonicalId = canonicalMemberId(member.id);
      final defaultName = member.id == 'me'
          ? '自分'
          : member.id == 'partner'
          ? 'パートナー'
          : null;
      if (defaultName != null && member.name != defaultName) {
        pendingMemberNames[canonicalId] = member.name;
      }
    }
    members
      ..clear()
      ..addAll(
        {
          for (final member in oldMembers)
            canonicalMemberId(member.id): Member(
              canonicalMemberId(member.id),
              member.name,
            ),
        }.values,
      );
    final pending = Map<String, String>.of(pendingMemberNames);
    pendingMemberNames
      ..clear()
      ..addAll({
        for (final entry in pending.entries)
          canonicalMemberId(entry.key): entry.value,
      });
    storage?.saveMemberAliases(legacyMemberAliases);
    storage?.saveMemberNames({for (final m in members) m.id: m.name});
    storage?.savePendingMemberNames(pendingMemberNames);
    storage?.saveMeId(meId);
    storage?.saveMemberAliases(legacyMemberAliases);
    storage?.saveMemberNames({
      for (final member in members) member.id: member.name,
    });
  }

  /// 記録の引っ越し用。持っているopをJSON配列で書き出す。
  String exportJson() => jsonEncode(encodeOps(_device.log));

  /// 書き出した記録を読み込む。受け取ったうち新しいopの数を返す。
  int importJson(String raw) {
    final decoded = jsonDecode(raw);
    final ops = decodeOps(decoded);
    if (ops.ops.isEmpty && ops.skipped > 0) {
      throw const FormatException('読める記録がありませんでした');
    }
    final known = _device.log.map((op) => op.id).toSet();
    final freshOps = ops.ops.where((op) => known.add(op.id)).toList();
    final fresh = freshOps.length;
    receive(ops.ops);
    _device.queueForRelay(freshOps);
    storage?.savePendingRelayIds(_device.pendingRelayIds);
    settle();
    return fresh;
  }

  DateTime get now => _clock();

  DateTime get today {
    final n = now;
    return DateTime(n.year, n.month, n.day);
  }

  List<Issue> get all => List.unmodifiable(_issues);

  /// いま持っているop。（送る側・検証用。手順3でこれをサーバーに渡す）
  List<Op> get ops => List.unmodifiable(_device.log);

  /// まだサーバーに送っていないop（送信待ち）。
  List<Op> get outbox => _device.peekOutbox();

  /// 送れたopを送信待ちから外す。送れなかったものは残る。
  /// どこまで届いたかを端末に残すので、次の起動で送り直さない。
  void markSent(Iterable<Op> ops) {
    _device.markSent(ops);
    storage?.savePushedThrough(_device.pushedThrough);
    storage?.savePendingRelayIds(_device.pendingRelayIds);
    notifyListeners();
  }

  /// 自分で書いた直後に呼ばれる（同期の自動送信の入口）。
  /// 受信では呼ばない（相手のopをそのまま送り返さないため）。
  void Function()? onLocalWrite;

  /// 他の端末のopを受け取る。同じop集合を持てば、どの端末でも同じ画面になる。
  /// 受け取ったあとに足りない「次の1件」を書くのは [settle] の仕事。
  void receive(Iterable<Op> incoming) {
    _device.receive(incoming);
    _rebuild();
    _save(); // もらったぶんも残す（次の起動で取り直さないため）
    notifyListeners();
  }

  /// もらったopから、足りない「次の1件」を書く（同期の後始末。書くものが無ければ何もしない）。
  void settle() => _commit(() {});

  /// 受け取ったうち、まだ持っていなかったopの数（[receive] の前に数える）。
  /// 同期の「新しく入った数」。自分のopが返ってきても、ここでは増えない。
  int countNew(Iterable<Op> incoming) {
    final known = _device.log.map((op) => op.id).toSet();
    var count = 0;
    for (final op in incoming) {
      if (known.add(op.id)) count += 1;
    }
    return count;
  }

  Issue? byId(String id) {
    for (final i in _issues) {
      if (i.id == id) return i;
    }
    return null;
  }

  Member? memberById(String? id) {
    if (id == null) return null;
    id = canonicalMemberId(id);
    for (final m in members) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 画面に出す名前。担当なしは「だれでも」。
  /// 既定の呼び名はこの端末の利用者から見た関係で表示する。
  String? memberLabel(String? id) {
    if (id == null) return null;
    id = canonicalMemberId(id);
    final member = memberById(id);
    if (member == null) return null;
    String? legacyId;
    for (final entry in legacyMemberAliases.entries) {
      if (entry.value == id) legacyId = entry.key;
    }
    final isDefaultAlias =
        ((id == 'me' || legacyId == 'me') && member.name == '自分') ||
        ((id == 'partner' || legacyId == 'partner') && member.name == 'パートナー');
    if (isDefaultAlias) return id == meId ? '自分' : 'パートナー';
    return id == meId ? '自分' : member.name;
  }

  String assigneeWord(String? id) => memberLabel(id) ?? 'だれでも';

  bool _isTodayDue(Issue i) =>
      i.dueDate != null && !_day(i.dueDate!).isAfter(today);

  int _todayOrder(Issue a, Issue b) => a.dueDate!.compareTo(b.dueDate!);

  int _laterOrder(Issue a, Issue b) {
    final ad = a.dueDate, bd = b.dueDate;
    if (ad != null && bd != null) return ad.compareTo(bd);
    if (ad != null) return -1;
    if (bd != null) return 1;
    return 0;
  }

  /// 今日やるもの。期限が今日以前のものだけ。自分の担当かどうかは問わない。
  List<Issue> get todayQueue =>
      _queue((i) => !i.isDone && _isTodayDue(i), _todayOrder);

  /// あとで。期限がないもの、先のもの。
  List<Issue> get laterQueue =>
      _queue((i) => !i.isDone && !_isTodayDue(i), _laterOrder);

  /// 画面に出す「今日」の行。完了した直後のものも、元の並びの位置に残す。
  List<Issue> get todayRows =>
      _queue((i) => _showsInList(i) && _isTodayDue(i), _todayOrder);

  /// 画面に出す「あとで」の行。完了した直後のものも、元の並びの位置に残す。
  List<Issue> get laterRows =>
      _queue((i) => _showsInList(i) && !_isTodayDue(i), _laterOrder);

  bool _showsInList(Issue i) => !i.isDone || _remaining(i) != null;

  List<Issue> get openIssues => [...todayQueue, ...laterQueue];

  /// 完了した直後だけ、薄く残して取り消せるようにする。
  List<Issue> get justDone =>
      _issues.where((i) => i.isDone && _remaining(i) != null).toList();

  /// これまでおわったもの（新しい順）。詳細の前回・前々回とは別に、後から探す用。
  List<Issue> get doneHistory {
    final list = _issues.where((i) => i.isDone).toList();
    list.sort((a, b) {
      final at = a.completedAt;
      final bt = b.completedAt;
      if (at != null && bt != null) return bt.compareTo(at);
      if (bt != null) return 1;
      if (at != null) return -1;
      return 0;
    });
    return list;
  }

  Duration? undoRemaining(Issue issue) => _remaining(issue);

  Duration? _remaining(Issue issue) {
    final at = issue.completedAt;
    if (at == null) return null;
    final left = undoWindow - now.difference(at);
    return left.isNegative ? null : left;
  }

  /// 同じ定期案件の、これまでの完了（新しい順）。
  List<Issue> seriesHistory(String seriesKey) {
    final list = _issues
        .where(
          (i) => i.seriesKey == seriesKey && i.isDone && i.completedAt != null,
        )
        .toList();
    list.sort((a, b) => b.completedAt!.compareTo(a.completedAt!));
    return list;
  }

  /// 登録に必要なのはタイトルだけ。担当も期限も後から足せる。
  Issue add({
    required String title,
    String? assigneeId,
    DateTime? dueDate,
    Recurrence recurrence = Recurrence.none,
    IssueStatus status = IssueStatus.open,
    DateTime? at,
  }) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(title, 'title', 'タイトルは必須');
    final createdAt = at ?? now;

    // 案件idは、それを生むadd opのidから取る（決定的で、端末をまたいでも衝突しない）。
    final issueId = _device.nextOpId();
    final due = dueDate == null ? null : _day(dueDate);

    _commit(() {
      _device.write(
        OpKind.add,
        issueId,
        at: createdAt,
        memberId: meId,
        data: <String, Object?>{
          'title': trimmed,
          'assigneeId': assigneeId,
          'dueDate': due,
          'recurrence': recurrence,
          // 追加の時点で必ず決めて、次の1件へ引き継ぐ。
          'seriesId': issueId,
        },
      );
      if (status != IssueStatus.open) {
        _device.write(
          OpKind.status,
          issueId,
          at: createdAt,
          memberId: meId,
          data: <String, Object?>{'status': status},
        );
      }
    });
    return byId(issueId)!;
  }

  /// 1タップで完了。定期案件なら次の1件が自動で出てくる。
  void complete(String id) {
    final issue = byId(id);
    if (issue == null || issue.isDone) return;
    _commit(() => _device.write(OpKind.complete, id, at: now, memberId: meId));
  }

  /// 完了をなかったことにする。自動生成した次の1件は、opを消さずに射影で隠れる。
  void undoComplete(String id) {
    final issue = byId(id);
    if (issue == null || !issue.isDone) return;
    _commit(() => _device.write(OpKind.reopen, id, at: now, memberId: meId));
  }

  void setAssignee(String id, String? memberId) {
    if (byId(id) == null) return;
    _commit(
      () => _device.write(
        OpKind.assignee,
        id,
        at: now,
        memberId: meId,
        data: <String, Object?>{'assigneeId': memberId},
      ),
    );
  }

  void setDue(String id, DateTime? due) {
    if (byId(id) == null) return;
    _commit(
      () => _device.write(
        OpKind.due,
        id,
        at: now,
        memberId: meId,
        data: <String, Object?>{'dueDate': due == null ? null : _day(due)},
      ),
    );
  }

  void setRecurrence(String id, Recurrence recurrence) {
    if (byId(id) == null) return;
    _commit(
      () => _device.write(
        OpKind.recurrence,
        id,
        at: now,
        memberId: meId,
        data: <String, Object?>{'recurrence': recurrence},
      ),
    );
  }

  void setStatus(String id, IssueStatus status) {
    final issue = byId(id);
    if (issue == null || issue.status == status) return;
    if (status == IssueStatus.done) {
      complete(id);
      return;
    }
    _commit(() {
      if (issue.isDone) {
        // 完了でなくなるなら、完了の取り消しと同じ。自動生成した次の1件も見えなくなる。
        _device.write(OpKind.reopen, id, at: now, memberId: meId);
        if (status == IssueStatus.open) return;
      }
      _device.write(
        OpKind.status,
        id,
        at: now,
        memberId: meId,
        data: <String, Object?>{'status': status},
      );
    });
  }

  void rename(String id, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty || byId(id) == null) return;
    _commit(
      () => _device.write(
        OpKind.rename,
        id,
        at: now,
        memberId: meId,
        data: <String, Object?>{'title': trimmed},
      ),
    );
  }

  void comment(String id, String text) {
    final t = text.trim();
    if (t.isEmpty || byId(id) == null) return;
    _commit(
      () => _device.write(
        OpKind.comment,
        id,
        at: now,
        memberId: meId,
        data: <String, Object?>{'text': t},
      ),
    );
  }

  void remove(String id) {
    if (byId(id) == null) return;
    _commit(() => _device.write(OpKind.delete, id, at: now, memberId: meId));
  }

  /// opを書いて、足りない「次の1件」を補い、画面を作り直す。書き込みは必ずここを通す。
  void _commit(void Function() writes) {
    _device.writeAtomically(() {
      writes();
      writeMissingFollowUps(project(_device.log), _device, at: now);
    });
    _rebuild();
    _save();
    notifyListeners();
    // 同期（手順3）の自動送信。受信はここを通らないので、相手のopを送り返さない。
    onLocalWrite?.call();
  }

  /// 保存から戻す。送信待ちも作り直す（自分が書いたopのうち、サーバーが確認していないもの）。
  void _restore(SavedState saved) {
    if (saved.deviceId.isNotEmpty) {
      final migratingLegacyId = saved.deviceId == 'dev' && deviceId != 'dev';
      final relayIds = <String>{
        ...saved.pendingRelayIds,
        if (migratingLegacyId)
          ...saved.ops
              .where(
                (op) =>
                    op.deviceId == 'dev' && op.lamport > saved.pushedThrough,
              )
              .map((op) => op.id),
      };
      _device.restore(
        saved.ops,
        pushedThrough: saved.pushedThrough,
        pendingRelayIds: relayIds,
      );
      storage?.savePendingRelayIds(_device.pendingRelayIds);
    }
    _savedOps = _device.log.length;
    _rebuild();
  }

  /// 増えたぶんを端末に残す。射影（画面に出す形）は残さず、起動時にopから作り直す。
  ///
  /// opは追記のみで log の並びは変わらないので、「先頭から何件までが端末にあるか」で
  /// 増えたぶんだけを渡せる（全件を書き直さない）。
  void _save() {
    final target = storage;
    if (target == null || _device.log.length == _savedOps) return;
    final fresh = _device.log.sublist(_savedOps);
    _savedOps = _device.log.length;
    target.appendOps(fresh);
  }

  /// 射影し直して、見えるものだけを Issue に写す。並びは op の並び（作られた順）。
  void _rebuild() {
    final tasks = project(_device.log).values.where((t) => t.isVisible).toList()
      ..sort((a, b) => a.addOrder.compareTo(b.addOrder));
    _issues
      ..clear()
      ..addAll(tasks.map(_toIssue));
  }

  Issue _toIssue(Task task) {
    final issue = Issue(
      id: task.id,
      title: task.title,
      createdAt: _createdAt(task),
      reporterId: _createdBy(task),
      assigneeId: task.assigneeId == null
          ? null
          : canonicalMemberId(task.assigneeId!),
      dueDate: task.dueDate,
      recurrence: task.recurrence,
      status: task.status,
      seriesId: task.seriesId,
      completedAt: task.completedAt,
      events: _events(task),
    );
    issue.generatedNextId = task.generatedNextId;
    return issue;
  }

  DateTime _createdAt(Task task) {
    for (final op in task.history) {
      if (op.kind == OpKind.add) return op.at;
    }
    return task.history.isEmpty
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : task.history.first.at;
  }

  String _createdBy(Task task) {
    for (final op in task.history) {
      if (op.kind == OpKind.add && op.memberId != null) return op.memberId!;
    }
    return canonicalMemberId(meId);
  }

  List<IssueEvent> _events(Task task) {
    final events = <IssueEvent>[];
    for (final op in task.history) {
      final event = _event(task, op);
      if (event != null) events.add(event);
    }
    return events;
  }

  /// op1つぶんの履歴。記録に操作者がない場合は推測で補完しない。
  IssueEvent? _event(Task task, Op op) {
    final actor = op.memberId == null ? null : canonicalMemberId(op.memberId!);
    switch (op.kind) {
      case OpKind.add:
        final title = (op.data['title'] as String?) ?? task.title;
        return IssueEvent(
          EventKind.created,
          op.at,
          actorId: actor,
          text: op.derivedFrom == null ? '追加した' : '「$title」の次の1件',
        );
      case OpKind.rename:
        // 名前は見出しに出るので、履歴には残さない（今までどおり）。
        return null;
      case OpKind.assignee:
        final id = op.data['assigneeId'] as String?;
        return IssueEvent(
          EventKind.assignee,
          op.at,
          actorId: actor,
          text: id == null ? 'だれでもにした' : '${assigneeWord(id)}が担当になった',
        );
      case OpKind.due:
        final due = op.data['dueDate'] as DateTime?;
        return IssueEvent(
          EventKind.due,
          op.at,
          actorId: actor,
          text: due == null ? '期限を消した' : '${due.month}/${due.day}にした',
        );
      case OpKind.recurrence:
        final recurrence =
            (op.data['recurrence'] as Recurrence?) ?? Recurrence.none;
        return IssueEvent(
          EventKind.recurrence,
          op.at,
          actorId: actor,
          text: '${recurrence.label}にした',
        );
      case OpKind.status:
        final status = op.data['status'] as IssueStatus?;
        if (status == null || status == IssueStatus.done) return null;
        return IssueEvent(
          EventKind.status,
          op.at,
          actorId: actor,
          text: '${status.word}にした',
        );
      case OpKind.comment:
        final text = op.data['text'] as String?;
        if (text == null || text.isEmpty) return null;
        return IssueEvent(EventKind.comment, op.at, actorId: actor, text: text);
      case OpKind.complete:
        return IssueEvent(
          EventKind.completed,
          op.at,
          actorId: actor,
          text: 'おわった',
        );
      case OpKind.reopen:
        return IssueEvent(
          EventKind.reopened,
          op.at,
          actorId: actor,
          text: 'もどした',
        );
      case OpKind.delete:
        return null;
    }
  }

  /// 絞り込んで並べる。同じ条件のときは、作られた順（opの順）で安定させる。
  List<Issue> _queue(
    bool Function(Issue) keep,
    int Function(Issue, Issue) compare,
  ) {
    final order = <String, int>{
      for (var i = 0; i < _issues.length; i++) _issues[i].id: i,
    };
    final list = _issues.where(keep).toList();
    list.sort((a, b) {
      final result = compare(a, b);
      return result != 0 ? result : order[a.id]!.compareTo(order[b.id]!);
    });
    return list;
  }

  /// 触って確かめられるよう、よくある家庭の案件を入れておく。
  /// 過去から順に書いていくので、履歴も定期の連なりも、opからそのまま組み上がる。
  factory IssueStore.demo({DateTime Function()? clock, Storage? storage}) {
    // 2回目以降は、端末に残しておいたものをそのまま開く（デモを入れ直さない）。
    final saved = storage?.load();
    if (saved != null && saved.ops.isNotEmpty) {
      return IssueStore(clock: clock, storage: storage);
    }

    final live = clock ?? DateTime.now;
    final target = live();
    final today = DateTime(target.year, target.month, target.day);

    // 組み立てているあいだだけ、時計を過去に進めながら書く。
    var cursor = target;
    var building = true;
    final store = IssueStore(
      clock: () => building ? cursor : live(),
      storage: storage,
    );

    // エアコンのフィルターそうじ: 2回の完了を経て、いまの1件が3日後に出ている。
    cursor = today.subtract(const Duration(days: 118));
    final aircon = store.add(
      title: 'エアコンのフィルターそうじ',
      dueDate: today.subtract(const Duration(days: 117)),
      recurrence: Recurrence.every(60),
    );
    cursor = today.subtract(const Duration(days: 117));
    store.complete(aircon.id);
    cursor = today.subtract(const Duration(days: 57));
    store.complete(
      store.openIssues.firstWhere((i) => i.title.startsWith('エアコン')).id,
    );

    cursor = today.subtract(const Duration(days: 3, hours: 2));
    final noise = store.add(title: '水道から変な音がする', assigneeId: 'me');
    cursor = today.subtract(const Duration(days: 3));
    store.add(title: '子供の靴を買う');
    cursor = today.subtract(const Duration(days: 2, hours: 20));
    store.comment(noise.id, '夜に音がする');
    cursor = today.subtract(const Duration(days: 2));
    store.comment(noise.id, '管理会社に電話した');
    cursor = today
        .subtract(const Duration(days: 2))
        .add(const Duration(hours: 1));
    store.setStatus(noise.id, IssueStatus.waiting);

    cursor = today.subtract(const Duration(days: 1));
    store.add(title: '保育園の書類を書く', assigneeId: 'partner', dueDate: today);
    cursor = today
        .subtract(const Duration(days: 1))
        .add(const Duration(hours: 2));
    store.add(
      title: 'ゴミ出し',
      assigneeId: 'partner',
      dueDate: _nextWeekday(today, const {2, 5}),
      recurrence: Recurrence.onWeekdays(const {2, 5}),
    );

    cursor = today.subtract(const Duration(hours: 5));
    final bulb = store.add(title: '廊下の電球を交換する');
    cursor = today.subtract(const Duration(hours: 4, minutes: 40));
    store.comment(bulb.id, '電球切れてた');
    cursor = today.subtract(const Duration(hours: 4, minutes: 20));
    store.setAssignee(bulb.id, 'me');
    cursor = today.subtract(const Duration(hours: 4));
    store.comment(bulb.id, 'E26だった');

    cursor = today.subtract(const Duration(hours: 3));
    store.add(title: '牛乳を買う', assigneeId: 'me', dueDate: today);
    cursor = today.subtract(const Duration(hours: 2));
    store.add(
      title: 'お風呂そうじ',
      assigneeId: 'partner',
      dueDate: today,
      recurrence: Recurrence.daily,
    );

    cursor = target;
    building = false;
    return store;
  }
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _nextWeekday(DateTime from, Set<int> weekdays) {
  var d = _day(from);
  if (weekdays.contains(d.weekday)) return d;
  for (var i = 0; i < 7; i++) {
    d = DateTime(d.year, d.month, d.day + 1);
    if (weekdays.contains(d.weekday)) return d;
  }
  return d;
}
