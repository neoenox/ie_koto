import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/config.dart';
import 'package:ie_koto/sync/log.dart';
import 'package:ie_koto/sync/session.dart';
import 'package:ie_koto/sync/storage.dart';
import 'package:ie_koto/sync/wire.dart';

import 'support/memory_store.dart';
import 'support/ops_server.dart';

/// 保存（設計の手順1）。閉じても消えないこと、開き直しても番号が衝突しないこと。
///
/// 「開き直す」は、同じ [MemoryStore] をもう1つ [DeviceStorage] で包み直して作る
/// （アプリを終了して、また起動したのと同じ）。
void main() {
  late MemoryStore device;
  late DeviceStorage storage;

  setUp(() {
    device = MemoryStore();
    storage = DeviceStorage(device);
  });

  DeviceStorage reopen() => DeviceStorage(device);

  test('書いたものは、閉じても残る（画面も同じに見える）', () {
    final store = IssueStore(deviceId: 'A', clock: _clock, storage: storage);
    final bath = store.add(
      title: 'お風呂そうじ',
      dueDate: DateTime(2026, 10, 6),
      recurrence: Recurrence.daily,
    );
    store.comment(bath.id, 'カビが気になる');
    store.complete(bath.id);
    final before = _view(store);
    expect(before, isNotEmpty);

    final reopened = IssueStore(clock: _clock, storage: reopen());
    expect(_view(reopened), before);
    expect(reopened.deviceId, 'A');
    expect(reopened.openedSeries(), isNotEmpty, reason: '定期の連なりも残る');
  });

  test('端末idは、一度決めたら変わらない', () {
    IssueStore(deviceId: 'A', clock: _clock, storage: storage);
    expect(storage.load().deviceId, 'A');

    // 次に別のidを渡しても、端末に残っている方が使われる（opのidが変わらないように）。
    final reopened = IssueStore(deviceId: 'B', clock: _clock, storage: reopen());
    expect(reopened.deviceId, 'A');
  });

  test('開き直しても、番号は続きから書く（opのidが衝突しない）', () {
    final store = IssueStore(deviceId: 'A', clock: _clock, storage: storage);
    store.add(title: '牛乳を買う');
    store.add(title: '子供の靴を買う');
    final ids = store.ops.map((op) => op.id).toSet();
    expect(ids, <String>{'A:1', 'A:2'});

    final reopened = IssueStore(clock: _clock, storage: reopen());
    final added = reopened.add(title: '廊下の電球を交換する');

    final all = reopened.ops.map((op) => op.id).toList();
    expect(all.toSet().length, all.length, reason: '同じidが2つない');
    expect(ids.contains(added.id), isFalse, reason: '前に使ったidを使い回していない');
    expect(added.id, 'A:3');
  });

  test('送信待ちは、確認できていない自分のopだけ', () {
    final store = IssueStore(deviceId: 'A', clock: _clock, storage: storage);
    store.add(title: '牛乳を買う');
    store.add(title: '子供の靴を買う');
    store.markSent(store.outbox); // 2件とも送れた
    store.add(title: '廊下の電球を交換する');
    store.receive(<Op>[
      Op(deviceId: 'B', lamport: 1, kind: OpKind.add, issueId: 'B:1', at: DateTime(2026, 10, 6, 9), data: <String, Object?>{'title': '相手が足したもの'}),
    ]);

    final reopened = IssueStore(clock: _clock, storage: reopen());
    expect(reopened.outbox.map((op) => op.id), <String>['A:3'], reason: '確認済みと、相手のopは送らない');
    expect(reopened.all.map((issue) => issue.title), contains('相手が足したもの'));
  });

  test('デモは初回だけ。2回目は、残しておいたものを開く', () {
    final demo = IssueStore.demo(clock: _clock, storage: storage);
    final seeded = demo.all.length;
    expect(seeded, greaterThan(5));
    demo.add(title: 'あとから足したもの');

    final reopened = IssueStore.demo(clock: _clock, storage: reopen());
    expect(reopened.all.map((issue) => issue.title), contains('あとから足したもの'));
    expect(reopened.all.length, seeded + 1, reason: 'デモを入れ直していない');
  });

  test('壊れた行があっても、読めるものだけ戻る', () {
    final kept = Op(deviceId: 'A', lamport: 1, kind: OpKind.add, issueId: 'A:1', at: DateTime(2026, 10, 6), data: <String, Object?>{'title': '残るもの'});
    final unknown = <String, Object?>{
      'id': 'A:2',
      'deviceId': 'A',
      'lamport': 2,
      'kind': 'future_kind',
      'issueId': 'A:1',
      'at': '2026-10-06T08:00:00.000',
      'data': <String, Object?>{},
    };
    device.write(DeviceStorage.chunkKey(0), <String>[jsonEncode(encodeOp(kept)), '{こわれている', jsonEncode(unknown)].join('\n'));
    device.write(DeviceStorage.chunksKey, '1');
    device.write(DeviceStorage.deviceKey, 'A');

    final saved = reopen().load();
    expect(saved.ops.map((op) => op.id), <String>['A:1']);
    expect(saved.skippedOps, 2, reason: '壊れた行と、知らない種類は捨てる');

    final store = IssueStore(clock: _clock, storage: reopen());
    expect(store.all.single.title, '残るもの');
  });

  test('保存が空でも、これまでどおり動く（保存を渡さない形と同じ）', () {
    final store = IssueStore(deviceId: 'dev', clock: _clock);
    store.add(title: '牛乳を買う');
    expect(store.all.single.title, '牛乳を買う');
    expect(store.ops.map((op) => op.id), <String>['dev:1']);
  });

  group('同期の設定', () {
    test('ビルド時に渡した設定が優先。無ければ、端末に残したものを使う', () {
      expect(
        SyncConfig.resolve(storage, baseUrl: '', household: '', token: ''),
        isNull,
        reason: '渡していないし、保存も無いなら同期しない',
      );

      final given = SyncConfig.resolve(
        storage,
        baseUrl: 'http://127.0.0.1:8799/',
        household: 'hh_wagaya00000000000000000000000000',
        token: 'token-token-token-token-token-token-token-token',
      )!;
      expect(given.baseUrl, 'http://127.0.0.1:8799', reason: '末尾の / は落とす');
      expect(given.cursor, 0);

      // 端末に残ったものは、渡さなければそのまま使われる。
      DeviceStorage(device).saveSync(given.withCursor(42));
      final remembered = SyncConfig.resolve(storage, baseUrl: '', household: '', token: '')!;
      expect(remembered.householdId, given.householdId);
      expect(remembered.token, given.token);
      expect(remembered.cursor, 42, reason: '次は差分だけをもらえる');
    });

    test('同じ設定を渡し直しても、cursorは残る（世帯が変われば0から）', () {
      const url = 'http://127.0.0.1:8799';
      const home = 'hh_wagaya00000000000000000000000000';
      const token = 'token-token-token-token-token-token-token-token';
      DeviceStorage(device).saveSync(const SyncCredentials(baseUrl: url, householdId: home, token: token, cursor: 42));

      final same = SyncConfig.resolve(storage, baseUrl: url, household: home, token: token)!;
      expect(same.cursor, 42);

      final other = SyncConfig.resolve(
        storage,
        baseUrl: url,
        household: 'hh_betsuno0000000000000000000000000',
        token: token,
      )!;
      expect(other.cursor, 0, reason: '別の世帯の位置を指したままにしない');
    });
  });

  test('同期の設定とcursorも残るので、次は差分だけをもらう', () async {
    final server = OpsServer();
    await server.start();
    addTearDown(server.stop);

    final store = IssueStore(deviceId: 'A', clock: _clock, storage: storage);
    final session = SyncSession(store: store, api: _api(server), storage: storage);
    store.add(title: '牛乳を買う');
    final first = await session.syncNow();
    expect(first.sent, 1);

    final saved = reopen().load();
    expect(saved.sync, isNotNull, reason: '世帯とトークンとcursorを残す');
    expect(saved.sync!.cursor, server.cursor);
    expect(saved.sync!.householdId, _household);

    // 開き直して、保存してある設定のまま同期する。
    final again = IssueStore(clock: _clock, storage: reopen());
    final remembered = SyncConfig.resolve(reopen())!;
    final reopenedSession = SyncSession(
      store: again,
      api: _api(server),
      storage: reopen(),
      cursor: remembered.cursor,
    );
    final outcome = await reopenedSession.syncNow();

    expect(outcome.received, 0, reason: 'cursorを覚えているので、同じopをもらい直さない');
    expect(outcome.sent, 0, reason: '送信済みのopを送り直さない');
    expect(outcome.empty, isTrue);
    expect(_view(again), _view(store));
  });

  test('5000件のときの、1回の書き込みと書き出しの重さ', () {
    final ops = <Op>[
      for (var i = 1; i <= 5000; i++)
        Op(
          deviceId: i.isEven ? 'B' : 'A',
          lamport: i,
          kind: i % 5 == 0 ? OpKind.complete : OpKind.comment,
          issueId: 'A:1',
          at: DateTime(2026, 10, 6).add(Duration(minutes: i)),
          data: <String, Object?>{'text': 'メモ$i'},
        ),
    ];
    final watchProject = Stopwatch()..start();
    project(ops);
    watchProject.stop();

    final watchWrite = Stopwatch()..start();
    storage.appendOps(ops);
    watchWrite.stop();

    device.write(DeviceStorage.deviceKey, 'A');
    final watchOpen = Stopwatch()..start();
    final store = IssueStore(clock: _clock, storage: reopen());
    watchOpen.stop();

    final watchAdd = Stopwatch()..start();
    store.add(title: '牛乳を買う');
    watchAdd.stop();

    final bytes = <String, String>{...device.values}.entries
        .where((entry) => entry.key.startsWith(DeviceStorage.opsPrefix))
        .fold<int>(0, (sum, entry) => sum + entry.value.length);
    debugPrint('5000op(${bytes ~/ 1024}KB / ${device.values[DeviceStorage.chunksKey]}まとまり): '
        '射影${watchProject.elapsedMilliseconds}ms / 初回の保存${watchWrite.elapsedMilliseconds}ms / '
        '読み込み${watchOpen.elapsedMilliseconds}ms / 1件追加${watchAdd.elapsedMilliseconds}ms');

    // 環境で変わるので、桁だけ見る（実測値は docs/VERIFICATION.md）。
    expect(watchAdd.elapsedMilliseconds, lessThan(1000));
    expect(bytes, lessThan(2 * 1024 * 1024));
  });
}

DateTime _clock() => DateTime(2026, 10, 6, 8);

SyncApi _api(OpsServer server) => SyncApi(
      baseUrl: server.baseUrl,
      householdId: _household,
      token: server.token,
    );

const String _household = 'hh_test00000000000000000000000';

/// 画面に出ているものの要約。これが一致すれば、同じに見えている。
Map<String, String> _view(IssueStore store) => <String, String>{
      for (final issue in store.all)
        issue.id: <String>[
          issue.title,
          issue.status.name,
          issue.dueDate?.toIso8601String() ?? '-',
          issue.recurrence.label,
          issue.assigneeId ?? '-',
          issue.events.where((event) => event.kind == EventKind.comment).map((event) => event.text).join(','),
        ].join('|'),
    };

extension on IssueStore {
  /// 定期案件の連なり（系列）がある数。開き直しても残っているかを見るため。
  Iterable<String> openedSeries() => all.map((issue) => issue.seriesKey).toSet();
}
