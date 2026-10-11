import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/sync/storage.dart';

class _FailingAsyncStore implements AsyncKeyValueStore {
  final Map<String, String> values = <String, String>{};
  bool failWrites = true;

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String? value) {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> writeConfirmed(String key, String? value) async {
    if (failWrites) throw StateError('保存拒否');
    write(key, value);
  }
}

void main() {
  test('非同期書込みが失敗中でも load は保留中の最新値を返す', () async {
    final store = _FailingAsyncStore();
    final storage = DeviceStorage(store);
    storage.saveDeviceId('A');
    storage.savePendingMemberAliases({'old': 'new'});
    storage.savePendingMemberRemovals({'removed'});
    await storage.flush();

    expect(storage.lastSaveError, isNotNull);
    expect(store.read(DeviceStorage.deviceKey), isNull);
    final saved = storage.load();
    expect(saved.deviceId, 'A');
    expect(saved.pendingMemberAliases, {'old': 'new'});
    expect(saved.pendingMemberRemovals, {'removed'});

    // When storage becomes available, the same pending writes are persisted.
    store.failWrites = false;
    await Future<void>.delayed(Duration.zero);
    await storage.flush();
    expect(storage.lastSaveError, isNull);
    expect(DeviceStorage(store).load().deviceId, 'A');
    expect(DeviceStorage(store).load().pendingMemberAliases, {'old': 'new'});
    expect(DeviceStorage(store).load().pendingMemberRemovals, {'removed'});
  });

  test('保留中の値は古い永続化値より優先される', () async {
    final store = _FailingAsyncStore();
    store.write(DeviceStorage.deviceKey, 'old');
    final storage = DeviceStorage(store);
    expect(storage.load().deviceId, 'old');
    storage.saveDeviceId('new');
    await storage.flush();
    expect(store.read(DeviceStorage.deviceKey), 'old');
    expect(storage.load().deviceId, 'new');
  });
}
