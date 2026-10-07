-- いえこと の同期サーバー（Cloudflare Workers + D1）
-- 方針は docs/SYNC_DESIGN.md §3。op は追記のみ・op_id が主キー。

-- 世帯。最初のアクセスで作られる（トークンはハッシュで持つ。平文は保存しない）。
CREATE TABLE IF NOT EXISTS households (
  id         TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL,
  -- その世帯で最後に振った番号。cursor はこの値まで進む。
  seq        INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL
);

-- op（操作ログ）。中身（payload）はサーバーが解釈しない。
-- payload には op の JSON を丸ごと入れる（data と derivedFrom を落とさないため）。
-- 残りの列は、人が見て分かるように置いてあるだけ。
CREATE TABLE IF NOT EXISTS ops (
  household_id TEXT NOT NULL,
  op_id        TEXT NOT NULL,
  seq          INTEGER NOT NULL,
  device_id    TEXT NOT NULL,
  lamport      INTEGER NOT NULL,
  kind         TEXT NOT NULL,
  issue_id     TEXT NOT NULL,
  payload      TEXT NOT NULL,
  at           TEXT NOT NULL,
  received_at  TEXT NOT NULL,
  PRIMARY KEY (household_id, op_id)
);

-- 差分は「seq > since」を挿入順に引くだけなので、この索引で足りる。
CREATE INDEX IF NOT EXISTS ops_by_seq ON ops (household_id, seq);

-- 表示名（「自分」「パートナー」）。member との対応はまだアプリ側に無い（設計の手順3の残り）。
CREATE TABLE IF NOT EXISTS members (
  household_id TEXT NOT NULL,
  member_id    TEXT NOT NULL,
  display_name TEXT NOT NULL,
  PRIMARY KEY (household_id, member_id)
);

-- 個別共有鍵。指定案件に限定し、有効期限はサーバー側でも検査する。
CREATE TABLE IF NOT EXISTS share_tokens (
  token_hash TEXT PRIMARY KEY,
  household_id TEXT NOT NULL,
  issue_id TEXT NOT NULL,
  member_id TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS share_tokens_by_household ON share_tokens (household_id);
