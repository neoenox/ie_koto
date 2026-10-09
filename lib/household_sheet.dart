import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'join_link.dart';
import 'store.dart';
import 'sync/setup.dart';
import 'sync/storage.dart';

/// 世帯とつなげるためのシート。ホームの世帯名から開く。
///
/// - つながっていないとき: 「あたらしくつくる」「はいっている家にはいる」
/// - つながっているとき: いまの世帯を見せて、招待文のコピーと「つながりをやめる」
/// - いつでも: この端末を使う人と世帯のメンバー名
/// 保存は呼ばない。決めた設定を Navigator で返すだけ（保存と再接続は呼ぶ側）。
/// この端末の人・表示名・書出し/読込みは、その場で [store] に適用する。
class HouseholdSheet extends StatefulWidget {
  const HouseholdSheet({
    super.key,
    required this.current,
    this.initialBaseUrl = '',
    this.initialJoin,
    this.store,
    this.onRotateToken,
    this.onDeleteHousehold,
  });

  /// いま使っている設定。nullなら未接続。
  final SyncCredentials? current;

  /// Webで動いているときの初期値（開いているページのドメイン）。
  final String initialBaseUrl;

  /// 参加リンクから開いたときの3値。あれば「はいる」側に自動で入れる。
  final JoinLink? initialJoin;

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
  final _baseFocus = FocusNode();
  final _householdFocus = FocusNode();
  final _tokenFocus = FocusNode();
  String? _baseError;
  String? _householdError;
  String? _tokenError;
  late SyncCredentials? _current = widget.current;
  bool _rotatingToken = false;

  @override
  void initState() {
    super.initState();
    final join = widget.initialJoin;
    // 未接続で参加リンクから開いたときだけ、3値を「はいる」側に入れる。
    if (join != null && _current == null) {
      _mode = _Mode.join;
      _base.text = join.apiBaseUrl;
      _household.text = join.householdId;
      _token.text = join.token;
    } else {
      _base.text = _current?.baseUrl ?? widget.initialBaseUrl;
      _household.text = _current?.householdId ?? '';
      _token.text = _current?.token ?? '';
    }
  }

