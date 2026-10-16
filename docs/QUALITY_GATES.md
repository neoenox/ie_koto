# PR品質ゲートと配布判断（#68）

## 自動チェック

[Quality workflow](../.github/workflows/quality.yml) はPR、main/masterへのpush、手動実行で動く。読み取り権限のみ。Flutter 3.44.0、Node 22.19.0を使い、以下を失敗時停止で順番に実行する。

1. lockfileを強制した依存解決
2. Flutter静的解析
3. 全Flutterテスト（ローカルHTTP→Worker→SQLiteの検証も含む）
4. サーバーSQLiteテスト
5. 通常Webビルド
6. 差分の空白チェック

`release-compile` ジョブ（#126で追加）は `checks` とは別に走り、CI実行時だけ有効な一時鍵（`$RUNNER_TEMP` 内、乱数合言葉、ログ出力なし）で `flutter build appbundle --release` を行い、`jarsigner` で一時鍵の署名（`CN=ci-temp`）とAndroid Debug署名が無いことを確認してから鍵材料を破棄する。本番の署名鍵には触れない。

本番資格情報は不要。デプロイ、DB変更、本番署名、Playアップロードは行わない。サーバーにnpm依存がないため、npm install/npm ciは不要。Web生成物はテスト用で、公開成果物ではない。

## まだ自動化していない範囲

- 実Chromeのintegration_test、AndroidエミュレーターE2E、強制終了復元
- 正式署名済みAndroid AAB、証明書照合
- 本番相当Cloudflare/D1・認可・2実端末HTTPS同期
- 依存の脆弱性監査、署名付き成果物の保管

このworkflow単独で公開可と判断しない。画面E2Eは [E2E_TESTING.md](E2E_TESTING.md)、Androidの境界は [ANDROID_RELEASE.md](ANDROID_RELEASE.md) を参照。

## 最新ローカル検証の範囲

