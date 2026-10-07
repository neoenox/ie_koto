import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';
import 'model.dart';
import 'store.dart';
import 'widgets.dart';

/// 詳細。担当・期限・くりかえしは畳んで置き、普段は目に入らないようにする。
/// 下の並びは、コメント欄ではなく家族のやりとりとして読める形にする。
class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.store, required this.issueId, this.linkFor});

  final IssueStore store;
  final String issueId;

  /// 1件リンクを作る（同期の設定が無ければ null）。
  final Future<String?> Function(Issue)? linkFor;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  final TextEditingController _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final issue = widget.store.byId(widget.issueId);
        if (issue == null) return const Scaffold(body: SizedBox.shrink());
        return Scaffold(
          appBar: AppBar(
            elevation: 0,
            scrolledUnderElevation: 0,
            leading: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back, size: 20),
              tooltip: 'もどる',
            ),
            title: const SizedBox.shrink(),
            actions: [_menu(issue)],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Text(
                issue.title,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, height: 1.35),
              ),
              if (issue.status == IssueStatus.waiting) ...[
                const SizedBox(height: 10),
                Row(children: [
                  MiniChip(label: '対応待ち', selected: true, onTap: null),
                ]),
              ],
              const SizedBox(height: 14),
              const HairLine(),
              AttrRow(
                label: 'だれが',
                value: widget.store.assigneeWord(issue.assigneeId),
                onTap: () => _pickAssignee(issue),
              ),
              AttrRow(
                label: 'いつまで',
                value: issue.dueDate == null ? 'なし' : dueLabel(issue.dueDate!, widget.store.now),
                onTap: () => _pickDue(issue),
              ),
              AttrRow(
                label: 'くりかえし',
                value: issue.recurrence.label,
                onTap: () => _pickRecurrence(issue),
              ),
              if (!issue.recurrence.isNone)
                Padding(
                  padding: const EdgeInsets.only(left: 76, bottom: 6),
                  child: Text(
                    _seriesLine(issue),
                    style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 10),
              const HairLine(),
              const SizedBox(height: 18),
              Text(
                'これまで',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              for (final event in [...issue.events]..sort((a, b) => a.at.compareTo(b.at)))
                _Timeline(event: event, store: widget.store),
            ],
          ),
          bottomNavigationBar: _bottom(issue),
        );
      },
    );
  }

  /// 定期案件は前回・前々回がそのまま残る。これが数年で家の記録になる。
  String _seriesLine(Issue issue) {
    final history = widget.store.seriesHistory(issue.seriesKey);
    if (history.isEmpty) return '前回はまだ';
    final labels = <String>[];
    for (var i = 0; i < history.length && i < 2; i++) {
      final at = history[i].completedAt!;
      labels.add('${i == 0 ? '前回' : '前々回'} ${at.month}/${at.day}');
    }
    return labels.join('・');
  }

  PopupMenuButton<String> _menu(Issue issue) => PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz, size: 20),
        tooltip: 'そのほか',
        onSelected: (value) {
          switch (value) {
            case 'waiting':
              widget.store.setStatus(issue.id, IssueStatus.waiting);
            case 'open':
              widget.store.setStatus(issue.id, IssueStatus.open);
            case 'rename':
              _rename(issue);
            case 'link':
              _copyLink(issue);
            case 'delete':
              _confirmDelete(issue);
          }
        },
        itemBuilder: (context) => [
          if (issue.status != IssueStatus.waiting)
            const PopupMenuItem(value: 'waiting', child: Text('対応待ちにする')),
          if (issue.status != IssueStatus.open)
            const PopupMenuItem(value: 'open', child: Text('やることにもどす')),
          const PopupMenuItem(value: 'rename', child: Text('名前を直す')),
          if (widget.linkFor != null) const PopupMenuItem(value: 'link', child: Text('リンクを送る')),
          const PopupMenuItem(value: 'delete', child: Text('消す')),
        ],
      );

  /// アプリを入れていない相手に送る「1件リンク」。
  /// 相手はブラウザで開いて、中身を見て「やる」だけ押せる（アカウントもインストールも不要）。
  Future<void> _copyLink(Issue issue) async {
    final text = await widget.linkFor?.call(issue);
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('リンクをコピーしました。相手はブラウザで開けます')),
    );
  }

  Widget _bottom(Issue issue) {
    final scheme = Theme.of(context).colorScheme;
    // bottomNavigationBar はキーボードに押し上げられないので、高さぶん自分で持ち上げる。
    // （これが無いと「ひとこと」を押した途端、入力欄がキーボードの下に隠れる）
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _bottomBar(issue, scheme),
    );
  }

  Widget _bottomBar(Issue issue, ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _comment,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(issue),
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: 'ひとこと',
                    isDense: true,
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(999),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const ValueKey('detail-done'),
                onPressed: issue.isDone ? null : () => _complete(issue),
                icon: const Icon(Icons.check, size: 20),
                tooltip: 'おわった',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _send(Issue issue) {
    final text = _comment.text;
    if (text.trim().isEmpty) return;
    widget.store.comment(issue.id, text);
    _comment.clear();
  }

  void _complete(Issue issue) {
    widget.store.complete(issue.id);
    Navigator.of(context).maybePop();
  }

  /// 消すだけは取り消せない（完了と違って戻す操作が無い）。1回だけ確かめる。
  Future<void> _confirmDelete(Issue issue) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「${issue.title}」を消しますか？', style: const TextStyle(fontSize: 16)),
        content: const Text('これまでのやりとりも見えなくなります。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('やめる')),
          FilledButton(
            key: const ValueKey('confirm-delete'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('消す'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Navigator.of(context).pop();
    widget.store.remove(issue.id);
  }

  Future<void> _rename(Issue issue) async {
    final controller = TextEditingController(text: issue.title);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('名前を直す', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(ctx).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('やめる')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(controller.text), child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (result != null) widget.store.rename(issue.id, result);
  }

  Future<void> _pickAssignee(Issue issue) async {
    final value = await _chooseOne('だれが', [
      _Opt(label: 'だれでも', value: 'none', selected: issue.assigneeId == null),
      for (final m in widget.store.members)
        _Opt(label: m.name, value: m.id, selected: issue.assigneeId == m.id),
    ]);
    if (value == null) return;
    widget.store.setAssignee(issue.id, value == 'none' ? null : value);
  }

  Future<void> _pickDue(Issue issue) async {
    final today = widget.store.today;
    final value = await _chooseOne('いつまで', [
      _Opt(label: 'なし', value: 'none', selected: issue.dueDate == null),
      _Opt(label: '今日', value: 'today', selected: _sameDay(issue.dueDate, today)),
      _Opt(
        label: '明日',
        value: 'tomorrow',
        selected: _sameDay(issue.dueDate, DateTime(today.year, today.month, today.day + 1)),
      ),
      _Opt(label: '今週末', value: 'weekend', selected: false),
      const _Opt(label: '日付を選ぶ', value: 'pick', selected: false),
    ]);
    if (value == null) return;
    if (value == 'pick') {
      if (!mounted) return;
      final picked = await showDatePicker(
        context: context,
        initialDate: issue.dueDate ?? today,
        firstDate: DateTime(today.year - 1),
        lastDate: DateTime(today.year + 3),
        locale: const Locale('ja'),
      );
      if (picked == null) return;
      widget.store.setDue(issue.id, picked);
      return;
    }
    widget.store.setDue(issue.id, _resolveDue(value, today));
  }

  Future<void> _pickRecurrence(Issue issue) async {
    var days = <int>{...issue.recurrence.weekdays};
    final result = await showModalBottomSheet<Recurrence>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text('くりかえし', style: TextStyle(fontSize: 13, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              ),
              ListTile(
                dense: true,
                title: const Text('なし', style: TextStyle(fontSize: 15)),
                trailing: issue.recurrence.isNone ? const Icon(Icons.check, size: 18) : null,
                onTap: () => Navigator.of(ctx).pop(Recurrence.none),
              ),
              ListTile(
                dense: true,
                title: const Text('毎日', style: TextStyle(fontSize: 15)),
                trailing: issue.recurrence.kind == RecurrenceKind.daily ? const Icon(Icons.check, size: 18) : null,
                onTap: () => Navigator.of(ctx).pop(Recurrence.daily),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Text('毎週（曜日を選ぶ）', style: TextStyle(fontSize: 12.5, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final entry in Recurrence.weekdayNames.entries)
                      MiniChip(
                        label: entry.value,
                        selected: days.contains(entry.key),
                        onTap: () => setSheet(() {
                          if (!days.add(entry.key)) days.remove(entry.key);
                        }),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                child: TextButton(
                  onPressed: days.isEmpty ? null : () => Navigator.of(ctx).pop(Recurrence.onWeekdays(days)),
                  child: const Text('この曜日で毎週にする'),
                ),
              ),
              for (final n in const [7, 30, 60])
                ListTile(
                  dense: true,
                  title: Text('終わってから$n日ごと', style: const TextStyle(fontSize: 15)),
                  trailing: !issue.recurrence.isNone &&
                          issue.recurrence.kind == RecurrenceKind.everyDays &&
                          issue.recurrence.everyDays == n
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => Navigator.of(ctx).pop(Recurrence.every(n)),
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    widget.store.setRecurrence(issue.id, result);
  }

  DateTime? _resolveDue(String value, DateTime today) {
    switch (value) {
      case 'today':
        return today;
      case 'tomorrow':
        return DateTime(today.year, today.month, today.day + 1);
      case 'weekend':
        final diff = (DateTime.saturday - today.weekday) % 7;
        return DateTime(today.year, today.month, today.day + diff);
      default:
        return null;
    }
  }

  Future<String?> _chooseOne(String title, List<_Opt> options) => showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(title, style: TextStyle(fontSize: 13, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              ),
              for (final option in options)
                ListTile(
                  dense: true,
                  title: Text(
                    option.label,
                    style: TextStyle(fontSize: 15, fontWeight: option.selected ? FontWeight.w600 : FontWeight.w400),
                  ),
                  trailing: option.selected ? const Icon(Icons.check, size: 18) : null,
                  onTap: () => Navigator.of(ctx).pop(option.value),
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      );
}

bool _sameDay(DateTime? a, DateTime b) => a != null && a.year == b.year && a.month == b.month && a.day == b.day;

class _Opt {
  const _Opt({required this.label, required this.value, required this.selected});

  final String label;
  final String value;
  final bool selected;
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.event, required this.store});

  final IssueEvent event;
  final IssueStore store;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final actor = store.memberById(event.actorId)?.name;
    final muted = event.kind == EventKind.completed || event.kind == EventKind.reopened;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 42,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                timeLabel(event.at, store.now),
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(_icon(event.kind), size: 14, color: scheme.outline),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (event.kind != EventKind.photo)
                  Text(
                    event.text ?? '',
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.35,
                      color: muted ? scheme.onSurfaceVariant : scheme.onSurface,
                    ),
                  ),
                if (event.kind == EventKind.photo)
                  Container(
                    width: 132,
                    height: 96,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.image_outlined, size: 20, color: scheme.outline),
                        const SizedBox(height: 4),
                        Text('写真', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                if (actor != null && event.kind == EventKind.comment)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(actor, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _icon(EventKind kind) => switch (kind) {
        EventKind.created => Icons.add,
        EventKind.comment => Icons.chat_bubble_outline,
        EventKind.photo => Icons.photo_outlined,
        EventKind.assignee => Icons.person_outline,
        EventKind.due => Icons.event_outlined,
        EventKind.recurrence => Icons.repeat,
        EventKind.status => Icons.flag_outlined,
        EventKind.completed => Icons.check,
        EventKind.reopened => Icons.undo,
      };
}
