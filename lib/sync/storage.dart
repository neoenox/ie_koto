import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'log.dart';
import 'wire.dart';

/// 端末に残すもの（設計の手順1）。
///
/// opの列・端末id・送信済みの位置・同期の設定と、世帯名簿・旧ID対応・本人設定を残す。
/// 案件の射影は残さない。起動時に op と旧ID対応から作り直せばよい
/// （規則が1つで済むし、射影の形を変えても保存を壊さない）。
class SavedState {
  const SavedState({
    this.deviceId = '',
    this.ops = const <Op>[],
    this.pushedThrough = 0,
    this.sync,
    this.skippedOps = 0,
    this.meId = '',
    this.memberNames = const <String, String>{},
    this.memberAliases = const <String, String>{},
    this.pendingMemberNames = const <String, String>{},
    this.pendingRelayIds = const <String>{},
  });

  /// 前回の起動で決めた端末id。空なら初回。
  final String deviceId;

  /// 端末が持っているop（自分のも、もらったものも）。
  final List<Op> ops;

  /// サーバーが確認した、自分のopの最大の論理時計。
  /// これより後の自分のopが「まだ送っていないもの」になる。
  final int pushedThrough;

  /// 同期の設定。渡していなければ null（1人で使う形）。
  final SyncCredentials? sync;

  /// 読めなくて捨てたopの数（壊れた行）。
  final int skippedOps;

  /// この端末を使う人（member_id）。空なら未設定（'me'扱い）。
  final String meId;

  /// 最後に受け取ったメンバー名（member_id → 名前）。
  final Map<String, String> memberNames;
  final Map<String, String> memberAliases;
  final Map<String, String> pendingMemberNames;

  final Set<String> pendingRelayIds;
}

/// 同期に必要な設定。これが残っていれば、次からはビルド時に渡さなくてよい。
class SyncCredentials {
  const SyncCredentials({
    required this.baseUrl,
    required this.householdId,
    required this.token,
    this.cursor = 0,
  });

  final String baseUrl;
  final String householdId;
  final String token;

  /// 次にもらう位置（サーバー採番）。残しておけば、次の起動は差分だけで済む。
  final int cursor;

  SyncCredentials withCursor(int cursor) => SyncCredentials(
    baseUrl: baseUrl,
    householdId: householdId,
    token: token,
    cursor: cursor,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'baseUrl': baseUrl,
    'householdId': householdId,
    'token': token,
    'cursor': cursor,
  };

  /// 壊れていれば null（同期の設定が無いのと同じ扱い）。
  static SyncCredentials? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final baseUrl = raw['baseUrl'];
    final householdId = raw['householdId'];
    final token = raw['token'];
    final cursor = raw['cursor'];
    if (baseUrl is! String || baseUrl.isEmpty) return null;
    if (householdId is! String || householdId.isEmpty) return null;
    if (token is! String || token.isEmpty) return null;
    return SyncCredentials(
      baseUrl: baseUrl,
      householdId: householdId,
      token: token,
      cursor: cursor is num ? cursor.toInt() : 0,
    );
  }
}

/// 端末に残すものの置き場。読み書きは同期（起動時に読んで、あとは足すだけ）。
///
/// 置き場（端末）に1つのインスタンスを向けて使うこと。
/// 同じ置き場を2つのインスタンスで見ることは想定していない。
abstract class Storage implements Listenable {
  bool get isSaving;
  Object? get lastSaveError;
  Future<void> flush();

  /// 残しておいたものを読む。**アプリの起動時に1回だけ**呼ぶのが基本。
  /// （読み直しを避けるため、実装は最後に読んだ結果を覚えている）
  SavedState load();

  /// 増えたopを足す。**書き直さないし、消さない**（opは追記のみ）。
  /// 呼ぶ側が「まだ書いていないもの」だけを渡す。
  void appendOps(Iterable<Op> ops);

  void saveDeviceId(String deviceId);

  /// 送信済みの位置（自分のopの最大の論理時計）。
  void savePushedThrough(int lamport);

