import 'package:flutter/material.dart';

import 'model.dart';
import 'store.dart';
import 'sync/log.dart';
import 'widgets.dart';

enum _When { none, today, tomorrow, weekend }

/// 追加は3秒。開いて、打って、Enter。
/// 担当と期限は押さなくても登録できる。押した場合は次の追加にも引き継ぐ。
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.store,
    this.onAdded,
    this.compact = false,
  });

  final bool compact;

  final IssueStore store;

  /// 追加直後に呼ばれる。入れたものが見えるように一覧を送るため。
  final ValueChanged<Issue>? onAdded;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _open = false;
  bool _showTitleError = false;
  String? _assigneeId;
  _When _when = _When.none;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _openComposer() {
    setState(() => _open = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _close() {
    _focus.unfocus();
    setState(() {
      _open = false;
      _showTitleError = false;
    });
  }

  DateTime? _dueDate() {
    final t = widget.store.today;
    switch (_when) {
      case _When.none:
        return null;
      case _When.today:
        return t;
      case _When.tomorrow:
        return DateTime(t.year, t.month, t.day + 1);
      case _When.weekend:
        final diff = (DateTime.saturday - t.weekday) % 7;
        return DateTime(t.year, t.month, t.day + diff);
    }
  }

  void _submit() {
    final title = _text.text.trim();
    if (title.isEmpty) {
      setState(() => _showTitleError = true);
      _focus.requestFocus();
      return;
    }
    late Issue issue;
    try {
      issue = widget.store.add(
        title: title,
        assigneeId: _assigneeId,
        dueDate: _dueDate(),
      );
    } on ClockExhaustedException catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }
    _text.clear();
    _focus.requestFocus();
    widget.onAdded?.call(issue);
    setState(() => _showTitleError = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.8),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: _open ? _opened(scheme) : _closed(scheme),
      ),
    );
  }

  Widget _closed(ColorScheme scheme) => InkWell(
    onTap: _openComposer,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Row(
        children: [
          Icon(Icons.add, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          const Text(
            '追加',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );

  Widget _opened(ColorScheme scheme) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('composer-field'),
                controller: _text,
                focusNode: _focus,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                onChanged: (value) {
                  if (_showTitleError && value.trim().isNotEmpty) {
                    setState(() => _showTitleError = false);
                  }
                },
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  labelText: 'やること',
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  hintText: '例：牛乳を買う',
                  errorText: _showTitleError ? 'やることを入力してください' : null,
                  filled: true,
                  fillColor: scheme.surfaceContainerLow,
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(minimumSize: const Size(72, 48)),
              child: const Text('追加'),
            ),
            IconButton(
              onPressed: _close,
              icon: const Icon(Icons.close, size: 22),
              tooltip: 'とじる',
            ),
          ],
        ),
        // Keep the title and submit controls usable above a tall Android IME.
        // Existing assignee/due selections survive while these controls fold.
        if (!widget.compact) ...[
          const SizedBox(height: 10),
          _row('だれ', [
            MiniChip(
              label: 'だれでも',
              selected: _assigneeId == null,
              onTap: () => setState(() => _assigneeId = null),
            ),
            for (final m in widget.store.members)
              MiniChip(
                label: widget.store.memberLabel(m.id)!,
                selected: _assigneeId == m.id,
                onTap: () => setState(() => _assigneeId = m.id),
              ),
          ]),
          const SizedBox(height: 6),
          _row('いつ', [
            MiniChip(
              label: 'なし',
              selected: _when == _When.none,
              onTap: () => setState(() => _when = _When.none),
            ),
            MiniChip(
              label: '今日',
              selected: _when == _When.today,
              onTap: () => setState(() => _when = _When.today),
            ),
            MiniChip(
              label: '明日',
              selected: _when == _When.tomorrow,
              onTap: () => setState(() => _when = _When.tomorrow),
            ),
            MiniChip(
              label: '今週末',
              selected: _when == _When.weekend,
              onTap: () => setState(() => _when = _When.weekend),
            ),
          ]),
        ],
      ],
    ),
  );

  Widget _row(String label, List<Widget> chips) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      SizedBox(
        width: 40,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      Expanded(child: Wrap(spacing: 6, runSpacing: 6, children: chips)),
    ],
  );
}
