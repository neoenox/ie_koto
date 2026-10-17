# リリース実行手順（所有者向け）

本番構成から内部テスト配布・実機受入までの**順番・コマンド・合否・止める条件**だけを置く。
中身の詳細は各文書に任せる（末尾の[関連文書](#関連文書)）。

エージェントが実行できる範囲（実装・自動テスト・署名済みAABの生成と照合・掲載素材・各種文書）は準備済み。
ここに残っているのは、**所有者のアカウント・実環境・実機が必要な操作**だけ。

## いまの状態（2026-10-17）

| 済み | 未 |
|---|---|
| 実装と自動テスト（Flutter 274件・server 37件・`flutter analyze` 問題なし） | Cloudflare 本番構成（`server/wrangler.toml` の `database_id` は未設定のプレースホルダ） |
| 署名済みAABの生成とアップロード証明書SHA-256の照合（2026-10-16） | 本番相当の通し検証（世帯共有・1件リンク） |
| 掲載素材（アイコン・フィーチャー・スクショ4枚）と掲載文・データ申告の下書き | 実機releaseでの受入 |
| 鍵の別媒体バックアップと指紋一致の確認 | Play Console の初回登録・内部テスト配布 |
| ADR／運用／復旧／セキュリティ／プライバシーの各文書 | 一般公開の判断 |

## 順番と依存

| 段 | やること | Issue | 前提 | 主な文書 |
|---|---|---|---|---|
| A | Cloudflare 本番構成（D1・HTTPS・同一ドメイン配信・CORS固定） | #62 | なし | [SECURITY.md](SECURITY.md) §本番構成の要件 |
| B | 本番相当の通し検証（2台・1件リンク・失効・削除） | #63 | A | [SYNC_DESIGN.md](SYNC_DESIGN.md) |
| C | レート制限・監視・予算アラート・復旧リハーサル | #66 #65 | A | [OPERATIONS.md](OPERATIONS.md) / [RECOVERY.md](RECOVERY.md) |
| D | Play Console 登録と内部テスト配布 | #69 | **先に再ビルド**（下記） | [STORE_LISTING.md](STORE_LISTING.md) §内部テスト配布 |
| E | 実機release受入（R1〜R6） | #60 | D | [RELEASE_ACCEPTANCE.md](RELEASE_ACCEPTANCE.md) |
| F | 段階公開 | #69の外 | E | [ANDROID_RELEASE.md](ANDROID_RELEASE.md) |

C は A の直後から B・E と並行してよい。B と E は別物（B は本番サーバーとの通し、E は実機の終了・復帰・オフライン）。

## 0. アップロード前に再ビルドする

手元の AAB `build/app/outputs/bundle/release/app-release.aab`（2026-10-16 12:35 生成）は、
**#57（詳細のメモ）と #133（招待の貼り付けで参加）より前**のコードで作られている。配布前に現在の `main` から作り直す。

- まだ一度も配布していないので `versionName 0.1.0` / `versionCode 1` のままでよい（**配布開始後は必ず増やす**）。
- ビルドと照合の手順・コマンドは [ANDROID_RELEASE.md](ANDROID_RELEASE.md) §公開成果物を作る／§署名の照合手順。
  - `flutter clean` のあと、`--no-pub` を付けずに `flutter build appbundle --release`（ビルド陳腐化の暫定回避策）。
  - アップロードするのは AAB。指紋照合は **アップロード証明書**（`5F:1D:…:36` / `CN=ie_koto`）と比べる。APKの照合は `apksigner`、AABは `jarsigner`。
- AAB（と `android/key.properties`）は Git に入れない。`storePassword`・トークン・世帯idは Issue・チャット・CIログに貼らない。

## A. Cloudflare 本番構成（#62）

```powershell
cd server
npx wrangler login                                   # 初回。2要素認証は必須（SECURITY.md）
npx wrangler d1 create ie_koto                       # 出力の database_id を server/wrangler.toml の該当行に貼る
npx wrangler d1 execute ie_koto --remote --file=./schema.sql
npx wrangler deploy
```

1. `server/wrangler.toml` の `database_id`（現在はプレースホルダ）を `d1 create` の値に置き換える。
2. `ALLOWED_ORIGIN = "*"` を**自ドメインに固定**する（開発用の既定を本番に残さない）。
3. Web版（1件リンクの受け皿）を **Worker と同じドメイン**に置く。どちらか一方：
   - Worker の Static Assets に `build/web` を載せる（`server/wrangler.toml` に `[assets]` と `directory` を足す）。
   - Cloudflare Pages に `build/web` を配信し、Worker を同じドメインのルートに載せる。
   - 要件は「**アプリ（Web）とAPIが同じドメイン**」であること。そうすれば CORS と証明書を考えなくてよく、1件リンクに `apiUrl` を書かずに済む（[lib/main.dart](../lib/main.dart) `_linkFor`）。
   - Web のビルドは `flutter build web --release`。`--dart-define` は不要（Webでは「場所」が開いたページのオリジンで埋まる。[lib/main.dart](../lib/main.dart) の `initialBaseUrl`）。
   - 画面遷移はURLの断片（`#join` / `#one`）なので、**SPA用のリライト規則は要らない**。
4. HTTP→HTTPS の強制と HSTS を有効にする（Cloudflare の SSL/TLS 設定）。
5. 確認：
   - `GET https://<ドメイン>/healthz` → `200 {"ok":true}`（認証不要・DB非依存）。
   - HTTP でアクセス → HTTPS へリダイレクトされる。
   - アプリ（Web）→ 世帯のシート → つくる → 「場所」が自分のドメインで埋まり、つくれる。
   - 許可していない `Origin` からのプリフライトが拒否される（CORS固定の確認）。

**止める条件**: `database_id`・オリジン・指紋のどれかが未確認のままデプロイしない。既存の別 Worker / 別 D1 を上書きしない。

## B. 本番相当の通し検証（#63）

本番URLに対して、テスト用の世帯で通す（本番の実データを使わない）。

- [ ] 2台（release APK / Web の組み合わせでも可）で世帯をつくり、片方を招待の貼り付けで参加させる
- [ ] 追加・完了・改名・コメント・担当・メモが両方とサーバーで一致する（重複・欠落なし）
- [ ] 1件リンク：アプリのないブラウザで開き「やる」を押す → 世帯側に反映され、他案件は見えない
- [ ] 1件リンクの失効（7日）と、そのURLで他案件が取れない（401）
- [ ] トークンを作り直す → 古い招待文が使えなくなる
- [ ] 世帯を削除 → サーバーの記録が消え、端末の記録は残る
- [ ] オフライン（機内モード）で編集 → 復旧 → 未送信が再送され重複しない
- [ ] `429`/`5xx` のときに送信待ちが残り、時間をおいて再送される

**止める条件**: 一致しない・重複する・想定外の5xxが出る場合は E に進まず、原因を潰す（必要なら Issue 化して #63 に紐付ける）。

## C. 運用の上限・監視・復旧（#66 / #65）

- レート制限を Cloudflare の Rate limiting rules で設定する（`/ops`・`/household/*`、目安は [OPERATIONS.md](OPERATIONS.md)）。
- Billing アラート（月 **$10** 目安）と、D1 storage **1GB** / Workers リクエスト **50,000/日** の目安を通知に設定する。
- Workers Logs（`[observability] enabled = true` 済み）で `console.*` を見られることを確認し、外部から `/healthz` を定期監視する。
- D1・Cloudflare アカウントを所有者のみにし、2要素認証を有効にする（[SECURITY.md](SECURITY.md)）。
- 復旧リハーサルを本番で1回行う（[RECOVERY.md](RECOVERY.md) の D1 バックアップと戻し）。
- [OPERATIONS.md](OPERATIONS.md) の「障害時の連絡先」を記入する（現在未確定）。

## D. Play Console 登録と内部テスト配布（#69）

手順は [STORE_LISTING.md](STORE_LISTING.md) §内部テスト配布。要点：

1. Play Console に初回登録（開発者契約・本人確認・支払い）。
2. アプリを作成し、**Play App Signing を有効化**。アップロード鍵は既存の鍵（指紋 `5F:1D:…:36`）。
3. 0 で作り直した署名済みAABを内部テストのトラックへアップロード（`versionCode 1`）。
4. テスターを追加して配布。掲載文・素材・データ申告は [STORE_LISTING.md](STORE_LISTING.md) のとおりに入力する。
5. プライバシーポリシーURLは現状 GitHub の [PRIVACY.md](PRIVACY.md) を指している（[lib/household_sheet.dart](../lib/household_sheet.dart) の `privacyUrl`）。A のあと本番ドメインへ移す場合は、アプリ側の値も変えて**再ビルド**する（配布済みなら `versionCode` を増やす）。GitHub のままでもよい。

**止める条件**: 指紋が一致しない・掲載文と実装（権限・デモ・データ申告）が食い違う場合はアップロードしない。

## E. 実機release受入（#60）

[RELEASE_ACCEPTANCE.md](RELEASE_ACCEPTANCE.md) の記録欄と受入項目 R1〜R6 を埋める。
2台あれば R3（2台の収束）も実施。結果の要約を #60 のコメントに貼る。未実施（−）は理由を明記する。

## F. 公開（#69の外）

内部テストで問題がないことを確認してから、段階公開（例：10% → 監視 → 100%）。
止める判断は [OPERATIONS.md](OPERATIONS.md) の「障害・容量超過時の初動」に従う（段階公開の停止はできるが、全公開後のAPKは取り下げられない）。

## 巻き戻し

- API: `npx wrangler rollback` で Worker を直前バージョンへ戻す。スキーマは追記のみなので戻さない。
- アプリ: Play の段階公開を停止し、修正版を上げる（`versionCode` を増やす）。
- 手元: 作業ブランチは残す。`force push`・`reset --hard`・`clean -fdx` は使わない。

## 記録

各段の結果は、その段の Issue のコメントに書く（#62 / #63 / #60 / #65 / #66 / #67 / #69）。
実施日・環境（機種/OS/ビルド番号/ドメイン）・合否・未実施の理由を残す。

## 関連文書

- [ANDROID_RELEASE.md](ANDROID_RELEASE.md): ビルドと署名、鍵の保全、Play Console 登録の前提
- [STORE_LISTING.md](STORE_LISTING.md): 表示名・掲載文・グラフィック素材・データ申告・内部テスト配布
- [RELEASE_ACCEPTANCE.md](RELEASE_ACCEPTANCE.md): 実機受入の記録用紙（#60）
- [OPERATIONS.md](OPERATIONS.md): 監視・レート制限・容量と費用（#66）
- [RECOVERY.md](RECOVERY.md): 端末移行と D1 のバックアップ・復旧（#65）
- [SECURITY.md](SECURITY.md): 認可・鍵・失効・本番構成の要件（#67）
- [PRIVACY.md](PRIVACY.md): 保存先・共有範囲・削除・申告との対応
- [server/README.md](../server/README.md): APIの形とデプロイ
