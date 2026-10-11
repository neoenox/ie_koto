import 'package:flutter_test/flutter_test.dart';
import 'package:ie_koto/store.dart';
import 'package:ie_koto/sync/storage.dart';

import 'support/memory_store.dart';

class CountingStore extends MemoryStore {
  final counts = <String, int>{};

  @override
  void write(String key, String? value) {
    counts[key] = (counts[key] ?? 0) + 1;
    super.write(key, value);
  }
}

/// #111: 名簿の対応表を適用しても、同じ保存先に重複書き込みしない。
void main() {
  test('applyMemberAliasesは対応表と名簿を1回ずつだけ保存する', () {
    final kv = CountingStore();
    final store = IssueStore(deviceId: 'A', storage: DeviceStorage(kv));
    kv.counts.clear();

    store.applyMemberAliases({'old-id': 'new-id'});

    expect(kv.counts[DeviceStorage.aliasesKey], 1);
    expect(kv.counts[DeviceStorage.membersKey], 1);
  });
}
