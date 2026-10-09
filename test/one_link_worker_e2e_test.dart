import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ie_koto/one_link.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/log.dart';
import 'package:ie_koto/sync/session.dart';

import 'support/worker_server.dart';

/// 通しの確認: **アプリを入れていない相手**が、送られてきた1件リンクをブラウザで開いて
/// 「やる」を押すと、持ち主のアプリに伝わる。**本物の Worker + SQLite に実HTTPで。**
///
/// 相手のブラウザがやることを、[OnePage](../lib/one_page.dart) と同じ手順で再現する:
///   リンクを読む → その1件だけもらう → 「やる」（担当のopを書く）→ 送る。
/// 世帯idとトークンは、端末に保存する値（保存は手順1）。ここでは固定。
const String household = 'hh_e2e0000000000000000000000000000';
const String token = 'e2e-token-e2e-token-e2e-token-e2e-token-e2e';

void main() {
  test(
    '相手がリンクで「やる」を押すと、持ち主に伝わる（世帯のほかの中身は漏れない）',
    () async {
      final worker = await WorkerServer.start();
      if (worker == null) return markTestSkipped('node が無いので飛ばす');
      addTearDown(worker.stop);

      // 持ち主（アプリ入り）が3件作って送る。
      final owner = _store('devA');
      final ownerSession = _session(owner, worker.baseUrl);
      final paper = owner.add(
        title: 'トイレットペーパーを買う',
        dueDate: DateTime(2026, 10, 6),
      );
      owner.add(title: '車のオイル交換');
      owner.add(title: '保育園の書類');
      owner.comment(paper.id, '低脂肪ので');
      await ownerSession.syncNow();

      // 送るのは、この1件のリンク1本。世帯トークンは断片に入っている（サーバーのログには残らない）。
      final link = OneLink(
        baseUrl: worker.baseUrl,
        householdId: household,
        token: token,
        issueId: paper.id,
        memberId: owner.canonicalMemberId('partner'),
      );
      final opened = OneLink.fromUri(Uri.parse(link.text));
      expect(opened, isNotNull);

      // 相手のブラウザ: アプリを入れておらず、端末にも何も残さない（保存を渡さない）。
      final guest = _store('guest1');
      expect(guest.storage, isNull, reason: '相手のブラウザに世帯の記録を置かない');
      final guestApi = SyncApi(
        baseUrl: opened!.baseUrl,
        householdId: opened.householdId,
        token: opened.token,
        issueId: opened.issueId,
      );
      addTearDown(guestApi.close);
      final guestSession = SyncSession(store: guest, api: guestApi);

      await guestSession.syncNow();

      // 相手に見えるのは1件だけ。しかも、その1件の中身（ひとこと含む）は読める。
      expect(guest.all.map((issue) => issue.title), <String>['トイレットペーパーを買う']);
      expect(guest.byId(paper.id)!.dueDate, DateTime(2026, 10, 6));
      expect(guest.byId(paper.id)!.assigneeId, isNull);
      expect(
        guest.byId(paper.id)!.events.map((event) => event.text),
        contains('低脂肪ので'),
      );
      expect(guest.outbox, isEmpty, reason: 'もらったopを、送り返さない');

      // 生の応答にも、世帯のほかの案件は1文字も入っていない。
      final raw = await _rawPull(worker.baseUrl, household, token, paper.id);
      expect(raw, contains('トイレットペーパー'));
      expect(raw, isNot(contains('オイル')));
      expect(raw, isNot(contains('保育園')));

      // 「やる」を押す（担当のopを1つ書いて、その場で送る）。
      guest.setAssignee(paper.id, opened.memberId);
      await guestSession.pushNow();
      expect(guest.outbox, isEmpty);

      // 持ち主が次に開くと、担当が変わっている。
      await ownerSession.syncNow();
      expect(
        owner.byId(paper.id)!.assigneeId,
        owner.canonicalMemberId(opened.memberId),
      );
      expect(
        guest.byId(paper.id)!.assigneeId,
        owner.byId(paper.id)!.assigneeId,
      );
      expect(owner.assigneeWord(owner.byId(paper.id)!.assigneeId), 'パートナー');
      expect(
        owner.byId(paper.id)!.events.map((event) => event.text),
        contains('パートナーが担当になった'),
      );

      // 送れなくて「もう一度」を押したときと同じ動きでは、担当のopは増えない。
      expect(
        guest.byId(paper.id)!.assigneeId,
        opened.memberId,
        reason: '押し直しても書かずに送り直す',
      );
      await guestSession.pushNow();
      expect(guest.outbox, isEmpty);

      await ownerSession.syncNow();
      expect(owner.ops.where((op) => op.kind == OpKind.assignee), hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '同じリンクを2人が開いて「やる」を押しても、世帯みんなが同じ担当になる',
    () async {
      final worker = await WorkerServer.start();
      if (worker == null) return markTestSkipped('node が無いので飛ばす');
      addTearDown(worker.stop);

      final owner = _store('devA');
      final ownerSession = _session(owner, worker.baseUrl);
      final bath = owner.add(title: 'お風呂そうじ', dueDate: DateTime(2026, 10, 6));
      await ownerSession.syncNow();

      // 2人（たとえば夫と、別居の親）が、同じリンクをそれぞれ自分のブラウザで開く。
      final first = _store('guest1');
      final second = _store('guest2');
      final sessions = <SyncSession>[];
      for (final guest in <IssueStore>[first, second]) {
        final api = SyncApi(
          baseUrl: worker.baseUrl,
          householdId: household,
          token: token,
          issueId: bath.id,
        );
        addTearDown(api.close);
        sessions.add(SyncSession(store: guest, api: api));
      }

      // 2人がほぼ同時に開いて、それぞれ「やる」を押す。
      await Future.wait(sessions.map((session) => session.syncNow()));
      for (final guest in <IssueStore>[first, second]) {
        guest.setAssignee(bath.id, 'partner');
      }
      await Future.wait(sessions.map((session) => session.pushNow()));

      // 持ち主が取りに行くと、2つとも届いている。
      await ownerSession.syncNow();
      expect(owner.ops.where((op) => op.kind == OpKind.assignee), hasLength(2));

      // もう一度みんな取り直すと、同じ1つの答えにそろう（順序は全端末で同じ決まり）。
      await Future.wait(sessions.map((session) => session.syncNow()));
      await ownerSession.syncNow();
      for (final store in <IssueStore>[owner, first, second]) {
        expect(store.byId(bath.id)!.assigneeId, isNotNull);
        expect(store.assigneeWord(store.byId(bath.id)!.assigneeId), 'パートナー');
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// 相手のブラウザが投げるのと同じ1本のGET（生の応答を見るため）。
Future<String> _rawPull(
  String baseUrl,
  String householdId,
  String token,
  String issueId,
) async {
  final uri = Uri.parse('$baseUrl/ops').replace(
    queryParameters: <String, String>{
      'household': householdId,
      'since': '0',
      'issue': issueId,
    },
  );
  final response = await http.get(
    uri,
    headers: <String, String>{'authorization': 'Bearer $token'},
  );
  expect(response.statusCode, 200);
  return utf8.decode(response.bodyBytes);
}

IssueStore _store(String deviceId) =>
    IssueStore(deviceId: deviceId, clock: () => DateTime(2026, 10, 6, 8));

SyncSession _session(IssueStore store, String baseUrl) => SyncSession(
  store: store,
  api: SyncApi(baseUrl: baseUrl, householdId: household, token: token),
);
