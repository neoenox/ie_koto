import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/storage.dart';
import 'support/memory_store.dart';

class ConfirmedMemoryStore extends MemoryStore implements AsyncKeyValueStore {
  @override
  Future<void> writeConfirmed(String key, String? value) async {
    super.write(key, value);
  }
}

const directory = MemberDirectory(
  members: [
    Member('mem_a', 'あき'),
    Member('mem_b', 'はる'),
    Member('mem_c', 'そら'),
  ],
  aliases: {'me': 'mem_a', 'partner': 'mem_b'},
);

void main() {
  test('非同期保存をflush後、新しい保存インスタンスから名簿と担当を復元する', () async {
    final kv = ConfirmedMemoryStore();
    final storage = DeviceStorage(kv).scoped('async');
    final first = IssueStore(storage: storage);
    final issue = first.add(title: '修理', assigneeId: 'partner');
    first.applyMemberDirectory(directory);
    first.setMeId('mem_b');
    first.renameMember('mem_b', '春');
    await storage.flush();
    final restored = IssueStore(storage: DeviceStorage(kv).scoped('async'));
    expect(restored.byId(issue.id)!.assigneeId, 'mem_b');
    // 装置が mem_b 本人なので鏡表示は「自分」。中身の名前は「春」。
    expect(restored.memberLabel('partner'), '自分');
    expect(restored.memberById('mem_b')!.name, '春');
    expect(restored.pendingMemberNames, {'mem_b': '春'});
  });

  test('オフライン再起動で共有名簿・旧担当・本人・操作履歴を復元する', () {
    final kv = MemoryStore();
    final first = IssueStore(storage: DeviceStorage(kv).scoped('home'));
    final issue = first.add(title: '電球', assigneeId: 'partner');
    first.applyMemberDirectory(directory);
    first.setMeId('mem_c');
    final ops = first.exportJson();

    final restored = IssueStore(storage: DeviceStorage(kv).scoped('home'));
    expect(restored.members.map((m) => m.id), ['mem_a', 'mem_b', 'mem_c']);
    expect(restored.meId, 'mem_c');
    expect(restored.byId(issue.id)!.assigneeId, 'mem_b');
    expect(restored.assigneeWord(restored.byId(issue.id)!.assigneeId), 'はる');
    expect(restored.memberLabel('partner'), 'はる');
    expect(restored.exportJson(), ops, reason: '旧ログは書き換えない');
  });

  test('未送信の追加・改名と担当を再起動で維持し古い名簿に戻さない', () {
    final kv = MemoryStore();
    final first = IssueStore(storage: DeviceStorage(kv));
    first.applyMemberDirectory(directory);
    first.setMeId('mem_b');
    first.renameMember('mem_b', '春');
    final added = first.addMember('なつ');
    final issue = first.add(title: '買い物', assigneeId: added.id);
    final restored = IssueStore(storage: DeviceStorage(kv));
    expect(restored.memberById('mem_b')!.name, '春');
    expect(restored.memberLabel(added.id), 'なつ');
    expect(restored.pendingMemberNames, {'mem_b': '春', added.id: 'なつ'});
    restored.applyMemberDirectory(directory);
    expect(restored.memberById('mem_b')!.name, '春');
    expect(restored.assigneeWord(restored.byId(issue.id)!.assigneeId), 'なつ');
  });

  test('壊れた旧ID対応表は無視し、旧形式の名前と用事は読める', () {
    final kv = MemoryStore();
    final first = IssueStore(storage: DeviceStorage(kv));
    first.setMeId('partner');
    first.renameMember('partner', 'はる');
    first.add(title: '書類', assigneeId: 'partner');
    kv.write(DeviceStorage.aliasesKey, '{broken');
    final restored = IssueStore(storage: DeviceStorage(kv));
    expect(restored.legacyMemberAliases, isEmpty);
    // 装置が partner 本人なので鏡表示は「自分」。中身の名前は「はる」。
    expect(restored.memberById('partner')!.name, 'はる');
  });

  test('旧memberNamesだけの保存データも追加メンバーを復元する', () {
    final kv = MemoryStore();
    final storage = DeviceStorage(kv);
    storage.saveMemberNames({'me': 'あき', 'partner': 'はる', 'mem_c': 'そら'});
    storage.saveMeId('mem_c');
    final restored = IssueStore(storage: DeviceStorage(kv));
    expect(restored.members.map((m) => m.name), ['あき', 'はる', 'そら']);
    expect(restored.meId, 'mem_c');
  });

  test('世帯を切り替えても名簿・本人・旧ID対応・未送信名を混ぜない', () {
    final kv = MemoryStore();
    final a = IssueStore(storage: DeviceStorage(kv).scoped('a'));
    a.applyMemberDirectory(directory);
    a.setMeId('mem_c');
    a.setMeId('mem_a');
    a.renameMember('mem_a', '秋');
    a.setMeId('mem_c');
    final b = IssueStore(storage: DeviceStorage(kv).scoped('b'));
    expect(b.members.map((m) => m.id), ['me', 'partner']);
    expect(b.legacyMemberAliases, isEmpty);
    expect(b.pendingMemberNames, isEmpty);
    expect(b.meId, 'me');
    final back = IssueStore(storage: DeviceStorage(kv).scoped('a'));
    expect(back.memberLabel('me'), '秋');
    expect(back.meId, 'mem_c');
  });
}
