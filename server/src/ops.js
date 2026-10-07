/**
 * op の預かり所。Cloudflare D1（SQLite）の上で動く。
 *
 * ここは「突き合わせ場所」なので、op の中身（payload）は解釈しない。
 * 預かって、挿入順に返すだけ。解釈するのは端末側（lib/sync/log.dart）。
 *
 * 決めごと（docs/SYNC_DESIGN.md §3）:
 * - op_id が主キー。同じ op を何度送っても増えない（二重送信安全）
 * - cursor は世帯ごとの挿入順。`seq > since` を順に返す
 * - 世帯の行は、最初のアクセスで、そのとき提示されたトークンで作られる
 */

/** 1回の POST で受け取る op の上限。超えたら 400（端末側が分けて送る）。 */
export const MAX_OPS_PER_POST = 200;

/** GET の既定の件数。`limit=0` で無制限。cursor が続きを指すので、端末は繰り返せばよい。 */
export const DEFAULT_PAGE = 1000;

/** GET の件数の上限。-1 は SQLite の LIMIT 無制限。 */
export function clampLimit(raw) {
  if (raw === undefined || raw === null || raw === '') return DEFAULT_PAGE;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) return null;
  if (value === 0) return -1;
  return Math.min(Math.floor(value), DEFAULT_PAGE);
}

/** トークンは平文で持たない。SHA-256（WebCrypto は Workers にも Node にもある）。 */
export async function hashToken(token) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * 世帯の行を用意する。無ければ、いま提示されたトークンで作る（最初の1回だけ）。
 * トークンが違えば false。初回のアクセスが所有人的な意味を持つので、
 * 世帯id は推測できない乱数にすること（招待リンクに埋め込む）。
 *
 * @returns {Promise<boolean>} このトークンで書き込んでよいか
 */
export async function ensureHousehold(db, householdId, tokenHash, now) {
  await db
    .prepare(
      'INSERT INTO households (id, token_hash, seq, created_at) VALUES (?, ?, 0, ?) ON CONFLICT(id) DO NOTHING',
    )
    .bind(householdId, tokenHash, now)
    .run();

  const row = await db.prepare('SELECT token_hash FROM households WHERE id = ?').bind(householdId).first();
  return row !== null && row !== undefined && row.token_hash === tokenHash;
}

/**
 * `GET /ops?household=<id>&since=<cursor>`
 * since より後の op を、挿入順（seq の昇順）で返す。
 *
 * cursor は「ここまで返した」位置。1件も返せなかったときは since を返すが、
 * since が実在する位置より先（端末が飛び越した）なら、実在する位置まで戻す。
 * 端末は cursor をそのまま覚えればよい。
 */
export async function pullOps(db, householdId, since, limit, issueId = null) {
  // issueId を渡すと、その1件のopだけを返す（1件リンクのページ用）。
  // 世帯の全部を相手のブラウザに置かないための絞り込みで、cursor の意味は変わらない。
  const filter = issueId ? ' AND issue_id = ?' : '';
  const rows = await db
    .prepare(`SELECT seq, payload FROM ops WHERE household_id = ? AND seq > ?${filter} ORDER BY seq LIMIT ?`)
    .bind(householdId, since, ...(issueId ? [issueId] : []), limit)
    .all();

  const ops = [];
  let lastSeq = null;
  let skipped = 0;
  for (const row of rows.results ?? []) {
    try {
      ops.push(JSON.parse(row.payload));
      lastSeq = Number(row.seq);
    } catch {
      // 壊れた行は返さない（1件のせいで世帯ぜんぶが読めなくなるより、飛ばす方がまし）。
      skipped += 1;
    }
  }

  if (lastSeq !== null) return { cursor: lastSeq, ops, skipped };

  const household = await db.prepare('SELECT seq FROM households WHERE id = ?').bind(householdId).first();
  const current = Number(household?.seq ?? 0);
  return { cursor: Math.min(since, current), ops, skipped };
}

