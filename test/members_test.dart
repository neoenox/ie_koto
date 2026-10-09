import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/home_page.dart';
import 'package:ie_koto/main.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/storage.dart';

void main() {
  group('#87 予約名', () {
    test('前後の半角・全角空白を落として比べる', () {
      expect(IssueStore.normalizeMemberName('　 自分 　'), '自分');
      expect(IssueStore.isReservedMemberName('自分'), isTrue);
      expect(IssueStore.isReservedMemberName('　パートナー　'), isTrue);
      expect(IssueStore.isReservedMemberName('あき'), isFalse);
      expect(IssueStore.isReservedMemberName('自分たち'), isFalse);
    });

    test('追加で予約名は作れない', () {
      final store = IssueStore();
      for (final bad in ['自分', 'パートナー', '　自分　']) {
        expect(() => store.addMember(bad), throwsArgumentError, reason: bad);
      }
      expect(store.members.length, 2);
    });

    test('改名で予約名・空は変えられない', () {
      final store = IssueStore();
      expect(store.renameMember('me', '自分'), isFalse);
      expect(store.renameMember('me', '  '), isFalse);
      expect(store.renameMember('me', 'あき'), isTrue);
      expect(store.memberById('me')!.name, 'あき');
    });
  });

  group('#86 所有制限', () {
    test('他人の名前は変えられない', () {
      final store = IssueStore();
      store.setMeId('me');
      expect(store.renameMember('partner', 'ゆう'), isFalse);
      expect(store.memberById('partner')!.name, 'パートナー');
    });
  });

  group('#85 重複検出', () {
    test('2台が同じ人で書くと警告対象になる', () {
      final a = IssueStore(deviceId: 'da');
      final b = IssueStore(deviceId: 'db');
      a.add(title: '牛乳');
      b.add(title: 'パン');
      b.receive(a.ops);
      expect(b.duplicateMemberLabels, contains('自分'));
    });

    test('1台だけなら警告は出ない', () {
      final store = IssueStore(deviceId: 'solo');
      store.add(title: '牛乳');
      expect(store.duplicateMemberLabels, isEmpty);
    });

    test('本人未選択は接続前から分かる', () {
      expect(IssueStore().meExplicit, isFalse);
      final store = IssueStore();
      store.setMeId('partner');
      expect(store.meExplicit, isTrue);
    });
  });

  group('#88 統合・削除', () {
    IssueStore household() {
      final store = IssueStore();
      store.setMeId('me');
      return store;
    }

    test('まとめると担当・履歴の見え方は残る', () {
      final store = household();
      final haru1 = store.addMember('はる');
      final haru2 = store.addMember('はる');
      final issue = store.add(title: '掃除');
      store.setAssignee(issue.id, haru2.id);
      expect(store.mergeMembers(haru2.id, haru1.id), isTrue);
      // 旧行は消えるが、旧IDでの参照は対応表で引き継ぐ。
      expect(store.members.where((m) => m.id == haru2.id), isEmpty);
      expect(store.memberById(haru2.id)!.id, haru1.id);
      expect(store.assigneeWord(store.byId(issue.id)!.assigneeId), 'はる');
    });

    test('自分はまとめられない・外せない', () {
      final store = household();
      final other = store.addMember('はる');
      expect(store.mergeMembers('me', other.id), isFalse);
      expect(store.removeMember('me'), isFalse);
    });

    test('未完了の担当がある人は外せない', () {
      final store = household();
      final other = store.addMember('はる');
      final issue = store.add(title: '掃除');
      store.setAssignee(issue.id, other.id);
      expect(store.removeMember(other.id), isFalse);
      store.complete(issue.id);
      expect(store.removeMember(other.id), isTrue);
    });

    test('使っていない人は外せる', () {
      final store = household();
      final other = store.addMember('はる');
      expect(store.removeMember(other.id), isTrue);
      expect(store.memberById(other.id), isNull);
      expect(store.pendingMemberRemovals, contains(other.id));
    });

    test('送り残しは端末に残る', () {
      final store = household();
      final haru1 = store.addMember('はる');
      final haru2 = store.addMember('はる');
      store.mergeMembers(haru2.id, haru1.id);
      expect(store.pendingMemberAliases, containsPair(haru2.id, haru1.id));
    });
  });

  group('本人警告の帯', () {
    const creds = SyncCredentials(
      baseUrl: 'http://localhost:9',
      householdId: 'h',
      token: 't',
    );

    Future<void> pumpHome(WidgetTester tester, IssueStore store) {
      return tester.pumpWidget(
        MaterialApp(
          home: HomePage(
            store: store,
            credentials: creds,
            onOpenHousehold: (_) async {},
          ),
        ),
      );
    }

    testWidgets('未選択なら選び直しを促す', (tester) async {
      final store = IssueStore();
      await pumpHome(tester, store);
      await tester.pumpAndSettle();
      expect(find.text('この端末を使う人をえらんでください'), findsOneWidget);
    });

    testWidgets('選択済み・重複なしなら出ない', (tester) async {
      final store = IssueStore();
      store.setMeId('partner');
      await pumpHome(tester, store);
      await tester.pumpAndSettle();
      expect(find.text('この端末を使う人をえらんでください'), findsNothing);
      expect(find.textContaining('2台で使われています'), findsNothing);
    });

    testWidgets('2台の重複は本人確認を促す', (tester) async {
      final store = IssueStore(deviceId: 'da');
      store.setMeId('me');
      store.add(title: '牛乳');
      final other = IssueStore(deviceId: 'db');
      other.add(title: 'パン');
      store.receive(other.ops);
      await pumpHome(tester, store);
      await tester.pumpAndSettle();
      expect(find.textContaining('2台で使われています'), findsOneWidget);
    });
  });

  group('名簿の行', () {
    testWidgets('他人は変えられず解消だけできる', (tester) async {
      final store = IssueStore();
      await tester.pumpWidget(IeKotoApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('empty-household')));
      await tester.pumpAndSettle();

      // 自分の行は編集欄、他人の行は解消ボタン。
      expect(find.text('まとめる'), findsOneWidget);
      expect(find.text('はずす'), findsOneWidget);
    });

    testWidgets('予約名の追加は理由が出る', (tester) async {
      final store = IssueStore();
      await tester.pumpWidget(IeKotoApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('empty-household')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('人を追加'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '自分');
      await tester.tap(find.text('この名前で入れる'));
      await tester.pumpAndSettle();
      expect(find.textContaining('使えません'), findsOneWidget);
      expect(store.members.length, 2);
    });
  });
}