  void savePendingRelayIds(Set<String> ids);

  void saveSync(SyncCredentials credentials);

  /// この端末を使う人。
  void saveMeId(String meId);

  /// 表示名の上書き。
  void saveMemberNames(Map<String, String> names);
  void saveMemberAliases(Map<String, String> aliases);
  void savePendingMemberNames(Map<String, String> names);
}

/// 文字列だけを預けられる場所。
/// ふつうは [SharedPrefsStore]（Android は SharedPreferences、Web は localStorage）。
/// テストは Map で置き換える（test/support/memory_store.dart）。
abstract class KeyValueStore {
  String? read(String key);
  void write(String key, String? value);
}

/// 非同期保存先は、受付と永続化の完了を区別する。
abstract class AsyncKeyValueStore implements KeyValueStore {
  Future<void> writeConfirmed(String key, String? value);
}

class SharedPrefsStore implements AsyncKeyValueStore {
  SharedPrefsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SharedPrefsStore> open() async =>
      SharedPrefsStore(await SharedPreferences.getInstance());

  @override
  String? read(String key) => _prefs.getString(key);

  @override
  void write(String key, String? value) {
    unawaited(writeConfirmed(key, value));
  }

  @override
  Future<void> writeConfirmed(String key, String? value) async {
    final saved = await (value == null
        ? _prefs.remove(key)
        : _prefs.setString(key, value));
    if (!saved) throw StateError('端末に保存できません');
  }
}

/// 端末に本当に残す保存先。
///
/// opは **[chunkSize] 件ずつのまとまり**にして、1行1つのJSON（JSONL）で置く。
/// 足すときに触るのは「いま書いているまとまり」だけなので、**家のopが増えても
/// 1回の書き込みの重さは変わらない**（全件を書き直すと、数年後に1タップごとに
/// 数百ミリ秒かかる。実測は docs/VERIFICATION.md）。
///
/// まとまりの中は行ごとに読むので、壊れた行があってもその1行だけ捨てられる。
class DeviceStorage extends ChangeNotifier implements Storage {
  DeviceStorage(this._store) : _baseStore = _store, namespace = null;

  DeviceStorage._(this._baseStore, String namespace)
    : _store = _ScopedKeyValueStore(_baseStore, namespace),
      namespace = namespace;

  final KeyValueStore _baseStore;
  final String? namespace;

  /// Keep each household's operation log and local settings in a separate key space.
  DeviceStorage scoped(String namespace) {
    const migratedKey = 'ie_koto.household_scope_migrated';
    if (_baseStore.read(migratedKey) != 'true') {
      final scoped = _ScopedKeyValueStore(_baseStore, namespace);
      for (final key in [
        chunksKey,
        deviceKey,
        pushedKey,
        syncKey,
        meKey,
        membersKey,
        aliasesKey,
        pendingMembersKey,
        for (
          var i = 0;
          i < (int.tryParse(_baseStore.read(chunksKey) ?? '') ?? 0);
          i++
        )
          chunkKey(i),
      ]) {
        final value = _baseStore.read(key);
        if (value != null && scoped.read(key) == null) scoped.write(key, value);
      }
      _baseStore.write(migratedKey, 'true');
    }
    return DeviceStorage._(_baseStore, namespace);
  }

  /// 端末の置き場を開く（アプリの起動時に1回）。
  static Future<DeviceStorage> open() async =>
      DeviceStorage(await SharedPrefsStore.open());

  /// 1つのまとまりに入れるopの数。
  static const int chunkSize = 200;

  static const String opsPrefix = 'ie_koto.ops';
  static const String chunksKey = '$opsPrefix.chunks';
  static const String deviceKey = 'ie_koto.device_id';
  static const String pushedKey = 'ie_koto.pushed_through';
  static const String relayKey = 'ie_koto.pending_relay_ids';
  static const String syncKey = 'ie_koto.sync';
  static const String meKey = 'ie_koto.me_id';
  static const String membersKey = 'ie_koto.member_names';
  static const String aliasesKey = 'ie_koto.member_aliases';
  static const String pendingMembersKey = 'ie_koto.pending_members';