- 同期/非同期保存失敗中の追加編集と送信済み位置の保存再試行回帰を含むFlutter全249件・解析・サーバー全27件・差分チェックが成功（exit 0）。件数は `flutter test` 最終行の `+N: All tests passed!`（test/配下の合計）とする。内訳は #108時点のmain 243件 → #119の保存復旧2件 → #118の#110/#111回帰3件で248件 → #120の小画面回帰1件で249件。JSONレポーターで37スイートすべてが読み込まれることを確認した。
- Web releaseビルドとactionlintは全182件の時点で成功。その成果物は独立Chromeの320×568で追加・reload後の復元・完了を確認済み（[記録](E2E_KNOWN_ISSUES.md)）。以後の変更は保存回帰テストと検証文書。182件は当時の `flutter test` 最終行の値であり、現在の合計ではない。
- 保存復旧のコメント本文・復元後ID非重複assert強化後、送信済み位置の復旧2件も追加してFlutter全240件→解析→サーバー全25件→差分チェックを同じ連続コマンドで再実行し成功（exit 0、server skip 0）。サーバー件数は `server/npm test` の `# pass N` とする。その後DRAFT #47由来の共有トークン権限分離・ページング再取得2件を追加し、サーバー全27件で再成功（exit 0、skip 0、#106）。さらに#108の詳細完了ボタンFilled化の回帰1件を追加し、Flutter全243件で再成功（exit 0）。その後#110の未送信統合・削除の表示回帰2件と#111の対応表保存の重複排除回帰1件を追加し、Flutter全246件で再成功（exit 0、#118）。E2Eの名簿仕様追随と追加ダイアログの縦overflow修正の回帰1件を加え、Flutter全249件で再成功（exit 0、#120）。サーバーの最新成功は27件検証回である。
- 実機IME・OS再起動・オフラインreload・正式署名・実2端末HTTPS/D1・ホストCIは未検証。このローカル合格だけで配布しない。
- 2026-10-13: 並列実行の `flutter test` でテストファイルごと黙って読み込まれない場合がある（`sync_worker_e2e` 3件の欠落を2回確認、失敗0・exit 0のまま）。`flutter test --concurrency=1` では40ファイルすべて読み込み・249件成功を確認。件数の確定が必要な検証回では直列実行を用いる。（注：合計値は追記で残し、既存の行を書き換えない）
- 2026-10-16: `flutter analyze` 問題なし、`flutter test --concurrency=1` は41ファイル／257件成功（exit 0）。本番アップロード鍵（`android/key.properties`、gitignore済み）で `flutter clean` → `flutter build appbundle --release` を実行し署名済みAABを生成（`build/app/outputs/bundle/release/app-release.aab`、53.4MB、`0.1.0+1`、exit 0）。`jarsigner -verify` exit 0、署名証明書SHA-256は本番アップロード証明書と一致（`CN=ie_koto`）。release merged ManifestにINTERNETあり。詳細は [ANDROID_RELEASE.md](ANDROID_RELEASE.md)。CIの `release-compile` は引き続き一時鍵で、本番署名AABはローカル手動（この範囲は自動化しない）。実機release受入・Play配布は未完了（#60/#62/#63）。
- 2026-10-16: 公開用の説明文 [PRIVACY.md](PRIVACY.md) を追加し、世帯シートにプライバシー導線（要点ダイアログ＋公開URLコピー）と回帰テスト1件を追加。`flutter analyze` 問題なし、`flutter test --concurrency=1` は41ファイル／258件成功（exit 0）。
- 2026-10-16: 運用（#66）として server に死活確認 `GET /healthz`（認証不要・DB非依存・GETのみ200）を追加し、`wrangler.toml` に Workers Logs（`[observability] enabled = true`）を有効化。監視・レート制限・容量/費用・障害時初動を [OPERATIONS.md](OPERATIONS.md) に記録。サーバー `npm test` は全28件成功（exit 0、skip 0）。Flutter側のコード変更はなし。
- 2026-10-16: 復旧（#65）として [RECOVERY.md](RECOVERY.md) を追加（端末移行の復旧範囲、D1のバックアップ/復元、保持方針、アクセス管理、復旧後の cursor・重複・整合性、RPO/RTO、利用者/運用者の手順）。`server/test/backup_restore.test.mjs` で全行ダンプ→別DBへの復元を実証（cursor の続き・二重送信防止・壊れた行の飛ばし・削除後のバックアップ）。[PRIVACY.md](PRIVACY.md) にバックアップ保持の扱いを追記して整合。サーバー `npm test` は全31件成功（exit 0、skip 0）。Flutter側のコード変更はなし。
- 2026-10-16: 認可・秘密情報（#67）として [SECURITY.md](SECURITY.md) を追加（認可モデル、検証結果の対応表、秘密値の露出経路の棚卸し、本番構成の要件、残存リスク）。`server/test/security.test.mjs` で穴を補完（別世帯の管理操作の拒否・削除後の再作成の実挙動・入力の形とサイズ上限・平文の秘密がDBに無い・期限の境界・CORSの反射）。サーバー `npm test` は全37件成功（exit 0、skip 0）。Flutter側のコード変更はなし。
- 2026-10-16: ストア掲載（#69）として表示名を `いえこと` に統一し、配布用アイコン（適応型・ラウンド・Web）とフィーチャーグラフィックを用意、Webメタデータ（`index.html`/`manifest.json`）を更新。エミュレーター実画面のスクリーンショット4枚を 2:1 以内に整えて [STORE_LISTING.md](STORE_LISTING.md) に掲載文・データ申告・初回起動デモの公開仕様を記録。`flutter build apk --debug` でリソース妥当性を確認（debug APKはGitに含めない）。掲載文の入力、AABの内部テスト配布、実機release同期は所有者承認後（#60）。
- 2026-10-16: 初回利用・日本語入力・文字拡大・読み上げ・コントラスト（#70）として、IMEの確定/Enter（二重送信なし・変換中は未登録）と追加ボタン連打を [test/ime_submit_test.dart](../test/ime_submit_test.dart) に3件、実テーマの色からWCAG AAコントラスト（本文16.4:1／説明文8.9:1／エラー6.2:1／強調6.2:1／通知7.2:1／選択チップ5.2:1）を [test/contrast_test.dart](../test/contrast_test.dart) に1件追加。結果と人の手で残す範囲を [VERIFICATION.md](VERIFICATION.md) の #70 節に記録。`flutter analyze` 問題なし、`flutter test --concurrency=1` は43ファイル／262件成功（exit 0）。Flutter側の製品コード変更はなし。

## GitHub上の運用

ホストされたrunner（GitHub Actions）での成功を確認済み。PR #118〜#126 の各PRで Quality / Validation の両方が success。統合後のmain `bbf457e` でも Quality（`checks`＋新規 `release-compile`、run 38396528065）と Validation（run 38395889069）が success。

同じrefへ連続pushすると、`concurrency` の `cancel-in-progress` により先行runが cancelled になる（commitの作成順とrunの作成順は一致しない）。tipの結果が cancelled のまま残った場合は `gh workflow run quality.yml --ref main` で取り直し、そのrunの `headSha` がtipと一致することを確認してから合格根拠にする。

