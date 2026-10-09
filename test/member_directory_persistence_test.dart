import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/model.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/storage.dart';

import 'support/memory_store.dart';

void main() {
  test(
    'offline restart restores roster, viewer, legacy actors and pending members',
    () {
      final device = MemoryStore();
      final storage = DeviceStorage(device).scoped('household-a');
      final store = IssueStore(storage: storage);
      final issue = store.add(title: '牛乳', assigneeId: 'partner');
      store.applyMemberDirectory(
        const MemberDirectory(
          members: [Member('mem_a', 'あき'), Member('mem_b', 'はる')],
          aliases: {'me': 'mem_a', 'partner': 'mem_b'},
        ),
      );
      store.setMeId('partner');
      final third = store.addMember('そら');
      store.renameMember('mem_a', 'あきさん');
      store.comment(issue.id, 'オフライン');

      final reopened = IssueStore(
        storage: DeviceStorage(device).scoped('household-a'),
      );
      expect(reopened.members.map((member) => member.id), [
        'mem_a',
        'mem_b',
        third.id,
      ]);
      expect(reopened.meId, 'mem_b');
      expect(reopened.memberLabel('me'), 'あきさん');
      expect(reopened.memberLabel('partner'), '自分');
      expect(reopened.byId(issue.id)!.assigneeId, 'mem_b');
      expect(reopened.pendingMemberNames, {'mem_a': 'あきさん', third.id: 'そら'});
      expect(reopened.byId(issue.id)!.events.first.actorId, 'mem_a');
      expect(reopened.byId(issue.id)!.events.last.actorId, 'mem_b');

      final other = IssueStore(
        storage: DeviceStorage(device).scoped('household-b'),
      );
      expect(other.legacyMemberAliases, isEmpty);
      expect(other.members.map((member) => member.id), ['me', 'partner']);
    },
  );

  test(
    'previously saved stable member names restore without requiring new keys',
    () {
      final device = MemoryStore();
      final storage = DeviceStorage(device);
      storage.saveMemberNames({'mem_a': 'あき', 'mem_b': 'はる', 'mem_c': 'そら'});
      storage.saveMeId('mem_b');
      final reopened = IssueStore(storage: DeviceStorage(device));
      expect(reopened.members.length, 3);
      expect(reopened.memberLabel('mem_a'), 'あき');
      expect(reopened.memberLabel('mem_b'), '自分');
      expect(reopened.memberLabel('mem_c'), 'そら');
    },
  );
}
