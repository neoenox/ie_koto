import '../model.dart';
import 'log.dart';

/// op の wire 形式（JSON）。
///
/// サーバー（[server/src/index.js](../../server/src/index.js)）は op の中身を解釈しない。
/// 預かって、挿入順に返すだけ。だから、この形が端末とサーバーの唯一の約束になる。
/// 変えるときは両側そろえて変える（`server/src/index.js` の parseOp も見ること）。
///
/// - `at` は端末の時計。**UTCに直さず、そのままの壁時計**で書く（`Z` を付けない）。
///   表示と「次はいつか」にだけ使い、順序は論理時計（lamport）で決める。
/// - `data` は種類ごとの項目。日付は ISO 8601、くりかえしは入れ子のオブジェクト、
///   状態は enum の名前。知らない項目はそのまま通す（古い端末が新しい項目を落とさない）。
Map<String, Object?> encodeOp(Op op) => <String, Object?>{
      'id': op.id,
      'deviceId': op.deviceId,
      'lamport': op.lamport,
      'kind': op.kind.name,
      'issueId': op.issueId,
      'at': encodeTime(op.at),
      'data': encodeData(op.data),
      'derivedFrom': op.derivedFrom,
      'member': op.memberId,
    };

List<Map<String, Object?>> encodeOps(Iterable<Op> ops) => <Map<String, Object?>>[
      for (final op in ops) encodeOp(op),
    ];

/// 受け取ったopの束。読めなかったものは捨てて、数だけ残す。
/// （1件のせいで同期ぜんぶが止まるより、飛ばして先へ進む方がまし）
class DecodedOps {
  const DecodedOps(this.ops, this.skipped);

  final List<Op> ops;
  final int skipped;

  static const DecodedOps none = DecodedOps(<Op>[], 0);
}

DecodedOps decodeOps(Object? raw) {
  if (raw is! List) return DecodedOps.none;
  final ops = <Op>[];
  var skipped = 0;
  for (final item in raw) {
    final op = item is Map ? decodeOp(item) : null;
    if (op == null) {
      skipped += 1;
      continue;
    }
    ops.add(op);
  }
  return DecodedOps(ops, skipped);
}

/// opを1つ読む。壊れていれば null（捨てる）。
Op? decodeOp(Map<Object?, Object?> raw) {
  final kind = _kindOf(raw['kind']);
  if (kind == null) return null;

  final deviceId = raw['deviceId'];
  final issueId = raw['issueId'];
  final lamport = raw['lamport'];
  final at = decodeTime(raw['at']);
  if (deviceId is! String || deviceId.isEmpty) return null;
  if (issueId is! String || issueId.isEmpty) return null;
  if (lamport is! int || lamport < 1) return null;
  if (at == null) return null;

  // op_id は `<端末id>:<論理時計>`。ここが崩れると重複を畳めない。
  final id = raw['id'];
  if (id is! String || id != '$deviceId:$lamport') return null;

  final dataRaw = raw['data'];
  final data = dataRaw is Map ? decodeData(dataRaw) : <String, Object?>{};

  // 種類ごとに、欠けると射影が壊れる項目だけ確かめる。
  switch (kind) {
    case OpKind.add:
      final title = data['title'];
      if (title is! String || title.trim().isEmpty) return null;
    case OpKind.comment:
      final text = data['text'];
      if (text is! String || text.trim().isEmpty) return null;
    case OpKind.status:
      if (data['status'] is! IssueStatus) return null;
    default:
      break;
  }

  final derivedFrom = raw['derivedFrom'];
  final member = raw['member'];
  return Op(
    deviceId: deviceId,
    lamport: lamport,
    kind: kind,
    issueId: issueId,
    at: at,
    data: data,
    derivedFrom: derivedFrom is String && derivedFrom.isNotEmpty ? derivedFrom : null,
    memberId: member is String && member.isNotEmpty ? member : null,
  );
}

Map<String, Object?> encodeData(Map<String, Object?> data) => <String, Object?>{
      for (final entry in data.entries) entry.key: _jsonValue(entry.value),
    };

Map<String, Object?> decodeData(Map<Object?, Object?> raw) {
  final out = <String, Object?>{};
  raw.forEach((key, value) {
    if (key is! String) return;
    switch (key) {
      case 'dueDate':
        out[key] = decodeTime(value);
      case 'recurrence':
        out[key] = decodeRecurrence(value);
      case 'status':
        out[key] = _statusOf(value);
      default:
        out[key] = value;
    }
  });
  return out;
}

/// 端末の時計を、そのままの壁時計で書く（`Z` を付けない）。
String encodeTime(DateTime time) => DateTime(
      time.year,
      time.month,
      time.day,
      time.hour,
      time.minute,
      time.second,
      time.millisecond,
      time.microsecond,
    ).toIso8601String();

DateTime? decodeTime(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

Map<String, Object?> encodeRecurrence(Recurrence recurrence) => <String, Object?>{
      'kind': recurrence.kind.name,
      if (recurrence.kind == RecurrenceKind.weekdays)
        'weekdays': recurrence.weekdays.toList()..sort(),
      if (recurrence.kind == RecurrenceKind.everyDays) 'everyDays': recurrence.everyDays,
      if (recurrence.kind == RecurrenceKind.everyDays) 'fromCompletion': recurrence.fromCompletion,
    };

Recurrence decodeRecurrence(Object? raw) {
  if (raw is! Map) return Recurrence.none;
  switch (raw['kind']) {
    case 'daily':
      return Recurrence.daily;
    case 'weekdays':
      final days = <int>{};
      final listed = raw['weekdays'];
      if (listed is List) {
        for (final day in listed) {
          if (day is int && day >= DateTime.monday && day <= DateTime.sunday) days.add(day);
        }
      }
      return days.isEmpty ? Recurrence.none : Recurrence.onWeekdays(days);
    case 'everyDays':
      final days = raw['everyDays'];
      if (days is! int || days < 1) return Recurrence.none;
      return Recurrence.every(days, fromCompletion: raw['fromCompletion'] != false);
    default:
      return Recurrence.none;
  }
}

OpKind? _kindOf(Object? raw) {
  if (raw is! String) return null;
  for (final kind in OpKind.values) {
    if (kind.name == raw) return kind;
  }
  return null;
}

IssueStatus? _statusOf(Object? raw) {
  if (raw is! String) return null;
  for (final status in IssueStatus.values) {
    if (status.name == raw) return status;
  }
  return null;
}

/// JSONに書ける形に直す。知らない型は文字列にして落とさない。
Object? _jsonValue(Object? value) => switch (value) {
      null => null,
      String() || num() || bool() => value,
      DateTime() => encodeTime(value),
      Recurrence() => encodeRecurrence(value),
      Enum() => value.name,
      List() => [for (final item in value) _jsonValue(item)],
      Map() => <String, Object?>{
          for (final entry in value.entries) '${entry.key}': _jsonValue(entry.value),
        },
      _ => value.toString(),
    };
