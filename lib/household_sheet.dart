import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'store.dart';
import 'sync/setup.dart';
import 'sync/storage.dart';

/// 世帯とつなげるためのシート。ホームの世帯名から開く。
///
/// - つながっていないとき: 「あたらしくつくる」「はいっている家にはいる」
/// - つながっているとき: いまの世帯を見せて、招待文のコピーと「つながりをやめる」
/// - いつでも: この端末を使う人と表示名（端末に残る。同期しない）
/// 保存は呼ばない。決めた設定を Navigator で返すだけ（保存と再接続は呼ぶ側）。
/// この端末の人・表示名・書出し/読込みは、その場で [store] に適用する。
class HouseholdSheet extends StatefulWidget {
  const HouseholdSheet({
    super.key,
    required this.current,
    this.initialBaseUrl = '',
    this.store,
    this.onRotateToken,
    this.onDeleteHousehold,
  });

  /// いま使っている設定。nullなら未接続。
  final SyncCredentials? current;

  /// Webで動いているときの初期値（開いているページのドメイン）。
  final String initialBaseUrl;

  /// 渡すと「この端末はだれ」・表示名・書出し/読込みを出せる。
  final IssueStore? store;

  /// トークン作り直し。成功したら新しいトークンを返す（失敗は null）。
  final Future<String?> Function()? onRotateToken;

  /// 世帯消し。成功したら true。
  final Future<bool> Function()? onDeleteHousehold;

  @override
  State<HouseholdSheet> createState() => _HouseholdSheetState();
}

enum _Mode { view, create, join }

class _HouseholdSheetState extends State<HouseholdSheet> {
  late _Mode _mode = _current == null ? _Mode.create : _Mode.view;

  final _base = TextEditingController();
  final _household = TextEditingController();
  final _token = TextEditingController();
  String? _error;
  late SyncCredentials? _current = widget.current;
  bool _rotatingToken = false;

  @override
  void initState() {
    super.initState();
    _base.text = _current?.baseUrl ?? widget.initialBaseUrl;
    _household.text = _current?.householdId ?? '';
    _token.text = _current?.token ?? '';
  }

