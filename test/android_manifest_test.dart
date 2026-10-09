import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release Android manifest has real line breaks and internet permission', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, isNot(contains(r'`r`n')));
    expect(manifest, contains('<uses-permission android:name="android.permission.INTERNET"/>'));
    expect(RegExp(r'<manifest[^>]*>\s*<uses-permission').hasMatch(manifest), isTrue);
  });
}
