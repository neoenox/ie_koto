# 公開構成のセキュリティ確認（#67）

公開（Cloudflare Workers + D1）に出す前の、認可・鍵・失効・秘密情報の最終確認。**実際の鍵・トークンはこの文書に書かない**（テストの値はすべてダミー）。

## 認可モデル

| 資格情報 | できること | 制限 |
|---|---|---|
| 世帯トークン（所有者） | その世帯の読取・書込・名簿・再発行・共有発行・削除 | `Authorization: Bearer`。サーバーは **SHA-256 ハッシュのみ**保存 |
| 1件共有鍵（ゲスト） | 指定した**1件**の取得と、その案件への「自分への割り当て（assignee）」op の追加 | **最大7日**で失効（サーバーで強制）。他案件・世帯管理は不可 |

- 世帯の行は**最初のアクセス**で作られ、そのとき提示したトークンが鍵になる。だから世帯idは推測不能な乱数にする（`^[A-Za-z0-9_-]{16,64}$`）。
- メンバーIDは**本人認証ではない**（[CONTEXT.md](../CONTEXT.md)）。認可はトークンの所持だけで決まる。
- 「誰が」は op の `deviceId`/`member` に残るが、なりすましは防がない（同一世帯内は相互信頼）。

## 検証したこと（自動テスト）

`server/` で `npm test`。schema.sql と src/ をそのまま動かし、差し替えるのは D1 だけ（[server/test/](../server/test/)）。

| 受け入れ条件 | 検証 | 場所 |
|---|---|---|
| 別世帯の読取/書込 | 401、データは変わらない | worker.test.mjs「トークンが違えば…」 |
| 別世帯の管理操作 | 名簿GET/POST/移行/まとめ/除外・再発行・共有発行・削除がすべて 401、副作用なし | security.test.mjs |
| 1件鍵で他案件 | 401（`issue` を指定しない全件取得も 401） | worker.test.mjs |
| 1件鍵で世帯管理 | 削除・再発行・名簿が 401 | worker.test.mjs「1件共有トークンでは…」 |
| 1件鍵で許可外op | 403 `share_scope`（案件違い・メンバー違い・`assigneeId` 違い・kind違い） | worker.test.mjs「1件リンクは…」 |
| 期限/失効のサーバー強制 | 期限切れ 401、**同時刻も 401**（`expires_at > now` の厳密比較） | worker.test.mjs, security.test.mjs |
| 世帯鍵再発行 | 古いトークン 401、新トークン 200 | worker.test.mjs「トークンを作り直せる」 |
| 削除 | op と世帯の行が消える。**削除後は空の世帯が作り直される**（下記・残存リスク） | security.test.mjs |
| 入力型・サイズ・不正op | 壊れたopはまとめて400、op数上限200、`limit`クランプ、`since`検証、本文1MB超/配列/文字列は400 | worker.test.mjs, security.test.mjs |
| 平文の秘密が残らない | `token_hash` は64桁16進のみ。DB全文に平文が無い | security.test.mjs |
| CORS | 既定は任意 `Origin` を反射、`ALLOWED_ORIGIN` で固定 | security.test.mjs |
| 死活確認 | `/healthz` は認証不要・DB非依存（秘密を返さない） | worker.test.mjs |

## 秘密情報の露出経路の棚卸し

| 経路 | 何が出うるか | 現状 | 判断・対策 |
|---|---|---|---|
| DB | 世帯トークン・共有鍵 | ハッシュのみ（64桁16進） | テストで担保。復旧ダンプもハッシュのみ（[RECOVERY.md](RECOVERY.md)） |
| サーバーログ | 例外の内容 | `console.error` はスタックのみ。トークン・本文・クエリ文字列を出さない | 監査済み（[OPERATIONS.md](OPERATIONS.md)） |
| URL | 世帯id・共有鍵 | 世帯idはクエリ。**共有鍵は1件リンクのURL/QRに含む** | 共有鍵は「URLが持つ資格情報」。7日失効・1件限定。[PRIVACY.md](PRIVACY.md) で説明 |
| 配布物（AAB/APK） | 署名鍵・key.properties | 署名情報はビルド時に読むだけでAPKに含まれない。`key.properties` は gitignore | 追跡ファイルに鍵なし（`git ls-files` で確認） |
| CI | 鍵 | GitHub Secrets を**使わない**。毎回その場で使い捨て鍵（`CN=ci-temp`）を生成し、終了後に削除 | 秘密を渡さない構成（[.github/workflows/quality.yml](../.github/workflows/quality.yml)） |
| 端末保存 | 世帯トークン・記録 | SharedPreferences（平文） | 端末の保護（画面ロック・暗号化）に依存。残存リスク |
| 書き出しJSON | op | トークン・世帯id・名簿は含まない（`exportJson` は op だけ。[RECOVERY.md](RECOVERY.md)） | 受け渡しは本人の管理 |

## 本番構成の要件（#62/#63 で適用する）

- **HTTPS のみ**。Cloudflare で HTTP→HTTPS リダイレクトと HSTS を有効にする。HTTP での API 利用は不可。
- `ALLOWED_ORIGIN` を**自ドメインに固定**する（現在は `*`＝反射。開発用の既定を本番に残さない）。
- レート制限（[OPERATIONS.md](OPERATIONS.md)）。
- Web（1件リンク）配信は Cloudflare の機能でセキュリティヘッダー（CSP 等）を付ける。インラインスクリプトを避ける。
- D1・アカウントは所有者のみ、2要素認証（[RECOVERY.md](RECOVERY.md)）。

## 残存リスク（記録）

1. **世帯削除後、トークン保持者は空の世帯を作り直せる**（データは戻らない）。「削除＝データ消去」であり「アクセス恒久拒否」ではない。必要なら tombstone（削除済みの記録）を将来検討。
2. **共有鍵は URL/QR に載る**（持っていれば誰でもその1件を読める）。7日失効と1件限定で緩和。
3. **端末の保存は平文**（SharedPreferences）。OS の保護に依存。
4. **CORS の既定は任意 Origin 反射**。トークンは `Authorization` ヘッダで自動送信されないため実害は限定的だが、本番は固定する。
5. **本文サイズ上限は「文字数」1MB**（UTF-8 では最大約4MB）。Cloudflare 側のリクエスト上限も効く。
6. **認可はトークンの所持のみ**（個人認証ではない）。メンバーIDは本人確認に使わない。
7. **レート制限・監視は設定と本番デプロイに依存**（#66・#62 が前提）。
8. 実際の Cloudflare 環境（HTTPS強制・HSTS・CSP・CORS固定）は**まだ未適用**（#62/#63）。ここでの確認はローカルの Worker/SQLite 上。
