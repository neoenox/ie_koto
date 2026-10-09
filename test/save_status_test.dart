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