  @override
  void dispose() {
    _base.dispose();
    _household.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 8,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Text(
              '家族とつなげる',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              _current == null ? 'いまはこの端末だけで使っています' : 'いまの家とつながっています',
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (_current == null) _tabs(),
            if (_mode == _Mode.view && _current != null)
              _currentView(_current!)
            else
              _form(),
            if (widget.store != null) ...[
              const SizedBox(height: 16),
              _meSection(widget.store!),
              const SizedBox(height: 8),
              _backupSection(widget.store!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tabs() {
    return Row(
      children: [
        ChoiceChip(
          label: const Text('あたらしくつくる'),
          selected: _mode != _Mode.join,
          onSelected: (_) => setState(() {
            _mode = _Mode.create;
            _error = null;
          }),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          label: const Text('はいっている家にはいる'),
          selected: _mode == _Mode.join,
          onSelected: (_) => setState(() {
            _mode = _Mode.join;
            _error = null;
          }),
        ),
      ],
    );
  }

  Widget _currentView(SyncCredentials current) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _line('場所', current.baseUrl),
        _line('世帯', current.householdId),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => _copyInvite(current),
                child: const Text('招待文をコピー'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(const HouseholdLeave()),
                child: const Text('つながりをやめる'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '招待文には場所・世帯・トークンが入ります。家族にだけ送ってください',
          style: TextStyle(
            fontSize: 11.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        _dangerSection(),
      ],
    );
  }

  /// トークン作り直しと世帯消し。どちらもサーバーに届く操作。
  Widget _dangerSection() {
    final rotate = widget.onRotateToken;
    final remove = widget.onDeleteHousehold;
    if (rotate == null && remove == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (rotate != null)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _rotatingToken ? null : () async {
                setState(() => _rotatingToken = true);
                String? token;
                try {
                  token = await rotate();
                } catch (_) {
                  token = null;
                }
                if (!mounted) return;
                setState(() {
                  _rotatingToken = false;
                  if (token != null) {
                    final current = _current!;
                    _current = SyncCredentials(
                      baseUrl: current.baseUrl,
                      householdId: current.householdId,
                      token: token,
                      cursor: 0,
                    );
                    _token.text = token;
                  }
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      token == null ? '作り直せませんでした。つながりを確認してください' : 'トークンを作り直しました。招待文を送り直してください',
                    ),
                  ),
                );
              },
              child: Text(_rotatingToken ? '作り直しています…' : 'トークンを作り直す'),
            ),
          ),
        if (remove != null)
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () async {
                final ok = await _confirmDelete();
                if (!ok) return;
                final deleted = await remove();
                if (!mounted) return;
                if (deleted) {
                  Navigator.of(context).pop(const HouseholdLeave());
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('消せませんでした。つながりを確認してください')),
                  );
                }
              },
              child: const Text('世帯を消す'),
            ),
          ),
        Text(
          'トークンを作り直すと古い招待文は使えなくなります。世帯を消しても端末の記録は残ります',
          style: TextStyle(fontSize: 11.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Future<bool> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('世帯を消しますか？', style: TextStyle(fontSize: 16)),
        content: const Text('サーバーの記録が消えます。端末の記録は残ります。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('やめる')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('消す')),
        ],
      ),
    );
    return ok == true;
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _form() {
    final creating = _mode == _Mode.create;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!creating || _current != null) const SizedBox(height: 8),
        TextField(
          controller: _base,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '場所（APIのURL）',
            hintText: 'https://…',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        if (!creating) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _household,
            decoration: const InputDecoration(
              labelText: '世帯id',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _token,
            decoration: const InputDecoration(
              labelText: 'トークン',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ] else ...[
          const SizedBox(height: 8),
          Text(
            'つくると世帯idとトークンを自動で決めます。この端末に残り、最初の同期で家が作られます',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            onPressed: creating ? _create : _join,
            child: Text(creating ? 'つくる' : 'はいる'),
          ),
        ),
      ],
    );
  }

  void _create() {
    final baseUrl = HouseholdSetup.normalizeBaseUrl(_base.text);
    if (baseUrl == null) {
      setState(() => _error = '場所は http(s)://… で入れてください');
      return;
    }
    Navigator.of(context).pop(
      HouseholdResult(
        baseUrl: baseUrl,
        householdId: HouseholdSetup.newHouseholdId(),
        token: HouseholdSetup.newToken(),
      ),
    );
  }

  void _join() {
    final baseUrl = HouseholdSetup.normalizeBaseUrl(_base.text);
    if (baseUrl == null) {
      setState(() => _error = '場所は http(s)://… で入れてください');
      return;
    }
    final hError = HouseholdSetup.validateHouseholdId(_household.text);
    if (hError != null) {
      setState(() => _error = hError);
      return;
    }
    final tError = HouseholdSetup.validateToken(_token.text);
    if (tError != null) {
      setState(() => _error = tError);
      return;
    }
    Navigator.of(context).pop(
      HouseholdResult(
        baseUrl: baseUrl,
        householdId: _household.text.trim(),
        token: _token.text.trim(),
      ),
    );
  }

  Future<void> _copyInvite(SyncCredentials current) async {
    final text =
        '場所 ${current.baseUrl}\n世帯 ${current.householdId}\nトークン ${current.token}';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('招待文をコピーしました。「はいっている家にはいる」に入れてください')),
    );
  }

  /// この端末を使う人と表示名。端末に残る（同期しない）。
  Widget _meSection(IssueStore store) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'この端末はだれ',
            style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final m in store.members)
                ChoiceChip(
                  label: Text(m.name),
                  selected: store.meId == m.id,
                  onSelected: (_) {
                    store.setMeId(m.id);
                    setState(() {});
                  },
                ),
            ],
          ),
          for (final m in store.members)
            _nameRow(store, m.id, m.name),
        ],
      ),
    );
  }

  Widget _nameRow(IssueStore store, String id, String name) {
    final controller = TextEditingController(text: name);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(id, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
              onSubmitted: (value) {
                store.renameMember(id, value);
                setState(() {});
              },
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: () {
              store.renameMember(id, controller.text);
              setState(() {});
            },
            child: const Text('直す'),
          ),
        ],
      ),
    );
  }

  /// 記録の引っ越し。書き出したJSONを別の端末で読み込む。
  Widget _backupSection(IssueStore store) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '記録の引っ越し',
          style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: store.exportJson()));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('記録をコピーしました。新しい端末で読み込んでください')),
                  );
                },
                child: const Text('書き出す'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _importDialog(store),
                child: const Text('読み込む'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _importDialog(IssueStore store) async {
    final controller = TextEditingController();
    final pasted = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('記録を読み込む', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '書き出したJSONを貼る',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('やめる')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(controller.text), child: const Text('読む')),
        ],
      ),
    );
    controller.dispose();
    if (pasted == null || pasted.trim().isEmpty) return;
    try {
      final fresh = store.importJson(pasted);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(fresh == 0 ? '新しい記録はありませんでした' : '$fresh件の記録を読み込みました')),
      );
      setState(() {});
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('読めませんでした。書き出したものをそのまま貼ってください')),
      );
    }
  }
}

/// シートで決めた値。保存と再接続は呼ばない（呼ぶ側がやる）。
class HouseholdResult {
  const HouseholdResult({
    required this.baseUrl,
    required this.householdId,
    required this.token,
  });

  final String baseUrl;
  final String householdId;
  final String token;
}

/// 「つながりをやめる」が選ばれた合図。
class HouseholdLeave {
  const HouseholdLeave();
}

Future<Object?> showHouseholdSheet(
  BuildContext context, {
  required SyncCredentials? current,
  String initialBaseUrl = '',
  IssueStore? store,
  Future<String?> Function()? onRotateToken,
  Future<bool> Function()? onDeleteHousehold,
}) {
  return showModalBottomSheet<Object?>(
    context: context,
    showDragHandle: false,
    isScrollControlled: true,
    builder: (_) => HouseholdSheet(
      current: current,
      initialBaseUrl: initialBaseUrl,
      store: store,
      onRotateToken: onRotateToken,
      onDeleteHousehold: onDeleteHousehold,
    ),
  );
}