  @override
  void dispose() {
    _base.dispose();
    _household.dispose();
    _token.dispose();
    _baseFocus.dispose();
    _householdFocus.dispose();
    _tokenFocus.dispose();
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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          label: const Text('あたらしくつくる'),
          selected: _mode != _Mode.join,
          onSelected: (_) => setState(() {
            _mode = _Mode.create;
            _clearErrors();
          }),
        ),
        ChoiceChip(
          label: const Text('はいっている家にはいる'),
          selected: _mode == _Mode.join,
          onSelected: (_) => setState(() {
            _mode = _Mode.join;
            _clearErrors();
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
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => _copyInvite(current),
            child: const Text('招待文をコピー'),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => _confirmLeave(),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('つながりをやめる'),
          ),
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
        _inviteSection(current),
        const SizedBox(height: 12),
        _dangerSection(),
      ],
    );
  }

  /// 参加リンクとQR。写すだけ・開くだけで参加欄まで進める。
  /// トークンはURLの断片に載せる（サーバーに送られない）。
  Widget _inviteSection(SyncCredentials current) {
    final appBase = widget.initialBaseUrl.isNotEmpty
        ? widget.initialBaseUrl
        : current.baseUrl;
    final link = JoinLink(
      baseUrl: appBase,
      apiUrl: appBase == current.baseUrl ? null : current.baseUrl,
      householdId: current.householdId,
      token: current.token,
    ).text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SheetCaption(text: '家族をよぶ'),
        Center(
          child: QrImageView(
            data: link,
            size: 160,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => _copyInviteLink(link),
            child: const Text('招待リンクをコピー'),
          ),
        ),
      ],
    );
  }

  Future<void> _copyInviteLink(String link) async {
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('招待リンクをコピーしました。開くと参加欄に自動で入ります')),
    );
  }

  /// トークン作り直しと世帯消し。どちらもサーバーに届く操作なので折りたたむ。
  Widget _dangerSection() {
    final rotate = widget.onRotateToken;
    final remove = widget.onDeleteHousehold;
    if (rotate == null && remove == null) return const SizedBox.shrink();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
        'トークン・削除',
        style: TextStyle(
          fontSize: 12.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (rotate != null)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _rotatingToken
                      ? null
                      : () async {
                          // 作り直すと古い招待文が使えなくなる不可逆操作。1回確かめる。
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text(
                                'トークンを作り直しますか？',
                                style: TextStyle(fontSize: 16),
                              ),
                              content: const Text(
                                '古い招待文・招待リンクは使えなくなります。家族に送り直してください。',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(false),
                                  child: const Text('つづける'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                  child: const Text('作り直す'),
                                ),
                              ],
                            ),
                          );
                          if (ok != true || !mounted) return;
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
                                token == null
                                    ? '作り直せませんでした。つながりを確認してください'
                                    : 'トークンを作り直しました。招待文を送り直してください',
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
                        const SnackBar(
                          content: Text('削除できませんでした。つながりを確認してください'),
                        ),
                      );
                    }
                  },
                  child: const Text('世帯を削除'),
                ),
              ),
            Text(
              'トークンを作り直すと古い招待文は使えなくなります。世帯を削除しても端末の記録は残ります',
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<bool> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('世帯を削除しますか？', style: TextStyle(fontSize: 16)),
        content: const Text('サーバーの記録が消えます。端末の記録は残ります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// つながりをやめると同期が止まり、戻るには3つの入れ直しが要る。1回だけ確かめる。
  Future<void> _confirmLeave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('つながりをやめますか？', style: TextStyle(fontSize: 16)),
        content: const Text('家族との同期が止まります。端末の記録は残ります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('つづける'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('やめる'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Navigator.of(context).pop(const HouseholdLeave());
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

  /// 欄の見出しは上に置く（枠に重ねるフローティング表示は使わない）。
  Widget _caption(String text) => _SheetCaption(text: text);

  void _clearErrors() {
    _baseError = null;
    _householdError = null;
    _tokenError = null;
  }

  Widget _form() {
    final creating = _mode == _Mode.create;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!creating || _current != null) const SizedBox(height: 8),
        _caption('場所（APIのURL）'),
        TextField(
          controller: _base,
          focusNode: _baseFocus,
          keyboardType: TextInputType.url,
          onChanged: (_) {
            if (_baseError != null) setState(() => _baseError = null);
          },
          decoration: InputDecoration(
            hintText: 'https://…',
            isDense: true,
            border: const OutlineInputBorder(),
            errorText: _baseError,
          ),
        ),
        if (!creating) ...[
          const SizedBox(height: 10),
          _caption('世帯id'),
          TextField(
            controller: _household,
            focusNode: _householdFocus,
            onChanged: (_) {
              if (_householdError != null) {
                setState(() => _householdError = null);
              }
            },
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: _householdError,
            ),
          ),
          const SizedBox(height: 10),
          _caption('トークン'),
          TextField(
            controller: _token,
            focusNode: _tokenFocus,
            onChanged: (_) {
              if (_tokenError != null) setState(() => _tokenError = null);
            },
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: _tokenError,
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
        if (_baseError != null ||
            _householdError != null ||
            _tokenError != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              '入力を確認してください',
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
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
      setState(() => _baseError = '場所は http(s)://… で入れてください');
      _baseFocus.requestFocus();
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
    final hError = HouseholdSetup.validateHouseholdId(_household.text);
    final tError = HouseholdSetup.validateToken(_token.text);
    if (baseUrl == null || hError != null || tError != null) {
      setState(() {
        _baseError = baseUrl == null ? '場所は http(s)://… で入れてください' : null;
        _householdError = hError;
        _tokenError = tError;
      });
      // 最初に直す欄へ移動する。
      if (baseUrl == null) {
        _baseFocus.requestFocus();
      } else if (hError != null) {
        _householdFocus.requestFocus();
      } else {
        _tokenFocus.requestFocus();
      }
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

  /// この端末を使う人の選択と、世帯で共有する名前。
  Widget _meSection(IssueStore store) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'この端末を使う人',
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _addMember(store),
              icon: const Icon(Icons.person_add_alt_1, size: 18),
              label: const Text('人を追加'),
            ),
          ),
          for (final m in store.members) _nameRow(store, m.id, m.name),
        ],
      ),
    );
  }

  Widget _nameRow(IssueStore store, String id, String name) {
    final isSelf =
        store.canonicalMemberId(id) == store.canonicalMemberId(store.meId);
    if (!isSelf) return _otherRow(store, id, name);
    return _MemberNameField(
      key: ValueKey(id),
      name: name,
      label: '$nameの表示名',
      onSave: (value) {
        if (!store.renameMember(id, value)) {
          final trimmed = IssueStore.normalizeMemberName(value);
          if (trimmed.isEmpty) return '名前を入力してください';
          if (IssueStore.isReservedMemberName(trimmed)) {
            return '「自分」「パートナー」は使えません。なまえ等を入れてください';
          }
          return '自分の名前だけ変えられます';
        }
        return null;
      },
    );
  }

  /// 他人の行は名前を変えられない。重複の解消（まとめる・はずす）だけできる。
  Widget _otherRow(IssueStore store, String id, String name) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SheetCaption(text: '$nameの表示名'),
          Row(
            children: [
              Expanded(child: Text(name, style: const TextStyle(fontSize: 15))),
              TextButton(
                onPressed: () => _mergeMember(store, id, name),
                child: const Text('まとめる'),
              ),
              TextButton(
                onPressed: () => _removeMember(store, id, name),
                child: const Text('はずす'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _mergeMember(IssueStore store, String id, String name) async {
    final others = [
      for (final m in store.members)
        if (store.canonicalMemberId(m.id) != store.canonicalMemberId(id)) m,
    ];
    if (others.isEmpty) return;
    final into = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('「$name」をだれにまとめる？', style: const TextStyle(fontSize: 16)),
        children: [
          for (final m in others)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(m.id),
              child: Text(m.id == store.meId ? '自分' : m.name),
            ),
        ],
      ),
    );
    if (!mounted || into == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('まとめてもいいですか？', style: TextStyle(fontSize: 16)),
        content: Text('「$name」の担当・履歴は残したまま、1人にまとめます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('まとめる'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!store.mergeMembers(id, into)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('まとめられませんでした')));
      return;
    }
    setState(() {});
  }

  Future<void> _removeMember(IssueStore store, String id, String name) async {
    if (store.hasOpenAssignment(id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「$name」は未完了の担当があるため外せません。先に担当を変えてください')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('名簿から外しますか？', style: TextStyle(fontSize: 16)),
        content: Text('「$name」を名簿から外します。これまでの履歴は残ります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('外す'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!store.removeMember(id)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('外せませんでした')));
      return;
    }
    setState(() {});
  }

  Future<void> _addMember(IssueStore store) async {
    final controller = TextEditingController();
    String? error;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (ctx, setDialog) {
          void submit() {
            final trimmed = IssueStore.normalizeMemberName(controller.text);
            if (trimmed.isEmpty) {
              setDialog(() => error = '名前を入力してください');
              return;
            }
            if (IssueStore.isReservedMemberName(trimmed)) {
              setDialog(() => error = '「自分」「パートナー」は使えません。なまえ等を入れてください');
              return;
            }
            Navigator.of(ctx).pop(controller.text);
          }

          return AlertDialog(
            title: const Text('人を追加'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SheetCaption(text: '名前'),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLength: 80,
                  decoration: InputDecoration(
                    hintText: '例：あき',
                    errorText: error,
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('やめる'),
              ),
              FilledButton(onPressed: submit, child: const Text('この名前で入れる')),
            ],
          );
        },
      ),
    );
    // popのアニメーション中に破棄するとTextFieldが壊れるため、破棄しない。
    if (!mounted || name == null) return;
    try {
      store.addMember(name);
    } on ArgumentError {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('名前を確認してください')));
    }
    setState(() {});
  }

  /// 記録の引っ越し。書き出したJSONを別の端末で読み込む。
  Widget _backupSection(IssueStore store) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '記録の引っ越し',
          style: TextStyle(
            fontSize: 12.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: store.exportJson()),
                  );
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
        const SizedBox(height: 6),
        Text(
          '端末への保存が失敗し続けるときは、ここから記録を書き出して保管してください。',
          style: TextStyle(
            fontSize: 12.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetCaption(text: '書き出した記録'),
            TextField(
              controller: controller,
              maxLines: 5,
              minLines: 3,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: '書き出したJSONを貼る',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('読み込む'),
          ),
        ],
      ),
    );
    // popのアニメーション中に破棄するとTextFieldが壊れるため、破棄しない。
    if (pasted == null || pasted.trim().isEmpty) return;
    try {
      final fresh = store.importJson(pasted);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(fresh == 0 ? '新しい記録はありませんでした' : '$fresh件の記録を読み込みました'),
        ),
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

