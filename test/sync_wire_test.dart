import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/sync/log.dart';
import 'package:ie_koto/sync/wire.dart';

/// opのwire形式。実際にJSONを通して確かめる（サーバーを往復する形そのもの）。
void main() {
  test('範囲外の論理時計は読み飛ばして端末時計を汚染しない', () {
    Map<String, Object?> raw(int clock) => encodeOp(
      Op(
        deviceId: 'remote',
        lamport: clock,
        kind: OpKind.add,
        issueId: 'remote:$clock',
        at: DateTime(2026, 10, 9),
        data: {'title': '境界'},
      ),
    );
    final decoded = decodeOps([raw(1), raw(2147483648), raw(9007199254740992)]);
    expect(decoded.skipped, 2);
    expect(decoded.ops, hasLength(1));
    final device = Device('local')..receive(decoded.ops);
    final first = device.write(
      OpKind.comment,
      'remote:1',
      data: {'text': '確認'},
    );
    final second = device.write(
      OpKind.comment,
      'remote:1',
      data: {'text': '続き'},
    );
    expect(first.lamport, 2);
    expect(second.lamport, 3);
    expect(first.id, isNot(second.id));
    expect(decodeOp(raw(2147483647)), isNotNull);
  });
  test('不正な既知項目を持つopを射影前に捨てる', () {
    final base = encodeOp(
      Op(
        deviceId: 'A',
        lamport: 1,
        kind: OpKind.add,
        issueId: 'A:1',
        at: DateTime(2026, 10, 6),
        data: {'title': '買い物'},
      ),
    );
    final broken = [
      {
        ...base,
        'data': {'title': '買い物', 'assigneeId': 42},
      },
      {...base, 'kind': 'rename', 'data': <String, Object?>{}},
      {
        ...base,
        'data': {'title': '買い物', 'seriesId': false},
      },
      {
        ...base,
        'data': {'title': '買い物', 'dueDate': 'invalid'},
      },
      {...base, 'derivedFrom': 42},
      {...base, 'member': <String>[]},
      {
        ...base,
        'data': {
          'title': '買い物',
          'recurrence': {
            'kind': 'weekdays',
            'weekdays': [8],
          },
        },
      },
    ];
    expect(decodeOps(broken).ops, isEmpty);
    expect(decodeOps(broken).skipped, broken.length);
  });
  test('追加のopは、そのまま往復する', () {
    final op = Op(
      deviceId: 'A',
      lamport: 1,
      kind: OpKind.add,
      issueId: 'A:1',
      at: DateTime(2026, 10, 6, 8, 30, 15, 250),
      data: <String, Object?>{
        'title': 'エアコンのフィルターそうじ',
        'assigneeId': 'partner',
        'dueDate': DateTime(2026, 10, 9),
        'recurrence': Recurrence.every(60),
        'seriesId': 'A:1',
      },
    );

    final back = _roundTrip(op);
    expect(back.id, 'A:1');
    expect(back.deviceId, 'A');
    expect(back.lamport, 1);
    expect(back.kind, OpKind.add);
    expect(back.issueId, 'A:1');
    expect(back.at, DateTime(2026, 10, 6, 8, 30, 15, 250));
    expect(back.data['title'], 'エアコンのフィルターそうじ');
    expect(back.data['assigneeId'], 'partner');
    expect(back.data['dueDate'], DateTime(2026, 10, 9));
    expect((back.data['recurrence'] as Recurrence).label, '終わってから60日ごと');
    expect(back.data['seriesId'], 'A:1');
    expect(back.derivedFrom, isNull);
  });

  test('種類ごとの項目が、そのまま往復する', () {
    final ops = <Op>[
      Op(
        deviceId: 'B',
        lamport: 1,
        kind: OpKind.add,
        issueId: 'B:1',
        at: DateTime(2026, 10, 1),
        data: <String, Object?>{
          'title': 'ゴミ出し',
          'recurrence': Recurrence.onWeekdays(const <int>{
            DateTime.tuesday,
            DateTime.friday,
          }),
        },
      ),
      Op(
        deviceId: 'B',
        lamport: 2,
        kind: OpKind.rename,
        issueId: 'B:1',
        at: DateTime(2026, 10, 2),
        data: <String, Object?>{'title': 'ゴミ出し（資源）'},
      ),
      Op(
        deviceId: 'B',
        lamport: 3,
        kind: OpKind.assignee,
        issueId: 'B:1',
        at: DateTime(2026, 10, 2),
        data: <String, Object?>{'assigneeId': null},
      ),
      Op(
        deviceId: 'B',
        lamport: 4,
        kind: OpKind.due,
        issueId: 'B:1',
        at: DateTime(2026, 10, 2),
        data: <String, Object?>{'dueDate': null},
      ),
      Op(
        deviceId: 'B',
        lamport: 5,
        kind: OpKind.recurrence,
        issueId: 'B:1',
        at: DateTime(2026, 10, 2),
        data: <String, Object?>{
          'recurrence': Recurrence.every(30, fromCompletion: false),
        },
      ),
      Op(
        deviceId: 'B',
        lamport: 6,
        kind: OpKind.status,
        issueId: 'B:1',
        at: DateTime(2026, 10, 2),
        data: <String, Object?>{'status': IssueStatus.waiting},
      ),
      Op(
        deviceId: 'B',
        lamport: 7,
        kind: OpKind.comment,
        issueId: 'B:1',
        at: DateTime(2026, 10, 2),
        data: <String, Object?>{'text': '管理会社に電話した'},
      ),
      Op(
        deviceId: 'B',
        lamport: 8,
        kind: OpKind.complete,
        issueId: 'B:1',
        at: DateTime(2026, 10, 3),
      ),
      Op(
        deviceId: 'B',
        lamport: 9,
        kind: OpKind.reopen,
        issueId: 'B:1',
        at: DateTime(2026, 10, 3),
      ),
      Op(
        deviceId: 'B',
        lamport: 10,
        kind: OpKind.delete,
        issueId: 'B:1',
        at: DateTime(2026, 10, 3),
      ),
    ];

    final back = decodeOps(jsonDecode(jsonEncode(encodeOps(ops))));
    expect(back.skipped, 0);
    expect(back.ops.map((op) => op.kind), OpKind.values);
    expect(back.ops.map((op) => op.id), ops.map((op) => op.id));
    expect(back.ops.map((op) => op.issueId), ops.map((op) => op.issueId));

    final weekdays = back.ops[0].data['recurrence'] as Recurrence;
    expect(weekdays.label, '毎週 火・金');
    expect(back.ops[2].data['assigneeId'], isNull);
    expect(back.ops[3].data['dueDate'], isNull);
    final every = back.ops[4].data['recurrence'] as Recurrence;
    expect(every.label, '30日ごと');
    expect(every.fromCompletion, isFalse);
    expect(back.ops[5].data['status'], IssueStatus.waiting);
    expect(back.ops[6].data['text'], '管理会社に電話した');
  });

  test('自動生成された「次の1件」は、元になった完了opを持って往復する', () {
    final op = Op(
      deviceId: 'A',
      lamport: 3,
      kind: OpKind.add,
      issueId: 'next:A:2',
      at: DateTime(2026, 10, 7),
      data: <String, Object?>{
        'title': 'お風呂そうじ',
        'seriesId': 'A:1',
        'originIssueId': 'A:1',
      },
      derivedFrom: 'A:2',
    );
    final back = _roundTrip(op);
    expect(back.derivedFrom, 'A:2');
    expect(back.data['originIssueId'], 'A:1');
    expect(back.issueId, nextIssueId('A:2'));
  });

  test('時刻はUTCに直さず、そのままの壁時計で書く', () {
    final encoded = encodeOp(
      Op(
        deviceId: 'A',
        lamport: 1,
        kind: OpKind.add,
        issueId: 'A:1',
        at: DateTime(2026, 10, 6, 8, 0),
        data: <String, Object?>{'title': '牛乳'},
      ),
    );
    final at = encoded['at'] as String;
    expect(at, '2026-10-06T08:00:00.000');
    expect(at.contains('Z'), isFalse, reason: '端末の時計は、そのままの壁時計として渡す');
    expect(decodeTime(at), DateTime(2026, 10, 6, 8, 0));
  });

  test('知らない種類のopは、投げずに捨てる', () {
    final raw = <Object?>[
      <String, Object?>{
        'id': 'A:1',
        'deviceId': 'A',
        'lamport': 1,
        'kind': 'future_thing',
        'issueId': 'A:1',
        'at': '2026-10-06T08:00:00.000',
        'data': <String, Object?>{},
      },
      encodeOp(
        Op(
          deviceId: 'A',
          lamport: 2,
          kind: OpKind.comment,
          issueId: 'A:1',
          at: DateTime(2026, 10, 6, 9),
          data: <String, Object?>{'text': 'メモ'},
        ),
      ),
    ];
    final decoded = decodeOps(raw);
    expect(decoded.ops, hasLength(1));
    expect(decoded.skipped, 1);
  });

  test('壊れたopは捨てる（1件のせいで同期全体を止めない）', () {
    Map<String, Object?> base = <String, Object?>{
      'id': 'A:1',
      'deviceId': 'A',
      'lamport': 1,
      'kind': 'add',
      'issueId': 'A:1',
      'at': '2026-10-06T08:00:00.000',
      'data': <String, Object?>{'title': '牛乳'},
    };

    final broken = <Object?>[
      <String, Object?>{...base, 'id': 'A:99'}, // idが端末id:論理時計と合わない
      <String, Object?>{...base, 'deviceId': 42},
      <String, Object?>{...base, 'lamport': '1'},
      <String, Object?>{...base, 'lamport': 0},
      <String, Object?>{...base, 'issueId': ''},
      <String, Object?>{...base, 'at': 'いつか'},
      <String, Object?>{...base, 'data': <String, Object?>{}},
      <String, Object?>{
        ...base,
        'data': <String, Object?>{'title': '   '},
      },
      <String, Object?>{
        ...base,
        'kind': 'comment',
        'data': <String, Object?>{'text': ''},
      },
      <String, Object?>{
        ...base,
        'kind': 'status',
        'data': <String, Object?>{'status': 'unknown_status'},
      },
      <String, Object?>{
        ...base,
        'data': <Object?>[1, 2],
      },
      'これはopではない',
    ];

    final decoded = decodeOps(broken);
    expect(decoded.ops, isEmpty);
    expect(decoded.skipped, broken.length);
    expect(decodeOps('これも違う').ops, isEmpty);
  });

  test('知らない項目は落とさずに通す（古い端末が新しい項目を消さない）', () {
    final op = Op(
      deviceId: 'A',
      lamport: 1,
      kind: OpKind.add,
      issueId: 'A:1',
      at: DateTime(2026, 10, 6),
      data: <String, Object?>{
        'title': '牛乳',
        'priority': 3,
        'tags': <Object?>['買い物', null],
      },
    );
    final back = _roundTrip(op);
    expect(back.data['priority'], 3);
    expect(back.data['tags'], <Object?>['買い物', null]);
  });

  test('日本語と絵文字が壊れない', () {
    final op = Op(
      deviceId: 'A',
      lamport: 1,
      kind: OpKind.comment,
      issueId: 'A:1',
      at: DateTime(2026, 10, 6, 12),
      data: <String, Object?>{'text': '電球は E26 🛁 だった'},
    );
    expect(_roundTrip(op).data['text'], '電球は E26 🛁 だった');
  });

  test('wire形式のキーは、サーバーが読む形と一致している', () {
    final encoded = encodeOp(
      Op(
        deviceId: 'A',
        lamport: 1,
        kind: OpKind.add,
        issueId: 'A:1',
        at: DateTime(2026, 10, 6),
        data: <String, Object?>{'title': '牛乳'},
      ),
    );
    expect(encoded.keys.toSet(), <String>{
      'id',
      'deviceId',
      'lamport',
      'kind',
      'issueId',
      'at',
      'data',
      'derivedFrom',
      'member',
    });
    expect(encoded['kind'], 'add');
    expect(encoded['data'], isA<Map<String, Object?>>());
  });
}

Op _roundTrip(Op op) {
  final json = jsonDecode(jsonEncode(encodeOp(op))) as Map<Object?, Object?>;
  final back = decodeOp(json);
  expect(back, isNotNull, reason: '往復できるはず: $json');
  return back!;
}
