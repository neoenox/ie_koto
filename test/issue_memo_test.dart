import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/detail_page.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/log.dart';
import 'package:ie_koto/sync/wire.dart';

void main() {
  group('メモの射影', () {
    test('いちばん新しい note が現在値になる', () {
      final device = Device('A')
        ..write(
          OpKind.add,
          'a1',
          data: <String, Object?>{'title': '電球'},
          at: DateTime(2026, 10, 1),
        )
        ..write(
          OpKind.note,
          'a1',
          data: <String, Object?>{'text': 'E17'},
          at: DateTime(2026, 10, 2),
        )
        ..write(
          OpKind.note,
          'a1',
          data: <String, Object?>{'text': 'E17 40W'},
          at: DateTime(2026, 10, 3),
        );
      expect(project(device.log)['a1']!.note, 'E17 40W');
    });

    test('空文字は「消した」として現在値が無くなる', () {
      final device = Device('A')
        ..write(
          OpKind.add,
          'a1',
          data: <String, Object?>{'title': '電球'},
          at: DateTime(2026, 10, 1),
        )
        ..write(
          OpKind.note,
          'a1',
          data: <String, Object?>{'text': 'E17'},
          at: DateTime(2026, 10, 2),
        )
        ..write(
          OpKind.note,
          'a1',
          data: <String, Object?>{'text': ''},
          at: DateTime(2026, 10, 3),
        );
      expect(project(device.log)['a1']!.note, isNull);
    });

    test('2台が同時に書いても全順序で収束する', () {
      final a = Device('A')
        ..write(
          OpKind.add,
          'a1',
          data: <String, Object?>{'title': '電球'},
          at: DateTime(2026, 10, 1),
        );
      final b = Device('B')..receive(a.takeOutbox());
      // 互いを知らないまま、同じ論理時計で別々のメモを書く。
      a.write(
        OpKind.note,
        'a1',
        data: <String, Object?>{'text': 'Aのメモ'},
        at: DateTime(2026, 10, 2),
      );
      b.write(
        OpKind.note,
        'a1',
        data: <String, Object?>{'text': 'Bのメモ'},
        at: DateTime(2026, 10, 2),
      );
      final merged = mergeOps(a.log, b.log);
      // 端末idまで含めた全順序なので、どちらの端末で見ても同じ結果。
      expect(project(merged)['a1']!.note, 'Bのメモ');
      expect(project(mergeOps(b.log, a.log))['a1']!.note, 'Bのメモ');
    });
  });

  group('定期案件の引き継ぎ', () {
    test('次の1件にメモがコピーされ、過去回は自分のメモを保つ', () {
      final store = IssueStore(clock: () => DateTime(2026, 10, 6, 9));
      final first = store.add(
        title: '浄水器のカートリッジ',
        recurrence: Recurrence.daily,
      );
      store.setNote(first.id, '型番 PLC-2J');
      expect(store.byId(first.id)!.note, '型番 PLC-2J');

      store.complete(first.id);
      final nextId = store.byId(first.id)!.generatedNextId!;
      expect(store.byId(nextId)!.note, '型番 PLC-2J', reason: '固定情報は引き継ぐ');
      expect(store.byId(first.id)!.note, '型番 PLC-2J', reason: '過去回は自分の値を保つ');
    });

    test('メモを消してから完了すると、次の1件も空', () {
      final store = IssueStore(clock: () => DateTime(2026, 10, 6, 9));
      final first = store.add(title: 'フィルター', recurrence: Recurrence.daily);
      store.setNote(first.id, '一時的なメモ');
      store.setNote(first.id, '');
      store.complete(first.id);
      final nextId = store.byId(first.id)!.generatedNextId!;
      expect(store.byId(nextId)!.note, isNull);
    });
  });

  group('wire の検証', () {
    test('note op をJSONで往復できる（空文字も通す）', () {
      Map<String, Object?> raw(String text) => encodeOp(
        Op(
          deviceId: 'A',
          lamport: 1,
          kind: OpKind.note,
          issueId: 'A:1',
          at: DateTime(2026, 10, 6),
          data: <String, Object?>{'text': text},
        ),
      );
      final kept = decodeOp(raw('E17'));
      expect(kept, isNotNull);
      expect(kept!.kind, OpKind.note);
      expect(kept.data['text'], 'E17');
      final cleared = decodeOp(raw(''));
      expect(cleared, isNotNull);
      expect(cleared!.data['text'], '');
    });

    test('text が文字列でない note は読み飛ばす', () {
      final raw = encodeOp(
        Op(
          deviceId: 'A',
          lamport: 1,
          kind: OpKind.note,
          issueId: 'A:1',
          at: DateTime(2026, 10, 6),
          data: <String, Object?>{'text': 'E17'},
        ),
      );
      expect(decodeOp({...raw, 'data': <String, Object?>{}}), isNull);
      expect(
        decodeOp({
          ...raw,
          'data': <String, Object?>{'text': 42},
        }),
        isNull,
      );
    });
  });

  group('詳細のメモ行', () {
    testWidgets('無いときは「なし」、書くと反映し、消去できる', (tester) async {
      final store = IssueStore(clock: () => DateTime(2026, 10, 6, 9));
      final issue = store.add(title: '電球');

      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(store: store, issueId: issue.id),
        ),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('detail-memo'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('なし')),
        findsOneWidget,
      );

      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('memo-field')),
        'E17 40W',
      );
      await tester.tap(find.byKey(const ValueKey('memo-save')));
      await tester.pumpAndSettle();

      expect(store.byId(issue.id)!.note, 'E17 40W');
      expect(
        find.descendant(of: row, matching: find.text('E17 40W')),
        findsOneWidget,
      );

      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('memo-clear')));
      await tester.pumpAndSettle();

      expect(store.byId(issue.id)!.note, isNull);
      expect(
        find.descendant(of: row, matching: find.text('なし')),
        findsOneWidget,
      );
    });

    testWidgets('長いメモは1行に切り詰めて出す', (tester) async {
      final store = IssueStore(clock: () => DateTime(2026, 10, 6, 9));
      final issue = store.add(title: '手続き');
      store.setNote(issue.id, '区役所の2番窓口で住所変更の手続き。持ち物は身分証と印鑑。');

      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(store: store, issueId: issue.id),
        ),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('detail-memo'));
      final value = tester
          .widgetList<Text>(
            find.descendant(of: row, matching: find.byType(Text)),
          )
          .map((t) => t.data)
          .firstWhere((d) => d != 'メモ');
      // 先頭24文字＋「…」で省略する。
      expect(value, startsWith('区役所の2番窓口で'));
      expect(value, endsWith('…'));
      expect(value!.length, 25);
    });
  });
}