/**
 * `POST /ops`。追記のみ。すでにある op_id は黙って落とす。
 *
 * 既にあるものを確認し、番号の確保と挿入を同じbatchで確定する。
 * （D1 は無料枠でサブリクエスト数に上限があるので、op ごとに1往復させない）
 */
export async function pushOps(db, householdId, incoming, now) {
  const wanted = new Set(incoming.map((op) => op.id));
  const exists = await existingOpIds(db, householdId, [...wanted]);
  const fresh = incoming.filter((op) => !exists.has(op.id));

  if (fresh.length === 0) {
    const household = await db.prepare('SELECT seq FROM households WHERE id = ?').bind(householdId).first();
    return { cursor: Number(household?.seq ?? 0), accepted: 0, duplicates: incoming.length };
  }

  // D1のbatchはトランザクション。番号だけ先に公開すると、後から小さいseqの
  // opが挿入され、進んだcursorでは取得できなくなるので、必ず挿入と同時に確定する。
  const reserve = db.prepare('UPDATE households SET seq = seq + ? WHERE id = ?')
    .bind(fresh.length, householdId);
  const statements = fresh.map((op, index) =>
    db
      .prepare(
        `INSERT OR IGNORE INTO ops
           (household_id, op_id, seq, device_id, lamport, kind, issue_id, payload, at, received_at)
         VALUES (?, ?, (SELECT seq FROM households WHERE id = ?) - ? + ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        householdId,
        op.id,
        householdId,
        fresh.length,
        index + 1,
        op.deviceId,
        op.lamport,
        op.kind,
        op.issueId,
        JSON.stringify(op),
        op.at,
        now,
      ),
  );
  // batch は D1 では1回の往復で済む（op ごとに往復しない）。
  const results = await db.batch([reserve, ...statements]);
  const accepted = results.slice(1).reduce((sum, result) => sum + Number(result?.meta?.changes ?? 0), 0);
  const household = await db.prepare('SELECT seq FROM households WHERE id = ?').bind(householdId).first();

  return {
    cursor: Number(household?.seq ?? 0),
    accepted,
    duplicates: incoming.length - accepted,
  };
}

/**
 * 世帯を消す。op と世帯の行を両方消す（端末の記録は残る）。
 * トークンを知っている人だけが呼べる。消した後の cursor は 0 から。
 */
export async function deleteHousehold(db, householdId) {
  await db.prepare('DELETE FROM share_tokens WHERE household_id = ?').bind(householdId).run();
  await db.prepare('DELETE FROM ops WHERE household_id = ?').bind(householdId).run();
  await db.prepare('DELETE FROM households WHERE id = ?').bind(householdId).run();
  return { deleted: true };
}

/**
 * 世帯トークンを作り直す。古いトークンで認証した上で、新しいハッシュに置き換える。
 * op と cursor はそのまま（取り直しは端末側が cursor=0 でやる）。
 *
 * @returns {Promise<boolean>} 世帯が存在して置き換えたか
 */
export async function rotateToken(db, householdId, tokenHash, now) {
  const result = await db
    .prepare('UPDATE households SET token_hash = ?, created_at = ? WHERE id = ?')
    .bind(tokenHash, now, householdId)
    .run();
  return Number(result?.meta?.changes ?? 0) > 0;
}

/** すでに預かっている op_id。バインドの上限（100）を超えないよう分けて聞く。 */
async function existingOpIds(db, householdId, ids) {
  const found = new Set();
  for (let start = 0; start < ids.length; start += 90) {
    const chunk = ids.slice(start, start + 90);
    const placeholders = chunk.map(() => '?').join(', ');
    const rows = await db
      .prepare(`SELECT op_id FROM ops WHERE household_id = ? AND op_id IN (${placeholders})`)
      .bind(householdId, ...chunk)
      .all();
    for (const row of rows.results ?? []) found.add(row.op_id);
  }
  return found;
}
