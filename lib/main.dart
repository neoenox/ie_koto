import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'home_page.dart';
import 'household_sheet.dart';
import 'model.dart';
import 'one_link.dart';
import 'one_page.dart';
import 'store.dart';
import 'sync/api.dart';
import 'sync/config.dart';
import 'sync/session.dart';
import 'sync/setup.dart';
import 'sync/storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 相手がブラウザで開いた1件リンクなら、端末の保存は読まずに、その1件だけを出す。
  final oneLink = OneLink.fromUri(Uri.base);
  if (oneLink != null) {
    runApp(IeKotoApp(oneLink: oneLink));
    return;
  }

  // 端末に残したものを読む前に、Flutter の準備を整えておく。
  final storage = await DeviceStorage.open();
  runApp(IeKotoApp(storage: storage));
}

class IeKotoApp extends StatefulWidget {
  const IeKotoApp({super.key, this.store, this.storage, this.oneLink});

  /// 検証用に差し替えられるようにしておく（通常は触って確かめる用のデータで起動する）。
  final IssueStore? store;

  /// 端末の保存先（手順1）。渡さなければ保存しない（テスト用）。
  final Storage? storage;

  /// 相手がブラウザで開いた1件リンク。渡されたら、そのページだけを出す。
  final OneLink? oneLink;

  @override
  State<IeKotoApp> createState() => _IeKotoAppState();
}

class _IeKotoAppState extends State<IeKotoApp> with WidgetsBindingObserver {
  /// 端末に残しておいたものから開く（初回だけ、触って確かめる用のデータが入る）。
  late final IssueStore _store = widget.store ?? IssueStore.demo(storage: widget.storage);

  /// 同期（設計の手順3）。設定が無ければ null のまま＝1人で使う形。
  SyncSession? _session;