/// メンバーごとに入力を保持し、別の入力欄へ移ったときにも保存する。
class _MemberNameField extends StatefulWidget {
  const _MemberNameField({
    super.key,
    required this.name,
    required this.label,
    required this.onSave,
  });

  final String name;
  final String label;

  /// 保存を試み、だめなら理由を返す。nullなら保存できた。
  final String? Function(String) onSave;

  @override
  State<_MemberNameField> createState() => _MemberNameFieldState();
}

class _MemberNameFieldState extends State<_MemberNameField> {
  late final _controller = TextEditingController(text: widget.name);
  final _focus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) _save();
  }

  void _save() {
    final error = widget.onSave(_controller.text);
    if (!mounted) return;
    setState(() => _error = error);
  }

  @override
  void didUpdateWidget(covariant _MemberNameField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && oldWidget.name != widget.name) {
      _controller.text = widget.name;
      _error = null;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SheetCaption(text: widget.label),
        TextField(
          controller: _controller,
          focusNode: _focus,
          maxLength: 80,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            counterText: '',
            errorText: _error,
          ),
          onSubmitted: (_) => _save(),
          onTapOutside: (_) => _focus.unfocus(),
        ),
      ],
    ),
  );
}

/// 状態を持たない見出し。枠に重ねるフローティング表示は使わない。
class _SheetCaption extends StatelessWidget {
  const _SheetCaption({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
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
  JoinLink? initialJoin,
  IssueStore? store,
  Future<String?> Function()? onRotateToken,
  Future<bool> Function()? onDeleteHousehold,
}) {
  return showModalBottomSheet<Object?>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => HouseholdSheet(
      current: current,
      initialBaseUrl: initialBaseUrl,
      initialJoin: initialJoin,
      store: store,
      onRotateToken: onRotateToken,
      onDeleteHousehold: onDeleteHousehold,
    ),
  );
}
