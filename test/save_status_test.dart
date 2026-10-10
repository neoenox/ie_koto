import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/storage.dart';
import 'support/memory_store.dart';

class FailingStore extends MemoryStore {
  bool fail = false;
  @override
  void write(String key, String? value) {
    if (fail) throw StateError('disk full');
    super.write(key, value);
  }
}

class DelayedStore extends MemoryStore implements AsyncKeyValueStore {
  Completer<void>? gate;
  bool fail = false;
  @override
  Future<void> writeConfirmed(String key, String? value) async {
    await gate?.future;
    if (fail) throw StateError('保存拒否');
    super.write(key, value);
  }
}

void main() {
  test('非同期保存の完了待ち中の編集も最後のflushで永続化する', () async {
    final kv = DelayedStore()..gate = Completer<void>();
    final storage = DeviceStorage(kv);
    final store = IssueStore(deviceId: 'A', storage: storage);
    final issue = store.add(title: '保存開始時の内容');
    await Future<void>.delayed(Duration.zero);
    expect(storage.isSaving, isTrue);
    expect(kv.values, isEmpty);
    store.rename(issue.id, '保存完了待ち中の改名');
    store.comment(issue.id, '保存完了待ち中のコメント');
    kv.gate!.complete();
    await storage.flush();
    expect(storage.isSaving, isFalse);
    expect(storage.lastSaveError, isNull);
    final restored = IssueStore(storage: DeviceStorage(kv));
    expect(restored.all.single.title, '保存完了待ち中の改名');
    expect(restored.ops.map((op) => op.id), store.ops.map((op) => op.id));
    expect(restored.outbox.map((op) => op.id), store.outbox.map((op) => op.id));
    expect(
      restored.ops.where((op) => op.data['text'] != null).single.data['text'],
      '保存完了待ち中のコメント',
    );
    await restored.storage!.flush();
  });

  for (final asyncSave in [false, true]) {
    test('非同期=$asyncSave・送信済み位置の保存失敗は再試行で復元する', () async {
      final syncKv = FailingStore();
      final asyncKv = DelayedStore();
      final MemoryStore kv = asyncSave ? asyncKv : syncKv;
      final storage = DeviceStorage(kv);
      final store = IssueStore(deviceId: 'A', storage: storage);
      store.add(title: '送信済みでも残す内容');
      await storage.flush();
      syncKv.fail = true;
      asyncKv.fail = true;
      store.markSent(store.outbox.toList());
      await storage.flush();
      expect(storage.lastSaveError, isNotNull);
      expect(store.outbox, isEmpty);
      final beforeRetry = IssueStore(storage: DeviceStorage(kv));
      expect(beforeRetry.outbox, hasLength(1));
      expect(beforeRetry.all.single.title, '送信済みでも残す内容');
      syncKv.fail = false;
      asyncKv.fail = false;
      await storage.flush();
      expect(storage.lastSaveError, isNull);
      final afterRetry = IssueStore(storage: DeviceStorage(kv));
      expect(afterRetry.outbox, isEmpty);
      expect(afterRetry.all.single.title, '送信済みでも残す内容');
      await afterRetry.storage!.flush();
    });
    test('非同期=$asyncSave・保存失敗中の追加編集も最新状態として復元する', () async {
      final syncKv = FailingStore()..fail = true;
      final asyncKv = DelayedStore()..fail = true;
      final MemoryStore kv = asyncSave ? asyncKv : syncKv;
      final storage = DeviceStorage(kv);
      final store = IssueStore(deviceId: 'A', storage: storage);
      final issue = store.add(title: '最初の内容');
      store.rename(issue.id, '保存待ち中に変更した内容');
      store.comment(issue.id, '保存待ち中のコメント');
      await storage.flush();
      expect(storage.lastSaveError, isNotNull);
      syncKv.fail = false;
      asyncKv.fail = false;
      await storage.flush();
      expect(storage.lastSaveError, isNull);
      final restored = IssueStore(storage: DeviceStorage(kv));
      expect(restored.all.single.title, '保存待ち中に変更した内容');
      expect(restored.ops.map((op) => op.id), store.ops.map((op) => op.id));
      expect(
        restored.outbox.map((op) => op.id),
        store.outbox.map((op) => op.id),
      );
      expect(
        restored.ops.where((op) => op.data['text'] != null).single.data['text'],
        '保存待ち中のコメント',
      );
      final priorIds = restored.ops.map((op) => op.id).toSet();
      restored.add(title: '復元後の追加');
      expect(restored.ops, hasLength(priorIds.length + 1));
      expect(
        restored.ops.map((op) => op.id).toSet(),
        hasLength(priorIds.length + 1),
      );
      await restored.storage!.flush();
    });
  }

  test('非同期保存は完了まで保存中、失敗後は内容を保持して再試行する', () async {
    final kv = DelayedStore()..gate = Completer<void>();
    final storage = DeviceStorage(kv);
    final store = IssueStore(deviceId: 'A', storage: storage);
    store.add(title: 'まだ保存中');
    expect(storage.isSaving, isTrue);
    expect(kv.values, isEmpty);
    kv.fail = true;
    kv.gate!.complete();
    await storage.flush();
    expect(storage.lastSaveError, isNotNull);
    kv.fail = false;
    await storage.flush();
    expect(storage.lastSaveError, isNull);
    expect(storage.isSaving, isFalse);
    expect(IssueStore(storage: DeviceStorage(kv)).all.single.title, 'まだ保存中');
    await storage.flush();
  });
  test('保存失敗を記録し、未保存のopを再試行で残す', () async {
    final kv = FailingStore();
    final storage = DeviceStorage(kv);
    final store = IssueStore(deviceId: 'A', storage: storage);
    kv.fail = true;
    store.add(title: '保存に失敗した用事');
    expect(storage.lastSaveError, isNotNull);
    expect(IssueStore(storage: DeviceStorage(kv)).all, isEmpty);
    kv.fail = false;
    await storage.flush();
    expect(storage.lastSaveError, isNull);
    expect(
      IssueStore(storage: DeviceStorage(kv)).all.single.title,
      '保存に失敗した用事',
    );
  });
}
