import 'package:ie_koto/sync/storage.dart';

/// テスト用の置き場（端末の代わりに Map を使う）。
///
/// 同じ [MemoryStore] をもう1つ [DeviceStorage] で包み直すと、
/// **アプリを開き直したのと同じ**になる（保存の中身はそのまま、読み直す）。
class MemoryStore implements KeyValueStore {
  final Map<String, String> values = <String, String>{};

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
}
