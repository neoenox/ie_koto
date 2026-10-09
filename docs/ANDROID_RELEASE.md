# Android配布前のビルドと署名（#59）

## 方針

applicationIdは既存の `com.neoen.ie_koto` を維持する。公開済みアプリのID・署名鍵を無断で変更しない。
releaseはdebug署名へフォールバックしない。署名設定がない/不完全、または鍵ファイルが存在しない場合はGradleのタスク実行前に停止する。debugビルドは従来どおり開発用署名で動かせる。

## 既存鍵を用意する

既存の配布先・Play Consoleの登録状態とアップロード鍵の管理者を確認する。鍵が見つからない場合は勝手に作り直さず、管理者の復旧・再設定手順を使う。

`android/key.properties` はgitignore対象。次の4項目をローカルで設定する。実際の値をIssue、チャット、CIログに貼らない。

```properties
storeFile=C:/private/path/upload-keystore.jks
storePassword=<store-password>
keyAlias=<existing-upload-key-alias>
keyPassword=<key-password>
```

Windowsのパスは `/` を使うとPropertiesのバックスラッシュエスケープを避けられる。相対パスは `android/` を基準に解決する。秘密鍵とパスワードはアクセス制限した別の場所で保管し、復旧用コピーも安全に管理する。

## 公開成果物を作る

1. 使用Flutter/JDK/SDK環境を記録する。SDKライセンスは担当者が確認・承認する。
2. `flutter analyze`、`flutter test`、サーバーテストと必要E2Eを通す。
3. `pubspec.yaml` のversionNameとversionCodeを配布先の既存バージョンに合わせて更新する。ビルド番号を再利用しない。
4. `flutter build appbundle --release` を実行する。
5. 署名を `jarsigner -verify -verbose -certs <aab>` 等で確認する。署名証明書の指紋を配布先のアップロード証明書と照合する。署名があるだけでは適切な配布鍵である証明にはならない。
6. merged ManifestにINTERNET権限があり、不正なテキストがないことを確認する。
7. 内部テストに配布してインストールする。HTTPS同期・保存・終了復帰は実機で別途確認する（#60）。

## 通常アプリを保護するAndroid debug検証

既存エミュレーターには利用データがある可能性があるため、通常のapplicationIdへのテスト上書きを避ける。検証用PowerShellでのみ以下を実行する。

```powershell
$env:IE_KOTO_ISOLATED_TEST = '1'
flutter test integration_test/app_flows_test.dart -d emulator-5554
Remove-Item Env:IE_KOTO_ISOLATED_TEST
```

この明示的な環境変数が `1` のときだけdebugのapplicationIdに `.verification` を付ける。releaseと通常debugは既存IDのまま。検証終了後は変数を解除する。IDEや別ターミナルへ恒久設定しない。

上記E2Eは本物のSharedPreferencesでアプリ再生成を確認するが、OS強制終了のテストではない。正式署名済みreleaseの合格にも代用できない。

## 今回の検証

- Manifestの開始タグに混入したリテラルのバッククォート改行表現を通常の改行へ修正。
- `flutter build apk --release` のGradleスクリプト評価は成功し、署名設定がないため指定した安全なエラーで停止した。
- 最新コードでもkey.properties不存在を確認してJDK17で `flutter build appbundle --release --no-pub` を実行。bundleReleaseは「Release signing requires android/key.properties: storeFile, storePassword, keyAlias, keyPassword」でexit 1（約18秒）。期待した負の検証であり、AAB生成成功ではない。鍵の作成・置換、ライセンス承認、配布は行っていない。
- `flutter build apk --debug` は成功。今回生成されたdebug merged ManifestにINTERNET権限と正しいXML開始部分を確認した。過去のrelease中間生成物は今回のrelease検証の証拠に使わない。
- 最新の保存・同期入力境界・時計上限の安全停止回帰を含むアプリ全182テスト、静的解析、`git diff --check` は成功。サーバー全23テストも成功（serverのnpm testで全テストファイルを実行）。`flutter pub get --enforce-lockfile` も成功。
- 実Chrome debugモードで320×568の基本操作・保存からの再生成E2Eが成功。
- Pixel_6_API_35エミュレーターの通常アプリは上書きせず、別ID `com.neoen.ie_koto.verification` でdebug E2Eを実行し成功。追加・コメント・完了/取り消し・改名・SharedPreferencesからのストア再生成・くりかえし選択を確認した。
- AndroidのIME表示時に縦overflowを発見し、Widget回帰テストでも修正前の失敗を確認。IME表示時の補助選択肢折りたたみ（選択値は保持）と空状態のスクロール対応で修正後に成功。追加の回帰assertionで担当・明日の期限が折りたたみ中の登録にも残り、IME解除で選択肢が戻ることを確認（小画面2テスト成功、静的解析問題なし）。
- 通常エントリポイント `lib/main.dart` の別ID debug APKで、ネイティブタップによる `ProcessRestartCheck` の追加後、`adb shell am force-stop com.neoen.ie_koto.verification` →再起動を確認。PIDは6092から6252へ変わり、再インストールなしで追加した項目が画面に復元された。同期未設定のローカル保存のみの検証。スクリーンショットは `build/android-process-restart.png`（生成物）に保存。
- 別ID debugアプリで `integration_test/two_users_test.dart` がAndroid上でも成功。ADB reverseでメモリ上Workerへ実HTTP接続し、依頼・担当・双方コメント・到達不能APIでの未送信保持・再送後の完了共有・重複なし・改名共有と端末本人の独立を確認。
- これは1エミュレーター内の2つのストアを切り替える検証で、2実端末ではない。同期はテストから明示実行し、ネットワーク遮断や自動タイマー・背景復帰同期は対象外。
- 端末再起動、2実端末のrelease HTTPS同期、背景復帰時の自動同期検証は未完了。debugエミュレーター結果をrelease実機合格と混同しない。
- リポジトリ内に既存の配布用鍵・key.propertiesは見つからない。鍵を新規作成・置換していない。
- 署名済みAAB生成、正式証明書の照合、実機release同期、Play配布は未完了。この文書を配布成功の証拠にしない。
