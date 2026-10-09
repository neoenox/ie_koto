# 画面操作E2E

Flutter `integration_test` を実Chromeで実行する。通常の `flutter test`（Widgetテスト）とは別の検証。

名簿・担当のオフライン再起動と復旧の検証記録は [OFFLINE_ROSTER.md](OFFLINE_ROSTER.md) を参照。

## 前提

- Flutter SDK、Chrome、およびChromeと互換性のあるChromeDriver。
- Node.js 22.13以降（`node:sqlite` が必要）。
- リポジトリのルートで `flutter pub get` を実行する。
- 本番APIや実際の世帯には接続しない。

## 実行

別ターミナルでChromeDriverを起動する:

```powershell
chromedriver --port=4444
```

別ターミナルでテスト専用Workerを起動する（DBはメモリ上、停止すると消える）:

```powershell
node --experimental-sqlite server/test/serve.mjs --port 8799
```

ルートから順番に実行する:

```powershell
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/app_flows_test.dart -d chrome --browser-name=chrome --headless
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/two_users_test.dart -d chrome --browser-name=chrome --headless --dart-define=E2E_API_URL=http://127.0.0.1:8799
```

終了後はWorkerとChromeDriverをCtrl+Cで停止する。ポートを変える場合は起動引数と `E2E_API_URL` を一致させる。

## ケース

- [基本操作](../integration_test/app_flows_test.dart): 追加、コメント送信で未完了を維持、完了、取り消し、名前の連続編集、端末保存からの再起動、コメント復元、320×568の描画領域で最後のくりかえしを選択。
- [2人のやり取り](../integration_test/two_users_test.dart): Aの追加→Bの担当引き受け→双方のコメント→オフライン中のコメント・完了→再接続→重複なし→名前共有と端末本人設定の独立。

2026-10-08、基本操作全体を先頭から320×568で実Chrome debugモード実行し、成功した。世帯設定のoverflow原因と修正前後の結果は [調査記録](E2E_KNOWN_ISSUES.md) を参照。文字拡大と全画面の網羅検証は別途必要。

この環境ではChrome debug接続が一度失敗し、停止後の再実行で成功した。profileモードは失敗詳細が出ないため、成功の証拠として使用していない。

前面自動同期（#50 / #51）の独立2ブラウザ検証記録と保存状態の意味は [前面同期の説明](FOREGROUND_SYNC.md) を参照。

## 検証の境界

- 2ユーザーは別々の `IssueStore` / `SyncSession` / 端末IDで分離する。1つのChrome内でアプリを切り替えて双方の画面を操作する。同時に2つのブラウザを開くテストではない。
- 通信は実HTTP→本番Workerのfetch→SQLite。画面への入力はFlutterのテストAPIを利用する。
- 同期はテストから明示的に実行する。アプリ自身の自動送信タイマー・ライフサイクル復帰による同期は、このテストの対象外。
- オフラインは到達不能なAPIへの同期失敗を検証し、未送信データを正しいAPIへ再送する。ブラウザ全体のネットワーク遮断ではない。
- 保存のテストは本物のSharedPreferencesをテスト専用プレフィックスで利用し、終了時にその領域だけ消す。アプリをアンマウントし、保存から新しいストアを生成して復元を確認する。ブラウザプロセスの再起動ではない。
- Android固有のキーボード・バックキー・OSによるプロセス終了は別途実機検証が必要。
- 既存の [Worker E2E](../test/sync_worker_e2e_test.dart) と [1件リンクE2E](../test/one_link_worker_e2e_test.dart) は `flutter test` で引き続き実行される。