  static String chunkKey(int index) => '$opsPrefix.$index';

  final KeyValueStore _store;
  final Map<String, String?> _unconfirmed = {};
  Future<void>? _flushing;
  @override
  bool get isSaving => _flushing != null;
  @override
  Object? lastSaveError;

  void _write(String key, String? value) {
    _unconfirmed[key] = value;
    final base = _baseStore;
    if (base is AsyncKeyValueStore) {
      unawaited(flush());
    } else {
      try {
        _store.write(key, value);
        _unconfirmed.remove(key);
        if (_unconfirmed.isEmpty) lastSaveError = null;
      } catch (error) {
        lastSaveError = error;
      }
      notifyListeners();
    }
  }

  /// 未完了・失敗した書き込みを、順序を保って再試行する。
  @override
  Future<void> flush() {
    final running = _flushing;
    if (running != null) return running;
    if (_unconfirmed.isEmpty) return Future.value();
    final future = Future<void>.microtask(() async {
      try {
        while (_unconfirmed.isNotEmpty) {
          final entry = _unconfirmed.entries.first;
          final base = _baseStore;
          if (base is AsyncKeyValueStore) {
            final key = namespace == null
                ? entry.key
                : 'ie_koto.household.$namespace.${entry.key}';
            await base.writeConfirmed(key, entry.value);
          } else {
            _store.write(entry.key, entry.value);
          }
          if (_unconfirmed[entry.key] == entry.value) {
            _unconfirmed.remove(entry.key);
          }
        }
        lastSaveError = null;
      } catch (error) {
        lastSaveError = error;
      }
    });
    _flushing = future;
    notifyListeners();
    unawaited(
      future.whenComplete(() {
        _flushing = null;
        notifyListeners();
      }),
    );
    return future;
  }

  SavedState? _cached;
  String? _cachedFingerprint;
  int _chunks = 0;
  List<String> _tail = <String>[];

  /// 読み直しを避けつつ、別のインスタンスが書いたものも見落とさない
  /// （書き換わるのは「いま書いているまとまり」だけなので、そこだけ見れば足りる）。
  @override
  SavedState load() {
    final fingerprint = _fingerprint();
    final cached = _cached;
    if (cached != null && _cachedFingerprint == fingerprint) return cached;

    final state = _read();
    _cached = state;
    _cachedFingerprint = fingerprint;
    return state;
  }

  @override
  void appendOps(Iterable<Op> ops) {
    final fresh = ops.toList();
    if (fresh.isEmpty) return;

    var index = _chunks == 0 ? 0 : _chunks - 1;
    var lines = List<String>.of(_tail);
    for (final op in fresh) {
      if (lines.length >= chunkSize) {
        _write(chunkKey(index), lines.join('\n')); // いっぱいになったまとまりは書き切る
        index += 1;
        lines = <String>[];
      }
      lines.add(jsonEncode(encodeOp(op)));
    }
    _write(chunkKey(index), lines.join('\n'));
    _write(chunksKey, '${index + 1}');

    _chunks = index + 1;
    _tail = lines;
    _cached = null;
    _cachedFingerprint = null;
  }

  @override
  void saveDeviceId(String deviceId) {
    _write(deviceKey, deviceId);
    _cached = null;
    _cachedFingerprint = null;
  }

  @override
  void savePushedThrough(int lamport) {
    _write(pushedKey, '$lamport');
    _cached = null;
    _cachedFingerprint = null;
  }

  @override
  void savePendingRelayIds(Set<String> ids) {
    _write(relayKey, jsonEncode(ids.toList()..sort()));
    _cached = null;
    _cachedFingerprint = null;
  }

  @override
  void saveSync(SyncCredentials credentials) {
    _write(syncKey, jsonEncode(credentials.toJson()));
    _cached = null;
    _cachedFingerprint = null;
  }

