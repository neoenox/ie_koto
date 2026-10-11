import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/api.dart';
import 'package:ie_koto/sync/session.dart';

/// #110: 未送信の統合・削除も「送信待ち」に含める。
/// `_run()` は名前変更だけでなく統合・削除も送るため、
/// 表示（`SyncStatusLine`）と実態を一致させる。
void main() {
  SyncSession sessionFor(IssueStore store) {
    final session = SyncSession(
      store: store,
      api: SyncApi(
        baseUrl: 'https://example.test',
        householdId: 'household12345678',
        token: 'x' * 32,
      ),
    );
    addTearDown(session.close);
    return session;
  }

  test('統合の送り残しは未送信として扱う', () {
    final store = IssueStore(deviceId: 'A');
    final session = sessionFor(store);
    expect(session.hasPendingChanges, isFalse);

    final keep = store.addMember('はる');
    final dup = store.addMember('はる');
    // 追加自体の未送信名は送り済みにして、統合だけを残す。
    store.markMemberSynced(keep.id);
    store.markMemberSynced(dup.id);
    expect(session.hasPendingChanges, isFalse);
    expect(store.mergeMembers(dup.id, keep.id), isTrue);
    expect(store.outbox, isEmpty);
    expect(session.hasPendingChanges, isTrue);

    store.markMemberAliasSynced(dup.id);
    expect(session.hasPendingChanges, isFalse);
  });

  test('削除の送り残しは未送信として扱う', () {
    final store = IssueStore(deviceId: 'A');
    final session = sessionFor(store);
    expect(session.hasPendingChanges, isFalse);

    final member = store.addMember('おばあちゃん');
    store.markMemberSynced(member.id);
    expect(session.hasPendingChanges, isFalse);
    expect(store.removeMember(member.id), isTrue);
    expect(store.outbox, isEmpty);
    expect(session.hasPendingChanges, isTrue);

    store.markMemberRemovalSynced(member.id);
    expect(session.hasPendingChanges, isFalse);
  });
}
