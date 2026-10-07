import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'format.dart';
import 'model.dart';
import 'one_link.dart';
import 'store.dart';
import 'sync/api.dart';
import 'sync/session.dart';

/// 1件リンクを開いた人に見せるページ（アプリの3画面の外側）。
///
/// **アプリを入れていない相手**がブラウザで開く前提なので、できることは2つだけ:
/// 中身を見て、「やる」（担当を引き受ける）か「あとで」か。
/// 端末には何も残さない（相手のブラウザに世帯の記録を置かない）。
class OnePage extends StatefulWidget {
  const OnePage({super.key, required this.link, this.api, this.clock});

  final OneLink link;

  /// テスト用に差し替える（本番はリンクのドメインから組み立てる）。
  final SyncApi? api;

  final DateTime Function()? clock;

  @override
  State<OnePage> createState() => _OnePageState();
}

/// 画面の状態。1件リンクはこの6つしかない。
enum _Stage { loading, ready, accepted, pending, later, done, gone, offline }

class _OnePageState extends State<OnePage> {
  /// この人（アプリを入れていない相手）の端末id。**保存しない**ので、開くたびに新しくなる。
  /// 推測できない長さにして、世帯の記録とぶつからないようにする。
  /// 書いた人の記録は、リンクで決めたメンバーとして残す。
  late final IssueStore _store =
      IssueStore(deviceId: _guestId(), clock: widget.clock, initialMeId: widget.link.memberId);

  late final SyncApi _api = widget.api ??
      SyncApi(
        baseUrl: widget.link.baseUrl,
        householdId: widget.link.householdId,
        token: widget.link.token,
        // 1件リンクなので、その1件のopだけをもらう（世帯の全部は取ってこない）。
        issueId: widget.link.issueId,
      );

  late final SyncSession _session = SyncSession(store: _store, api: _api);

  _Stage _stage = _Stage.loading;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _session.close();
    super.dispose();
  }

  Future<void> _load() async {
    var failed = false;
    try {
      await _session.syncNow();
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;

    final issue = _store.byId(widget.link.issueId);
    if (issue == null) {
      setState(() => _stage = failed ? _Stage.offline : _Stage.gone);
      return;
    }
    if (issue.isDone) {
      setState(() => _stage = _Stage.done);
      return;
    }
    setState(() => _stage = issue.assigneeId == widget.link.memberId ? _Stage.accepted : _Stage.ready);
  }

  /// 「やる」。担当を引き受けたことをopとして書いて、その場で送る。
  ///
  /// すでに書いてある（送れなかったぶんが残っている）なら、**書かずに送り直すだけ**。
  /// 押し直すたびに同じ担当のopが増えると、相手の履歴にも同じ行が並んでしまう。
  Future<void> _take() async {
    if (_store.byId(widget.link.issueId)?.assigneeId != widget.link.memberId) {
      _store.setAssignee(widget.link.issueId, widget.link.memberId);
    }
    try {
      await _session.pushNow();
      if (mounted) setState(() => _stage = _Stage.accepted);
    } catch (_) {
      // 送れなくても、書いたことは端末の中に残っている（このページを開いているあいだ）。
      if (mounted) setState(() => _stage = _Stage.pending);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final issue = _store.byId(widget.link.issueId);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('いえこと', style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 26),
              if (issue == null)
                Text(_messageForNothing(scheme), style: const TextStyle(fontSize: 18, height: 1.4))
              else
                Text(
                  issue.title,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, height: 1.35),
                ),
              if (issue != null) ...[
                const SizedBox(height: 12),
                Text(_metaLine(issue), style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant)),
              ],
              const Spacer(),
              Text(_message(scheme), style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 14),
              ..._actions(scheme),
            ],
          ),
        ),
      ),
    );
  }

  String _messageForNothing(ColorScheme scheme) => switch (_stage) {
        _Stage.loading => '読み込んでいます',
        _Stage.offline => 'つながりませんでした。電波の良いところでもう一度どうぞ',
        _ => 'この1件は、もう終わったか消えています',
      };

  String _message(ColorScheme scheme) => switch (_stage) {
        _Stage.loading => '',
        _Stage.ready => '自分の担当にできます',
        _Stage.accepted => '引き受けました。送った人にも伝わります',
        _Stage.pending => '引き受けました。いまは送れませんでした',
        _Stage.later => 'また今度で大丈夫です',
        _Stage.done => 'もう終わっています',
        _Stage.gone => '',
        _Stage.offline => '',
      };

  /// 押せるものは、状態で決まる。1件リンクに、それ以外の操作は出さない。
  List<Widget> _actions(ColorScheme scheme) {
    final issue = _store.byId(widget.link.issueId);
    if (issue == null) {
      if (_stage != _Stage.offline) return const <Widget>[];
      return <Widget>[
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            key: const ValueKey('one-retry'),
            onPressed: () {
              setState(() => _stage = _Stage.loading);
              unawaited(_load());
            },
            child: const Text('もう一度'),
          ),
        ),
      ];
    }

    switch (_stage) {
      case _Stage.ready:
        return <Widget>[
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              key: const ValueKey('one-take'),
              onPressed: _take,
              child: const Text('やる'),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              key: const ValueKey('one-later'),
              onPressed: () => setState(() => _stage = _Stage.later),
              child: const Text('あとで'),
            ),
          ),
        ];
      case _Stage.pending:
        return <Widget>[
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              key: const ValueKey('one-retry-send'),
              onPressed: _take,
              child: const Text('もう一度送る'),
            ),
          ),
        ];
      default:
        return const <Widget>[];
    }
  }

  /// 期限と担当だけ。1件リンクに、それ以外の情報は出さない。
  String _metaLine(Issue issue) {
    final words = <String>[];
    if (issue.dueDate != null) words.add(dueLabel(issue.dueDate!, _store.now));
    words.add(_assigneeWord(issue.assigneeId));
    return words.join('・');
  }

  /// 担当の言い方は、**開いた人から見た言い方**にする。
  ///
  /// 世帯の呼び名（自分・パートナー）は、アプリを持っている側の都合で、開いた人には分からない。
  /// 開いた人に分かるのは、このリンクで引き受けるのが誰か（[OneLink.memberId]）だけ。
  /// だから、ほかの人を「自分」と呼んでしまわないようにする。
  String _assigneeWord(String? id) {
    if (id == null) return 'だれでも';
    return id == widget.link.memberId ? '自分' : 'ほかの人';
  }
}

/// 開くたびに新しくなる端末id。opのidが世帯のものとぶつからない長さにする。
String _guestId() {
  final random = Random.secure();
  return 'g${random.nextInt(1 << 30).toRadixString(36)}${random.nextInt(1 << 30).toRadixString(36)}';
}
