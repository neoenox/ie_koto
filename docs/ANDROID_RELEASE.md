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

## 署名の照合手順（Play App Signing利用時）

Play App Signingでは、配布署名とアップロード署名が別になる。照合するのは **アップロード証明書**（Play Console → 設定 → アプリの署名 → アップロード証明書のSHA-256）である。

```powershell
# 1. AABの署名を確認（AABはJAR署名のためjarsignerを使う。APKには使わない）
jarsigner -verify -verbose -certs build/app/outputs/bundle/release/app-release.aab

# 2. 手元のアップロード鍵のSHA-256指紋を取り出す（合言葉は画面に入力し、ログに残さない）
keytool -list -v -keystore C:/private/path/upload-keystore.jks -alias <existing-upload-key-alias> |
  Select-String 'SHA256'

# 3. 手順2の指紋とPlay Consoleのアップロード証明書のSHA-256が一致することを確認する
```

APKを確認するときは `apksigner` を使う（`apksigner` はAPK専用、AABには使わない。
`apksigner.bat` が直接動かない環境では `java -jar` 形を使う。debug APKで動作確認済み）。

```powershell
java -jar C:/Android/sdk/build-tools/36.0.0/lib/apksigner.jar verify --print-certs `
  build/app/outputs/flutter-apk/app-release.apk |
  Select-String 'SHA-256'