ローカルではFlutter 3.44.0/Node 22.19.0で178テスト（曜日とカスタム日付の拒否時保持・正常保存、完了→保留と複数次回生成のロールバック回帰を含む）、静的解析（問題なし）、差分チェックが成功（時計上限の安全停止・入力保持・取り消し・保存復元後の通知/送信抑制回帰を追加後）。最新の小画面文字2倍＋キーボード回帰と現行ワークスペースの書式/lint更新を含む検証で、Flutter全180件・解析・差分チェックを再確認した（exit 0）。さらに背景編集保持と320px文字2倍の再試行UI回帰を含む全182件・解析・Web releaseビルド・actionlint・差分チェックが連続成功（exit 0）。Webビルド成功は実ブラウザ実行成功ではなく、Wasm関連の警告も合格根拠にしない。サーバー全23件は180件の検証回で再実行し全成功、skip 0（exit 0）。現在のコードで `flutter build web --no-pub` も成功（Wasm dry run成功。ただしWasm版の実行検証ではない）。以前の `flutter pub get --enforce-lockfile` も成功した。Windowsに既存のactionlint 1.7.12があることを確認し、`actionlint .github/workflows/quality.yml` を実行して指摘なし・exit 0を確認。これはローカル静的検証であり、Ubuntu runnerの成功根拠には使わない（runnerの成功は上記の別runで確認した）。必須status checkの設定は未実施。

WindowsのChrome runnerではFlutter SDKのCanvasKitルートに区切り文字不一致があり、通常実行がsuite読込みで停止した。診断用CDPでSDK既存CanvasKitの2ファイルだけを配信した条件ではwire全11件成功。保存テストは11件成功・1件がdart:ioのテスト補助HTTPサーバー非対応で失敗（exit 1）。通常runnerやブラウザ保存E2Eの成功とは扱わず、詳細と制約は [SYNC_INPUT_LIMITS.md](SYNC_INPUT_LIMITS.md) を参照。

全テスト再実行で自動送信テストの競合を検出した。サーバー受信の観測だけではクライアントのHTTP応答処理が終わっていないため、受信とoutboxの空状態の両方を待つようテストを修正した（製品コード変更なし）。修正後に153テスト・解析・差分チェックが再び成功。

リポジトリ管理者はマージ先ブランチに `checks`・`release-compile` の必須status checkとレビューを設定することが望ましい。workflow追加だけではマージは禁止されない。runnerの実行自体は上記のとおり確認済みだが、`main` は現在もブランチ保護が無く、必須status checkは未設定。

## 実ブラウザ保存の限定検証

ビルド済みWebを127.0.0.1の一時静的サーバーで配信し、agent-browserの隔離セッションで追加欄へ識別用タイトルを入力・Enterで保存した。実localStorageの世帯soloのops.0にタイトルが含まれることを確認し、ページをreloadして同じ依頼の表示を確認。reload後はデモを再投入せず保存した1件だけが表示された。ブラウザerrors出力は空。Flutter semantics placeholderへDOM clickを送り操作用のアクセシビリティツリーを有効化した。CanvasKit差替え・SDK変更・API mockは使っていない。検証終了後、隔離ブラウザと一時サーバーを停止した。

さらに専用の永続profile（ignoredな.dart_tool配下）を新規使用して別の識別用依頼を入力した。localStorage保存を確認後agent-browser closeで隔離ブラウザを終了し、同じdisk profileを指定して再起動。依頼1件の復元とデモ未再投入をアクセシビリティツリーで確認、errors出力は空。state export/importによる模擬復元は使っていない。再度ブラウザと一時サーバーを停止した。

同じ専用profileで詳細からコメントを送信して完了し、ブラウザを終了・再起動した。ホームの未完了一覧から対象が消え、完了一覧に対象が1件あり、詳細のコメント本文と「おわった」履歴が復元されることを確認。errors出力は空。保存データの文字列に「done」が含まれるかという予備確認はfalseだったため、その文字列を完了保存の判定には使わず、再起動後の投影と履歴を成功根拠とした。

これは実SharedPreferencesブラウザ保存・同一セッションreload・ブラウザ終了後の同一profile再起動（追加・コメント・完了状態）の成功であり、強制終了・OS再起動・オフライン再読込み・2端末HTTPS同期・通常Chrome test runnerの成功ではない。本番やユーザーのChromeプロフィールは使っていない。

## 配布・ロールバックの手動ゲート

- 配布前にcommit、アプリversion/build番号、Workerバージョン、D1スキーマ、バックアップ位置を記録する。
- 正式鍵の証明書照合と内部テストを通し、少人数で開始する。
- 保存不整合、認可逸脱、データ損失が出たら配布を停止する。データを壊す操作やDB巻き戻しを即実行しない。
- Web/Workerは既知の互換バージョンへ戻す計画を用意する。D1復旧は保存データとの整合を確認してから担当者が行う。
- Androidは一般に既存端末へ低いversionCodeをインストールできない。前の実装を含む、より高いbuild番号の修正版を用意する。署名鍵・applicationIdは維持する。

実際の本番復旧手順と監視担当者は別途確定が必要。#68全体は未完了。