  @override
  void saveMeId(String meId) {
    _write(meKey, meId);
    _cached = null;
    _cachedFingerprint = null;
  }

  @override
  void saveMemberNames(Map<String, String> names) {
    _write(membersKey, jsonEncode(names));
    _cached = null;
    _cachedFingerprint = null;
  }

  @override
  void saveMemberAliases(Map<String, String> aliases) {
    _write(aliasesKey, jsonEncode(aliases));
    _cached = null;
    _cachedFingerprint = null;
  }

  @override
  void savePendingMemberNames(Map<String, String> names) {
    _write(pendingMembersKey, jsonEncode(names));
    _cached = null;
    _cachedFingerprint = null;
  }

  /// 中身が変わったかどうかを、安い読み取りだけで見分けるための目印。
  String _fingerprint() {
    final chunks = _store.read(chunksKey) ?? '';
    final last = (int.tryParse(chunks) ?? 0) - 1;
    return <String>[
      chunks,
      if (last >= 0) _store.read(chunkKey(last)) ?? '',
      _store.read(deviceKey) ?? '',
      _store.read(pushedKey) ?? '',
      _store.read(relayKey) ?? '',
      _store.read(syncKey) ?? '',
      _store.read(meKey) ?? '',
      _store.read(membersKey) ?? '',
      _store.read(aliasesKey) ?? '',
      _store.read(pendingMembersKey) ?? '',
    ].join('|');
  }

  SavedState _read() {
    final chunks = int.tryParse(_store.read(chunksKey) ?? '') ?? 0;
    final raw = <Object?>[];
    var tail = <String>[];
    for (var index = 0; index < chunks; index++) {
      final lines = _lines(_store.read(chunkKey(index)));
      if (index == chunks - 1) tail = lines;
      for (final line in lines) {
        try {
          raw.add(jsonDecode(line));
        } catch (_) {
          raw.add(null); // 壊れた行は、その1行だけ捨てる
        }
      }
    }
    final decoded = decodeOps(raw);

    _chunks = chunks;
    _tail = tail;

    return SavedState(
      deviceId: _store.read(deviceKey) ?? '',
      ops: decoded.ops,
      pushedThrough: int.tryParse(_store.read(pushedKey) ?? '') ?? 0,
      pendingRelayIds: _readRelayIds(),
      sync: _readSync(),
      skippedOps: decoded.skipped,
      meId: _store.read(meKey) ?? '',
      memberNames: _readMemberNames(),
      memberAliases: _readStringMap(aliasesKey),
      pendingMemberNames: _readStringMap(pendingMembersKey),
    );
  }

  List<String> _lines(String? text) => <String>[
    for (final line in (text ?? '').split('\n'))
      if (line.trim().isNotEmpty) line,
  ];

  Set<String> _readRelayIds() {
    try {
      final raw = jsonDecode(_store.read(relayKey) ?? '[]');
      if (raw is! List) return <String>{};
      return raw.whereType<String>().where((id) => id.isNotEmpty).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  SyncCredentials? _readSync() {
    final raw = _store.read(syncKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return SyncCredentials.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _readMemberNames() {
    return _readStringMap(membersKey);
  }

  Map<String, String> _readStringMap(String key) {
    final raw = _store.read(key);
    if (raw == null || raw.isEmpty) return const <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, String>{};
      final out = <String, String>{};
      decoded.forEach((key, value) {
        if (key is String &&
            value is String &&
            key.isNotEmpty &&
            value.trim().isNotEmpty) {
          out[key] = value.trim();
        }
      });
      return out;
    } catch (_) {
      return const <String, String>{};
    }
  }
}

class _ScopedKeyValueStore implements KeyValueStore {
  _ScopedKeyValueStore(this.store, this.namespace);
  final KeyValueStore store;
  final String namespace;
  String _key(String key) => 'ie_koto.household.$namespace.$key';
  @override
  String? read(String key) => store.read(_key(key));
  @override
  void write(String key, String? value) => store.write(_key(key), value);
}