```

注意：`keytool -printcert -jarfile` はv1（JAR）署名のない成果物に使えない。
debug APKのようにv2以降のみで署名されたものは「JARファイルではありません」と失敗する。
上記の使い分け（AAB→jarsigner／鍵→keytool -list／APK→apksigner）を守ること。

指紋が一致しない場合は配布を止め、鍵の取り違えを疑う。正しい鍵でも `key.properties` の値（パス・別名・合言葉）はIssue・チャット・CIログに貼らない。

## 鍵の保全と復元（所有者作業）

JKS・パスワード・`key.properties` を変更・移動・削除しない。以下は所有者が暗号化した別媒体で実施する。

1. `~/.android/release-keys/ie-koto-upload.jks` を別媒体へ複写する。
2. パスワード（`ie-koto-passwords.txt` の内容）をパスワード管理へ移し、平文ファイルの扱いを決める（残す場合は権限制限を維持）。
3. 復元検証：別媒体から一時フォルダへ戻し、`keytool -list -keystore <戻したJKS> -alias upload` で読めることと、SHA-256が記録の指紋と一致することを確認する。確認後は一時ファイルを消す。
4. Git・OneDriveの通常同期・チャット・CIログに鍵・パスワードを置かない。`android/.gitignore` が `key.properties` と `**/*.jks` を除外していることを `git check-ignore -v` で確認する。

バックアップの完了確認までは #59 を閉じない。

## ビルド陳腐化の記録（暫定回避策）

`integration_test` を実行した後の作業ツリーでは、生成済み `GeneratedPluginRegistrant.java` が
`dev.flutter.plugins.integration_test` を参照したまま残り、`bundleRelease` のjavacが
`package does not exist` で失敗することがある（debugビルドでは顕在化しない場合がある）。

- 暫定回避策：`flutter clean` のあと `--no-pub` を付けずに `flutter build appbundle --release` を実行する（依存再解決で登録が作り直される）。2026-10-12にこの手順で復旧し、署名AAB生成に成功した。クリーン再ビルドはバイト同一（SHA-256一致）の成果物を再現した。
- 追加検証（2026-10-12）：E2E実行直後に `flutter build apk --debug --no-pub` を行っても再現しなかった。増分Gradle状態に依存する散発事象と判断し、原因の断定はしない。
- CIにはAndroidビルド工程がなく、releaseコンパイルにはローカルの署名鍵が要るため、CIでの再発検出は組み込まない。release手順として「クリーン＋依存再解決つきビルド」を必須とする（RESIDUAL RISK）。

## Play Console登録の準備（未登録）

現状：`com.neoen.ie_koto` はPlay Console未登録。登録・アップロード・公開は所有者の承認後に行う。

- applicationId: `com.neoen.ie_koto`（維持、無断変更しない）
- versionName `0.1.0`／versionCode `1`（初回。更新時はビルド番号を再利用しない）
- compileSdk 36／minSdk 24／targetSdk 36（Flutter 3.44.0の既定）
- 照合対象は **アップロード証明書** のSHA-256（Play Console → 設定 → アプリの署名）。配信用のアプリ署名証明書（Google管理）とは別物であり、取り違えないこと。
- 新規登録時はPlay App Signingを有効にし、アップロード鍵として今回作成の鍵を使う。

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
- 最新の保存・同期入力境界・時計上限の安全停止回帰を含むアプリ全240テスト（同期/非同期保存失敗時の最新編集復旧・送信済み位置再試行を含む）、静的解析、`git diff --check` は成功。件数は `flutter test` 最終行の `+N: All tests passed!` とする。サーバー全25テストも成功（serverのnpm testで全テストファイルを実行、`# pass 25`・skip 0）。`flutter pub get --enforce-lockfile` も成功。
- 実Chrome debugモードで320×568の基本操作・保存からの再生成E2Eが成功。
- Pixel_6_API_35エミュレーターの通常アプリは上書きせず、別ID `com.neoen.ie_koto.verification` でdebug E2Eを実行し成功。追加・コメント・完了/取り消し・改名・SharedPreferencesからのストア再生成・くりかえし選択を確認した。
- AndroidのIME表示時に縦overflowを発見し、Widget回帰テストでも修正前の失敗を確認。IME表示時の補助選択肢折りたたみ（選択値は保持）と空状態のスクロール対応で修正後に成功。追加の回帰assertionで担当・明日の期限が折りたたみ中の登録にも残り、IME解除で選択肢が戻ることを確認（小画面2テスト成功、静的解析問題なし）。
- 通常エントリポイント `lib/main.dart` の別ID debug APKで、ネイティブタップによる `ProcessRestartCheck` の追加後、`adb shell am force-stop com.neoen.ie_koto.verification` →再起動を確認。PIDは6092から6252へ変わり、再インストールなしで追加した項目が画面に復元された。同期未設定のローカル保存のみの検証。スクリーンショットは `build/android-process-restart.png`（生成物）に保存。
- 別ID debugアプリで `integration_test/two_users_test.dart` がAndroid上でも成功。ADB reverseでメモリ上Workerへ実HTTP接続し、依頼・担当・双方コメント・到達不能APIでの未送信保持・再送後の完了共有・重複なし・改名共有と端末本人の独立を確認。
- これは1エミュレーター内の2つのストアを切り替える検証で、2実端末ではない。同期はテストから明示実行し、ネットワーク遮断や自動タイマー・背景復帰同期は対象外。
- 端末再起動、2実端末のrelease HTTPS同期、背景復帰時の自動同期検証は未完了。debugエミュレーター結果をrelease実機合格と混同しない。
- （2026-10-16）既存の本番アップロード鍵を用い、`android/key.properties`（`C:/Users/neoen/.android/release-keys/ie-koto-upload.jks`、別名 `upload`、gitignore済み・値は非表示）を設定して `flutter clean` → `flutter build appbundle --release` を実行。署名済みAAB `build/app/outputs/bundle/release/app-release.aab`（53.4MB、versionName `0.1.0`／versionCode `1`）を生成（exit 0、Gradle `bundleRelease` 約81秒）。環境は Flutter 3.44.0（stable）/ JDK 17.0.19。手順書（22〜31行）のビルド陳腐化回避のためクリーン＋依存再解決つきで実行した。
- （2026-10-16）`jarsigner -verify <aab>` は exit 0（署名済み・改ざん検出なし。JarFile/JarInputStreamの差に関する情報メッセージのみ）。`keytool -printcert -jarfile <aab>` の署名証明書SHA-256は `5F:1D:60:1D:EA:A3:A6:48:7B:CA:17:6B:55:E3:CE:8A:C9:75:6D:E3:A3:F9:BC:5B:72:3C:62:58:A1:93:52:36` で、記録済みの本番アップロード証明書と一致（`CN=ie_koto, OU=neoenox, O=neoenox, C=JP`）。署名があるだけでは不十分で、指紋一致まで確認した。
- （2026-10-16）release merged Manifest（`build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml`）で package `com.neoen.ie_koto`、`android.permission.INTERNET` あり、リテラルの改行・バッククォート混入なしを確認。AndroidX標準の `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` も付与されている。
- （2026-10-16）成果物AABのSHA-256は `DA6202DEA33E6B8A96F459F347CD219E9431103F5C42BD04283D4AA4217EF9B7`。同一入力でのバイト同一再現確認は未実施（2026-10-12の記録とは別ビルド）。`flutter analyze` は問題なし、`flutter test --concurrency=1` は41ファイル／257件成功（exit 0）。
- 残る未完了：Play Consoleへのアップロード・内部テスト配布と実機release同期（#60/#62/#63）は所有者承認後。AABファイル自体は配布物であり、Gitには含めない。
- リポジトリ内に既存の配布用鍵・key.propertiesは見つからない。鍵を新規作成・置換していない。
- （2026-10-16）署名済みrelease AABの生成とアップロード鍵証明書の照合まで完了。実機release同期・Play配布・本番相当環境は未完了（#60/#62/#63）。この文書を実機合格の証拠にしない。
