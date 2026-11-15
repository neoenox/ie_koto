import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/sync/storage.dart';

class _ControlledAsyncStore implements AsyncKeyValueStore {
  final Map<String, String> values = <String, String>{};
  int confirmedWrites = 0;
  int? failOnConfirmedWrite;

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
    confirmedWrites++;
    if (confirmedWrites == failOnConfirmedWrite) {
      throw StateError('保存拒否');
    }
    write(key, value);
  }
}

void main() {
  test('移行先への全書込みが確認できるまでマーカーを保存しない', () async {
    final store = _ControlledAsyncStore()
      ..write(DeviceStorage.deviceKey, 'device-1')
      ..write(DeviceStorage.relayKey, '["relay-1"]')
      ..failOnConfirmedWrite = 2;
    final storage = DeviceStorage(store);

    await expectLater(
      storage.migrateLegacyScope('household-1'),
      throwsA(isA<StateError>()),
    );

    expect(store.read('ie_koto.household_scope_migrated'), isNull);
    expect(
      store.read('ie_koto.household.household-1.${DeviceStorage.deviceKey}'),
      'device-1',
    );
    expect(
      () => storage.scoped('household-1'),
      throwsA(isA<StateError>()),
    );

    // Retry after the destination becomes writable. Already-copied keys stay
    // intact, missing keys are copied, and only then is the marker written.
    store.failOnConfirmedWrite = null;
    await storage.migrateLegacyScope('household-1');
    expect(store.read('ie_koto.household_scope_migrated'), 'true');

    final scoped = storage.scoped('household-1');
    expect(scoped.load().deviceId, 'device-1');
    expect(scoped.load().pendingRelayIds, {'relay-1'});
  });

  test('旧版が先にマーカーを保存していても不足キーを再移行する', () async {
    final store = _ControlledAsyncStore()
      ..write('ie_koto.household_scope_migrated', 'true')
      ..write(DeviceStorage.deviceKey, 'legacy-device')
      ..write(DeviceStorage.relayKey, '["relay-2"]')
      ..write(
        'ie_koto.household.household-2.${DeviceStorage.deviceKey}',
        'existing-device',
      );
    final storage = DeviceStorage(store);

    await storage.migrateLegacyScope('household-2');

    final scoped = storage.scoped('household-2');
    expect(scoped.load().deviceId, 'existing-device');
    expect(scoped.load().pendingRelayIds, {'relay-2'});
  });
}