  /// いま使っている同期の設定（1件リンクを作るのにも使う）。
  SyncCredentials? _credentials;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.oneLink != null) return; // 1件リンクは、端末の保存も同期の設定も使わない

    // ビルド時に渡した設定（--dart-define）が最優先。無ければ端末に残しておいたものを使う。
    final credentials = SyncConfig.resolve(widget.storage);
    _startSession(credentials);
  }

  /// 同期を（再）開始する。設定がなければ1人で使う形のまま。
  void _startSession(SyncCredentials? credentials) {
    _session?.close();
    _session = null;
    _credentials = credentials;
    if (credentials == null) return;

    final api = SyncApi(
      baseUrl: credentials.baseUrl,
      householdId: credentials.householdId,
      token: credentials.token,
    );
    // 起動時に1回、送って・もらって・足りない「次の1件」を書く。
    // このあとは、自分が書いた直後だけ自動で送る（リアルタイム購読はしない）。
    // cursor も端末から戻すので、2回目以降は差分だけをもらう。
    final session = SyncSession(
      store: _store,
      api: api,
      storage: widget.storage,
      cursor: credentials.cursor,
    )..attach();
    _session = session;
    unawaited(_syncOnce(session));
  }

  /// 画面で決めた設定に切り替える。保存して、セッションを作り直して、すぐ同期する。
  void _applyHousehold(HouseholdResult result) {
    final saved = widget.storage?.load().sync;
    final credentials = HouseholdSetup.buildCredentials(
      baseUrl: result.baseUrl,
      householdId: result.householdId,
      token: result.token,
      saved: saved,
    );
    widget.storage?.saveSync(credentials);
    setState(() => _startSession(credentials));
  }

  /// つながりをやめる。端末の記録は残し、同期の設定だけ消す。
  void _leaveHousehold() {
    widget.storage?.saveSync(const SyncCredentials(baseUrl: '', householdId: '', token: '', cursor: 0));
    // 空の設定は「未接続」と同じ扱いにするため、保存した同期設定を消したものとして扱う。
    // DeviceStorage に削除APIが無いので、空文字で上書きしてから null として再開する。
    setState(() => _startSession(null));
  }

  /// トークンを作り直す。古いトークンで認証し、新しいトークンに置き換える。
  /// 成功したら新しいトークンを返す（招待文の送り直しに使う）。
  Future<String?> _rotateToken() async {
    final credentials = _credentials;
    if (credentials == null) return null;
    final repo = SyncApi(
      baseUrl: credentials.baseUrl,
      householdId: credentials.householdId,
      token: credentials.token,
    );
    final next = HouseholdSetup.newToken();
    try {
      await repo.rotateToken(next);
    } catch (_) {
      repo.close();
      return null;
    }
    repo.close();
    final updated = HouseholdSetup.buildCredentials(
      baseUrl: credentials.baseUrl,
      householdId: credentials.householdId,
      token: next,
      saved: null, // トークンが変わったので、cursorは0から取り直す
    );
    widget.storage?.saveSync(updated);
    setState(() => _startSession(updated));
    return next;
  }

  /// 世帯を消す。サーバーの記録が消え、端末の記録は残る。
  Future<bool> _deleteHousehold() async {
    final credentials = _credentials;
    if (credentials == null) return false;
    final repo = SyncApi(
      baseUrl: credentials.baseUrl,
      householdId: credentials.householdId,
      token: credentials.token,
    );
    try {
      await repo.deleteHousehold();
    } catch (_) {
      repo.close();
      return false;
    }
    repo.close();
    _leaveHousehold();
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final session = _session;
      if (session != null) unawaited(_syncOnce(session));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.close();
    super.dispose();
  }

  /// 届かなくても、アプリはそのまま使える（オフライン優先）。
  /// もらった結果、自分の担当になったものがあれば1件だけ知らせる。
  Future<void> _syncOnce(SyncSession session) async {
    final before = <String, String?>{
      for (final issue in _store.all) issue.id: issue.assigneeId,
    };
    try {
      await session.syncNow();
    } catch (_) {
      // session.lastError に残っている。次の同期でやり直す。
      return;
    }
    if (!mounted) return;
    final me = _store.meId;
    for (final issue in _store.all) {
      if (issue.isDone || issue.assigneeId != me) continue;
      if (before[issue.id] == me) continue;
      _messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('「${issue.title}」が自分の担当になった')),
      );
      break;
    }
  }

  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: _messengerKey,
      title: 'いえこと',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: _theme(),
      home: widget.oneLink == null
          ? HomePage(
              store: _store,
              linkFor: _credentials == null ? null : _linkFor,
              credentials: _credentials,
              onOpenHousehold: _openHousehold,
            )
          : OnePage(link: widget.oneLink!),
    );
  }

  /// ホームの世帯名から開く。決めた値は保存してセッションを作り直す。
  Future<void> _openHousehold(BuildContext context) async {
    final here = Uri.base;
    final onWeb = here.scheme == 'http' || here.scheme == 'https';
    final result = await showHouseholdSheet(
      context,
      current: _credentials,
      initialBaseUrl: onWeb ? here.origin : (_credentials?.baseUrl ?? ''),
      store: _store,
      onRotateToken: _credentials == null ? null : _rotateToken,
      onDeleteHousehold: _credentials == null ? null : _deleteHousehold,
    );
    if (!mounted) return;
    if (result is HouseholdResult) {
      _applyHousehold(result);
    } else if (result is HouseholdLeave) {
      _leaveHousehold();
    }
  }

  /// アプリを入れていない相手に送る「1件リンク」（docs/SYNC_DESIGN.md §2）。
  ///
  /// リンクを開くのは相手のブラウザなので、**アプリ（Webビルド）が乗っている場所**を使う。
  /// Webで動いているなら、いま開いているページのドメイン。Android からは、APIのドメイン
  /// （本番はアプリもAPIも同じドメインに置くので、そこがWeb版の場所でもある）。
  String? _linkFor(Issue issue) {
    final credentials = _credentials;
    if (credentials == null) return null;

    final here = Uri.base;
    final onWeb = here.scheme == 'http' || here.scheme == 'https';
    final baseUrl = onWeb ? here.origin : credentials.baseUrl;
    // 開発中はアプリとAPIのポートが違うので、APIの場所をリンクに書いておく。
    final apiUrl = baseUrl == credentials.baseUrl ? null : credentials.baseUrl;

    return OneLink(
      baseUrl: baseUrl,
      apiUrl: apiUrl,
      householdId: credentials.householdId,
      token: credentials.token,
      issueId: issue.id,
      // 送りっぱなしにしない。7日を過ぎたリンクは、開いてもただのアプリになる。
      expiresAt: DateTime.now().add(const Duration(days: 7)),
    ).text;
  }

  /// 落ち着いた配色。色で意味を持たせず、線と余白で区切る。
  ThemeData _theme() {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3F6F5F));
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFFBFAF7),
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFFFBFAF7),
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 20)),
      dividerTheme: const DividerThemeData(space: 1, thickness: 0.5),
    );
  }
}
