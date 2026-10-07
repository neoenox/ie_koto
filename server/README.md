# いえこと の同期サーバー

Cloudflare Workers + D1。操作ログ、世帯、メンバー名の同期を行う。
基本の2本は「op（操作ログ）を預かって、挿入順に返す」だけ。
突き合わせの中身（どのopが勝つか、次の1件をどう決めるか）は端末側が決める（[../lib/sync/log.dart](../lib/sync/log.dart)）。

```
GET  /ops?household=<id>&since=<cursor>[&limit=<n>][&issue=<id>]   増分をもらう
POST /ops  {"household": "<id>", "ops": [...]}                    自分のopを送る
DELETE /ops?household=<id>                                        世帯を消す（opと世帯の行。端末の記録は残る）
POST /household/rotate  {"household": "<id>", "token": "<新しいトークン>"}   トークンを作り直す
POST /household/members/migrate  旧 me/partner を世帯共通IDへ一度だけ移行
GET  /household/members?household=<id>                              メンバー一覧
POST /household/members  {"household":"<id>","id":"mem_…","name":"…"} 表示名を保存
```

どれも `Authorization: Bearer <世帯トークン>` が要る。

| 決めごと | 内容 |
|---|---|
| 世帯 | 最初のアクセスで作られる。**そのとき提示されたトークンが、その世帯の鍵になる**。以後、違うトークンでは読めない・書けない |
| トークン | 32バイト以上の乱数。サーバーは **SHA-256 のハッシュだけ**を持ち、平文は保存しない |
| cursor | 世帯ごとの挿入順（単調増加）。`since` より後を順に返す。応答の `cursor` は「ここまで返した」位置 |
| ページング | `limit`（既定1000、`0`で無制限）。端末は空が返るまで `since=cursor` で繰り返せばよい |
| 1件だけ | `issue` を付けると、その1件のopだけを返す（**1件リンク**のページ用）。相手のブラウザに世帯の記録を置かないための絞り込みで、cursorの意味は変わらない |
| 二重送信 | `op_id` が主キー。すでにあれば増えず、cursorも進まない |
| まとめて断る | 1件でも形が壊れていたら **400**。中途半端に預けると、端末の送信待ちが消えてしまうため |
| 壊れた行 | 読めないpayloadは飛ばして返す（1件のせいで世帯が読めなくならない） |
| 上限 | 1回のPOSTは200件まで。本文は1MBまで |
| 削除 | `DELETE /ops?household=<id>`。opと世帯の行を消す。消した後の最初のアクセスで、空の世帯が作り直される |
| 作り直し | `POST /household/rotate`。古いトークンで認証し、新しいトークンのハッシュに置き換える。opとcursorはそのまま。短いトークンは400 |

失敗の返し方は `401`（トークン違い）／`400`（形が違う）／`500`。

## 手元で動かす

Worker のコードをそのまま Node の HTTP サーバーに載せて動かせる（D1 だけ `node:sqlite` で真似る）。
Cloudflare のアカウントが無くても、アプリと同期のテストができる。

```bash
cd server
npm test                                          # Workerのテスト（20件・本物のSQLで）
npm run serve -- --port 8799                      # メモリ上のDBで起動
npm run serve -- --port 8799 --db ./local.db      # ファイルに残す
```

アプリ（Flutter）からつなぐには、世帯idとトークンを自分で決めて渡す。
世帯idは16〜64文字の `[A-Za-z0-9_-]`、トークンは32文字以上。

```bash
# 例: 端末1
flutter run -d web-server --web-port 8080 \
  --dart-define=IE_KOTO_API=http://127.0.0.1:8799 \
  --dart-define=IE_KOTO_HOUSEHOLD=hh_wagaya00000000000000000000000000 \
  --dart-define=IE_KOTO_TOKEN=8f3c1d5e7a9b2c4d6e8f0a1b3c5d7e9f2a4b6c8d0e
```

同じ2つの値を別の端末（または別のブラウザ）で使えば、同じ世帯になる。

## デプロイ

```bash
cd server
npx wrangler d1 create ie_koto                    # 出た database_id を wrangler.toml に貼る
npx wrangler d1 execute ie_koto --remote --file=./schema.sql
npx wrangler deploy
# うまくいかないときは、先にログインしておく
npx wrangler login
```

環境変数（設計のメモ）: `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_API_TOKEN` を CI から使う場合は設定する。

本番では、この Worker と同じドメインに Flutter Web のビルド（`build/web`）を置く。
そうすると、アプリ・招待リンク・APIが1つのドメインで完結する（CORSも証明書も考えなくていい）。

## 確かめてあること

`npm test` の20件は、**schema.sql と src/ をそのまま**動かして確かめている（差し替えているのは D1 だけ）:
挿入順の取り出し、差分、二重POST、同時POST、ページング、世帯ごとの独立、トークンの拒否、
壊れたopの拒否（まとめて400）、件数上限、`derivedFrom` の保存、壊れた行の読み飛ばし、CORS、
`issue=` の絞り込み（ほかの案件が混ざらない・誰も知らないidは空・空文字と長すぎるidは400）、
トークンの作り直し（古い招待文の失効・短いトークンの拒否）、世帯の削除（opと世帯の行が消え、端末の記録は残る）。

Dart 側からは [../test/sync_worker_e2e_test.dart](../test/sync_worker_e2e_test.dart) が
`npm run serve` を起動して、**実際にHTTPで**2台の端末役を収束させる。
1件リンク（アプリを入れていない相手）は [../test/one_link_worker_e2e_test.dart](../test/one_link_worker_e2e_test.dart) が
同じやり方で通しで確かめる。実アプリ（Flutter Web）からの同期も確認済み（[../docs/VERIFICATION.md](../docs/VERIFICATION.md)）。

1件リンクを手元で見るには、アプリを `--dart-define` 付きで起動して、詳細の「そのほか」→「リンクを送る」で
コピーしたURLを、別のブラウザ（アプリを入れていない相手のつもり）で開く。
サーバーを `--log` 付きで起動しておくと、相手が `?issue=<id>` の1本しか投げていないことを目で見られる。

## まだやっていないこと

- レート制限、サイズの監視、不要になったopの整理（追記のみなので増え続ける）
- 個人ログインによる本人確認（世帯メンバーIDは認証情報ではない）
- OSのプッシュ通知（アプリ内のお知らせ1行＋担当通知は実装済み）
