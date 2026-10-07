import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/notices.dart';
import 'package:ie_koto/one_link.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/log.dart';
import 'package:ie_koto/sync/setup.dart';
import 'package:ie_koto/sync/storage.dart';
import 'package:ie_koto/sync/wire.dart';

import 'support/memory_store.dart';

/// 世帯参加UIの下支え（生成・検証・cursor引継ぎ）。
/// サーバー側の約束（server/src/index.js）と一致することを見る。
void main() {
  test('つくった世帯idとトークンはサーバーの形を満たす', () {
    final random = Random(20261006);
    for (var i = 0; i < 50; i++) {
      final id = HouseholdSetup.newHouseholdId(random);
      final token = HouseholdSetup.newToken(random);
      expect(HouseholdSetup.householdPattern.hasMatch(id), isTrue, reason: id);
      expect(token.length, greaterThanOrEqualTo(32));
      expect(RegExp(r'\s').hasMatch(token), isFalse);
    }
    // 毎回違うものが出る（推測できない乱数であること）。
    final ids = <String>{for (var i = 0; i < 20; i++) HouseholdSetup.newHouseholdId()};
    expect(ids, hasLength(20));
  });

  test('場所はhttp(s)だけ受け付ける', () {
    expect(HouseholdSetup.normalizeBaseUrl('https://example.workers.dev/'), 'https://example.workers.dev');
    expect(HouseholdSetup.normalizeBaseUrl('http://127.0.0.1:8799'), 'http://127.0.0.1:8799');
    expect(HouseholdSetup.normalizeBaseUrl('ftp://example.com'), isNull);
    expect(HouseholdSetup.normalizeBaseUrl('example.com'), isNull);
    expect(HouseholdSetup.normalizeBaseUrl(''), isNull);
  });

  test('欠けた入力は理由とともに断る', () {
    expect(HouseholdSetup.validateHouseholdId(''), isNotNull);
    expect(HouseholdSetup.validateHouseholdId('short'), isNotNull);
    expect(HouseholdSetup.validateHouseholdId('hh_abcdefghijklmnopqrstuv'), isNull);
    expect(HouseholdSetup.validateToken(''), isNotNull);
    expect(HouseholdSetup.validateToken('short'), isNotNull);
    expect(HouseholdSetup.validateToken('8f3c1d5e7a9b2c4d6e8f0a1b3c5d7e9f2a4b6c8d0e'), isNull);
  });

  test('同じ世帯ならcursorを引き継ぎ、変わったら0に戻す', () {
    const saved = SyncCredentials(
      baseUrl: 'https://example.workers.dev',
      householdId: 'hh_abcdefghijklmnopqrstuv',
      token: '8f3c1d5e7a9b2c4d6e8f0a1b3c5d7e9f2a4b6c8d0e',
      cursor: 18,
    );
    final same = HouseholdSetup.buildCredentials(
      baseUrl: saved.baseUrl,
      householdId: saved.householdId,
      token: saved.token,
      saved: saved,
    );
    expect(same.cursor, 18);

    final other = HouseholdSetup.buildCredentials(
      baseUrl: saved.baseUrl,
      householdId: 'hh_xxxxxxxxxxxxxxxxxxxxxx',
      token: saved.token,
      saved: saved,
    );
    expect(other.cursor, 0);
  });

  test('書いた人はopに残り、JSONを往復しても消えない', () {
    final op = Op(
      deviceId: 'A',
      lamport: 1,
      kind: OpKind.comment,
      issueId: 'A:1',
      at: DateTime(2026, 10, 6, 9),
      data: <String, Object?>{'text': '管理会社に電話した'},
      memberId: 'partner',
    );
    final back = decodeOp(Map<Object?, Object?>.from(encodeOp(op)));
    expect(back?.memberId, 'partner');
    // 古いop（書いた人が無い）は null のまま読める。
    final legacy = Map<Object?, Object?>.from(encodeOp(op))..remove('member');
    expect(decodeOp(legacy)?.memberId, isNull);
  });

  test('履歴の「だれが」は書いた人になる（全部「自分」にならない）', () {
    final a = IssueStore(deviceId: 'A', clock: () => DateTime(2026, 10, 6, 8));
    final milk = a.add(title: '牛乳を買う');
    a.setMeId('partner');
    a.comment(milk.id, '管理会社に電話した');

    final b = IssueStore(deviceId: 'B', clock: () => DateTime(2026, 10, 6, 8));
    b.receive(a.ops);

    final comments = b.byId(milk.id)!.events.where((e) => e.kind == EventKind.comment).toList();
    expect(comments, hasLength(1));
    expect(comments.single.actorId, 'partner');
    expect(b.memberById(comments.single.actorId)?.name, 'パートナー');
    expect(b.byId(milk.id)!.reporterId, 'me', reason: '追加したopの書いた人が残る');
  });

  test('この端末の人と表示名は端末に残る', () {
    final kv = MemoryStore();
    final first = IssueStore(storage: DeviceStorage(kv), deviceId: 'A');
    first.setMeId('partner');
    first.renameMember('partner', 'あいぼう');

    final second = IssueStore(storage: DeviceStorage(kv), deviceId: 'Z');
    expect(second.deviceId, 'A', reason: '端末idは残っている方を使う');
    expect(second.meId, 'partner');
    expect(second.memberById('partner')?.name, 'あいぼう');
  });

  test('1件リンクは期限を過ぎると読まない', () {
    const base = OneLink(
      baseUrl: 'https://example.workers.dev',
      householdId: 'hh_abcdefghijklmnopqrstuv',
      token: '8f3c1d5e7a9b2c4d6e8f0a1b3c5d7e9f2a4b6c8d0e',
      issueId: 'A:1',
    );
    final now = DateTime(2026, 10, 6, 8);
    final dated = OneLink(
      baseUrl: base.baseUrl,
      householdId: base.householdId,
      token: base.token,
      issueId: base.issueId,
      expiresAt: now.add(const Duration(days: 7)),
    );
    // 期限付きは往復する。期限なし（古いリンク）も読める。
    expect(OneLink.fromUri(Uri.parse(dated.text), now: now)?.issueId, 'A:1');
    expect(OneLink.fromUri(Uri.parse(base.text), now: now)?.issueId, 'A:1');
    // 過ぎたら読まない。壊れた期限も読まない。
    expect(OneLink.fromUri(Uri.parse(dated.text), now: now.add(const Duration(days: 8))), isNull);
    final broken = dated.text.replaceAll(RegExp(r'e=\d+'), 'e=not-a-time');
    expect(OneLink.fromUri(Uri.parse(broken), now: now), isNull);
  });

  test('お知らせは1行だけ（すぎたもの・今日の自分）', () {
    final store = IssueStore(deviceId: 'A', clock: () => DateTime(2026, 10, 6, 8));
    expect(noticeLineFor(store), isNull, reason: 'なければ行を出さない');
    final milk = store.add(title: '牛乳を買う', dueDate: DateTime(2026, 10, 5));
    expect(noticeLineFor(store), contains('すぎているものが1件'));
    store.setAssignee(milk.id, 'me');
    expect(noticeLineFor(store), contains('今日の自分は1件'));
  });

  test('記録を書き出して別の端末で読み込める', () {
    final a = IssueStore(deviceId: 'A', clock: () => DateTime(2026, 10, 6, 8));
    a.add(title: '牛乳を買う');
    a.add(title: '子供の靴を買う');

    final b = IssueStore(deviceId: 'B', clock: () => DateTime(2026, 10, 6, 8));
    expect(b.importJson(a.exportJson()), 2);
    expect(b.all.map((i) => i.title), containsAll(['牛乳を買う', '子供の靴を買う']));
    expect(b.importJson(a.exportJson()), 0, reason: '二重に読んでも増えない');
  });

  test('おわったものは新しい順に探せる', () {
    var now = DateTime(2026, 10, 6, 8);
    final store = IssueStore(deviceId: 'A', clock: () => now);
    final first = store.add(title: '古い方');
    now = DateTime(2026, 10, 6, 9);
    final second = store.add(title: '新しい方');
    store.complete(first.id);
    now = DateTime(2026, 10, 6, 10);
    store.complete(second.id);
    expect(store.doneHistory.map((i) => i.id), [second.id, first.id]);
  });
}
