import 'dart:async';

import 'package:flutter/material.dart';

import 'composer.dart';
import 'detail_page.dart';
import 'done_page.dart';
import 'format.dart';
import 'model.dart';
import 'notices.dart';
import 'store.dart';
import 'write_guard.dart';
import 'sync/storage.dart';
import 'sync/session.dart';
import 'sync/status_line.dart';
import 'widgets.dart';

/// ホームに出すのは「今やるもの」と「あとで」の2つだけ。
/// グラフもカレンダーも達成率も置かない。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.store,
    this.linkFor,
    this.credentials,
    this.onOpenHousehold,
    this.session,
    this.onSyncRetry,
  });

  final IssueStore store;
  final SyncSession? session;
  final Future<void> Function()? onSyncRetry;

  /// 1件リンクを作る（同期の設定が無ければ null）。詳細の「そのほか」から使う。
  final Future<String?> Function(Issue)? linkFor;

  /// いま使っている同期の設定。nullなら未接続。
  final SyncCredentials? credentials;

  /// 世帯名を押したときに開く（同期の設定シート）。
  final Future<void> Function(BuildContext context)? onOpenHousehold;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Timer? _sweep;
  final ScrollController _scroll = ScrollController();
  final GlobalKey<ComposerState> _composerKey = GlobalKey<ComposerState>();

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreChanged);
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
      _rowKeys.clear();
      _sweep?.cancel();
      _scheduleSweep();
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    _sweep?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};

  /// 追加したものが見えないと信用されない。入れた直後だけ、追加した行まで送る。
  void _scrollTo(Issue issue) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _rowKeys[issue.id]?.currentContext;
      if (!mounted || context == null) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: 0.5,
      );
    });
  }

  void _onStoreChanged() {
    _scheduleSweep();
    if (mounted) setState(() {});
  }

  /// 取り消せる時間が終わったら、おわった行を一覧から消す。
  void _scheduleSweep() {
    _sweep?.cancel();
    Duration? soonest;
    for (final issue in widget.store.justDone) {
      final left = widget.store.undoRemaining(issue);
      if (left != null && (soonest == null || left < soonest)) soonest = left;
    }
    if (soonest == null) return;
    _sweep = Timer(soonest + const Duration(milliseconds: 80), () {
      if (mounted) setState(() {});
    });
  }

  void _openDetail(Issue issue) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          store: widget.store,
          issueId: issue.id,
          linkFor: widget.linkFor,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final today = store.todayRows;
    final later = store.laterRows;
    _rowKeys.removeWhere((id, _) => store.byId(id) == null);
    final empty = today.isEmpty && later.isEmpty;
    // 未接続のあいだは手順を残す。空でなくてもつなげる案内は消さない。
    final showSteps =
        widget.credentials == null && widget.onOpenHousehold != null;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _header(store),
            _noticeLine(store),
            if (widget.session != null)
              SyncStatusLine(
                session: widget.session!,
                onRetry: widget.onSyncRetry,
              ),
            Expanded(
              child: empty
                  ? Center(child: SingleChildScrollView(child: _empty()))
                  // 件数は少ないので、行を全部作っておく（追加した行へ確実に送れる）。
                  : SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.only(bottom: 96),
                      child: Column(
                        children: [
                          if (today.isNotEmpty) ...[
                            _section(
                              '今日',
                              today.where((i) => !i.isDone).length,
                            ),
                            ..._rows(today),
                          ],
                          if (later.isNotEmpty) ...[
                            _section(
                              'あとで',
                              later.where((i) => !i.isDone).length,
                            ),
                            ..._rows(later),
                          ],
                          _doneEntry(),
                        ],
                      ),
                    ),
            ),
            if (showSteps && !empty) _connectStrip(),
            Composer(
              key: _composerKey,
              store: store,
              onAdded: _scrollTo,
              compact: MediaQuery.viewInsetsOf(context).bottom > 0,
            ),
          ],
        ),
      ),
    );
  }

  /// 1件でも入ったら、手順1は終わり。2だけ細帯で残す。
  /// キーボード表示中は隠してoverflowを避ける。
  Widget _connectStrip() {
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      return const SizedBox.shrink();
    }
    final openHousehold = widget.onOpenHousehold!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.8),
            width: 0.5,
          ),
        ),
      ),
      child: OutlinedButton(
        key: const ValueKey('empty-household'),
        onPressed: () => _openSheet(openHousehold),
        child: const Text('2 家族とつなげる'),
      ),
    );
  }

  Widget _header(IssueStore store) {
    final connected = widget.credentials != null;
    final open = widget.onOpenHousehold;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Row(
        children: [
          const Text(
            '家のこと',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          InkWell(
            key: const ValueKey('household-open'),
            onTap: open == null ? null : () => open(context),
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: connected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    connected ? '家族と共有' : store.householdName,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// お知らせ1行。なければ何も出さない（ホームの情報量を増やさない）。
  Widget _noticeLine(IssueStore store) {
    final line = noticeLineFor(store);
    if (line == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          line,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _doneEntry({bool center = false}) => Align(
    alignment: center ? Alignment.center : Alignment.centerLeft,
    child: TextButton(
      key: const ValueKey('done-open'),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              DonePage(store: widget.store, linkFor: widget.linkFor),
        ),
      ),
      style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
      child: const Text('おわったものをみる', style: TextStyle(fontSize: 13)),
    ),
  );

  Widget _section(String label, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
    child: Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.04,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  List<Widget> _rows(List<Issue> group) {
    final store = widget.store;
    final rows = <Widget>[];
    for (var i = 0; i < group.length; i++) {
      final issue = group[i];
      final done = issue.isDone;
      rows.add(
        _IssueRow(
          key: _rowKeys.putIfAbsent(issue.id, GlobalKey.new),
          issue: issue,
          meta: _metaWords(issue),
          overdue:
              !done &&
              issue.dueDate != null &&
              isOverdue(issue.dueDate!, store.now),
          done: done,
          onTap: done ? null : () => _openDetail(issue),
          onDone: done
              ? null
              : () => guardWrite(context, () => store.complete(issue.id)),
          onUndo: done
              ? () => guardWrite(context, () => store.undoComplete(issue.id))
              : null,
        ),
      );
      if (i != group.length - 1) {
        rows.add(
          const Padding(padding: EdgeInsets.only(left: 60), child: HairLine()),
        );
      }
    }
    return rows;
  }

  /// 一覧に出す情報は最大2つ。
  List<String> _metaWords(Issue issue) {
    final store = widget.store;
    final words = <String>[];
    if (issue.dueDate != null) words.add(dueLabel(issue.dueDate!, store.now));
    if (issue.assigneeId != null) {
      words.add(store.assigneeWord(issue.assigneeId));
    }
    if (issue.recurrence.isNone == false) words.add(issue.recurrence.label);
    return words.take(2).toList();
  }

  /// 手順からシートへ移るときは、開いた追加欄を先に畳む（重ねない）。
  void _openSheet(Future<void> Function(BuildContext context) openHousehold) {
    _composerKey.currentState?.close();
    openHousehold(context);
  }

  Widget _empty() {
    // 未接続のあいだだけ手順を出す（つなげたら卒業。デモ入り起動とも整合する）。
    final showSteps =
        widget.credentials == null && widget.onOpenHousehold != null;
    final openHousehold = widget.onOpenHousehold;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'いまは何もない',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              if (showSteps)
                Text(
                  'はじめの2ステップ',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              if (showSteps) const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('empty-add'),
                onPressed: () => _composerKey.currentState?.open(),
                icon: const Icon(Icons.add, size: 20),
                label: Text(showSteps ? '1 追加してみる' : '追加する'),
              ),
              if (showSteps && openHousehold != null) ...[
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const ValueKey('empty-household'),
                  onPressed: () => _openSheet(openHousehold),
                  child: const Text('2 家族とつなげる'),
                ),
              ],
              const SizedBox(height: 8),
              Center(child: _doneEntry(center: true)),
              if (!showSteps)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '気づいたときに 追加 で入れておく',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IssueRow extends StatelessWidget {
  const _IssueRow({
    super.key,
    required this.issue,
    required this.meta,
    required this.overdue,
    required this.done,
    this.onTap,
    this.onDone,
    this.onUndo,
  });

  final Issue issue;
  final List<String> meta;
  final bool overdue;
  final bool done;
  final VoidCallback? onTap;
  final VoidCallback? onDone;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dim = done ? 0.45 : 1.0;
    final metaWords = meta.join('・');
    final semanticsLabel = done
        ? (metaWords.isEmpty
              ? '${issue.title}、おわった'
              : '${issue.title}、$metaWords、おわった')
        : (metaWords.isEmpty ? issue.title : '${issue.title}、$metaWords');
    return Semantics(
      button: onTap != null,
      label: semanticsLabel,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                height: 52,
                // 完了行のもどすは右のボタンに一本化し、読み上げの重複を避ける。
                child: ExcludeSemantics(
                  excluding: done,
                  child: IconButton(
                    key: ValueKey(
                      done ? 'undo-${issue.title}' : 'done-${issue.title}',
                    ),
                    onPressed: done ? onUndo : onDone,
                    iconSize: 24,
                    tooltip: done ? 'もどす' : 'おわった',
                    icon: Icon(
                      done ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: done
                          ? scheme.primary.withValues(alpha: 0.5)
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              // 本文は親ラベルに集約し、二重読みを避ける。
              Expanded(
                child: ExcludeSemantics(
                  excluding: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          issue.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurface.withValues(alpha: dim),
                            decoration: done
                                ? TextDecoration.lineThrough
                                : null,
                            decorationColor: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (meta.isNotEmpty || done) ...[
                          const SizedBox(height: 3),
                          Text(
                            done ? 'おわった' : meta.join('・'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: overdue && !done
                                  ? scheme.error.withValues(alpha: 0.85)
                                  : scheme.onSurfaceVariant.withValues(
                                      alpha: dim,
                                    ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ), // Expanded
              if (done)
                TextButton(
                  onPressed: onUndo,
                  child: const Text('もどす', style: TextStyle(fontSize: 13)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
