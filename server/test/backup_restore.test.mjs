import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import worker from '../src/index.js';
import { createD1 } from './d1.mjs';

/**
 * #65: D1 のバックアップ/復元を、隔離した検証環境（別の in-memory SQLite）で実証する。
 *
 * 本番の D1 には手が届かないので、`wrangler d1 export` が出す「行のダンプ」と同じ形
 * （全テーブルの全行）を取り、schema.sql を当てた**新しいDB**へ入れ直す。
 * 復元元は読むだけで書き換えない（隔離）。
 *
 * 確かめること:
 *   - op の中身と挿入順（seq）が戻る
 *   - 世帯の seq（cursor の上限）が戻る＝復旧後も「続き」から引ける
 *   - 二重送信しても増えない（op_id が主キー）
 *   - 復元後に新しい op を足しても番号が衝突しない
 *   - 名簿・個別共有鍵も戻る
 *   - 壊れた payload の行は飛ばすが、ほかの行は読める
 *   - 世帯を消したあとのバックアップには、消したデータが残らない
 */

const SCHEMA = readFileSync(new URL('../schema.sql', import.meta.url), 'utf8');

const TOKEN = 'h8Qw3ZrT9xYb2LmN4PvC6SdF7GhJ1KlZ3XcV5BnM7Qa';
const HOME = 'hh_RESTORE0000000000000000000000000000';
const MEMBER = 'mem_restore00000000000000000001'; // /^mem_[A-Za-z0-9_-]{16,48}$/

const TABLES = ['households', 'ops', 'members', 'member_aliases', 'share_tokens'];

function op(deviceId, lamport, kind, issueId, data) {
  return {
    id: `${deviceId}:${lamport}`,
    deviceId,
    lamport,
    kind,
    issueId,
    at: '2026-10-06T08:00:00.000',
    data: data ?? {},
  };
}

async function call(env, path, init) {
  const response = await worker.fetch(new Request(`https://ie-koto.test${path}`, init), env);
  const body = response.status === 204 ? null : await response.json();
  return { status: response.status, body };
}

function post(env, ops, { token = TOKEN, household = HOME } = {}) {
  return call(env, '/ops', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household, ops }),
  });
}

function get(env, { since = 0, token = TOKEN, household = HOME } = {}) {
  const query = new URLSearchParams({ household, since: String(since) });
  return call(env, `/ops?${query}`, { headers: { authorization: `Bearer ${token}` } });
}

/** 全テーブルの全行を取り出す（`wrangler d1 export` のダンプに相当）。 */
function dump(db) {
  const out = {};
  for (const table of TABLES) out[table] = db.prepare(`SELECT * FROM ${table}`).all().map((row) => ({ ...row }));
  return out;
}

/** ダンプを、schema を当てた新しいDBへ入れ直す（隔離した復元先）。 */
function restore(snapshot) {
  const { db, d1 } = createD1();
  db.exec(SCHEMA);
  for (const [table, rows] of Object.entries(snapshot)) {
    for (const row of rows) {
      const keys = Object.keys(row);
      const sql = `INSERT INTO ${table} (${keys.join(', ')}) VALUES (${keys.map(() => '?').join(', ')})`;
      db.prepare(sql).run(...keys.map((key) => row[key]));
    }
  }
  return { db, d1, env: { DB: d1 } };
}

async function seed() {
  const { db, d1 } = createD1();
  db.exec(SCHEMA);
  const env = { DB: d1 };

  await call(env, '/household/members', {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household: HOME, id: MEMBER, name: 'みか' }),
  });
  const share = await call(env, '/household/share', {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household: HOME, issue: 'i:1', member: MEMBER, expiresAt: new Date(Date.now() + 86400000).toISOString() }),
  });
  assert.equal(share.status, 200);

  const first = await post(env, [op('devA', 1, 'add', 'i:1', { title: '引っ越し' }), op('devA', 2, 'comment', 'i:1', { text: 'メモ' })]);
  assert.equal(first.body.cursor, 2, 'バッチ1のあと cursor は 2');
  await post(env, [op('devB', 3, 'add', 'i:2', { title: '粗大ごみ' })]);
  return { db, d1, env };
}

test('バックアップを別DBへ戻しても、cursorの続きと二重送信防止が保たれる', async (t) => {
  const a = await seed();
  const snapshot = dump(a.db);
  assert.equal(snapshot.ops.length, 3);
  assert.equal(snapshot.households[0].seq, 3, '世帯の seq（cursorの上限）も一緒に戻す');

  const b = restore(snapshot);
  t.after(() => b.db.close());

  // 通しで読める（中身と順番が同じ）。
  const all = await get(b.env);
  assert.equal(all.status, 200);
  assert.deepEqual(all.body.ops.map((o) => o.id), ['devA:1', 'devA:2', 'devB:3']);
  assert.deepEqual(all.body.ops[1].data, { text: 'メモ' }, 'payload(data) ごと戻る');
  assert.equal(all.body.skipped, 0);

  // すでに cursor=2 まで見ていた端末は、復旧後の続きだけを引ける。
  const tail = await get(b.env, { since: 2 });
  assert.deepEqual(tail.body.ops.map((o) => o.id), ['devB:3']);
  assert.equal(tail.body.cursor, 3);

  // 二重送信しても増えない。
  const dup = await post(b.env, [op('devA', 1, 'add', 'i:1', { title: '引っ越し' })]);
  assert.deepEqual(dup.body, { cursor: 3, accepted: 0, duplicates: 1 });

  // 復元後に足した op は、続きの番号を取る（既存の cursor が壊れない）。
  const fresh = await post(b.env, [op('devC', 9, 'add', 'i:3', { title: '不用品' })]);
  assert.deepEqual(fresh.body, { cursor: 4, accepted: 1, duplicates: 0 });
  const after = await get(b.env, { since: 3 });
  assert.deepEqual(after.body.ops.map((o) => o.id), ['devC:9']);

  // 名簿と個別共有鍵も戻っている。
  const members = await call(b.env, `/household/members?household=${HOME}`, { headers: { authorization: `Bearer ${TOKEN}` } });
  assert.deepEqual(members.body.members, [{ id: MEMBER, name: 'みか' }]);
  assert.equal(snapshot.share_tokens.length, 1, '個別共有鍵もダンプに含まれる');

  // 元のDBは読むだけで、書き換えていない。
  assert.deepEqual(dump(a.db), snapshot, '復元元は変わらない（隔離）');
});

test('壊れた行があっても、読める行は飛ばして返す（1件のせいで全部が読めなくならない）', async (t) => {
  const a = await seed();
  const snapshot = dump(a.db);
  snapshot.ops.splice(1, 0, {
    household_id: HOME,
    op_id: 'devA:99',
    seq: 4,
    device_id: 'devA',
    lamport: 99,
    kind: 'add',
    issue_id: 'i:9',
    payload: '{壊れたJSON',
    at: '2026-10-06T08:00:00.000',
    received_at: '2026-10-06T08:00:00.000',
  });
  snapshot.households[0].seq = 4;

  const b = restore(snapshot);
  t.after(() => b.db.close());

  const all = await get(b.env);
  assert.deepEqual(all.body.ops.map((o) => o.id), ['devA:1', 'devA:2', 'devB:3'], '壊れた行は返さない');
  assert.equal(all.body.skipped, 1);
});

test('世帯を消したあとのバックアップには、消したデータが残らない', async () => {
  const a = await seed();
  const before = dump(a.db);
  assert.equal(before.ops.length, 3, '消す前のバックアップには残っている（保持方針の対象）');

  const deleted = await call(a.env, `/ops?household=${HOME}`, { method: 'DELETE', headers: { authorization: `Bearer ${TOKEN}` } });
  assert.equal(deleted.status, 200);

  const after = dump(a.db);
  assert.equal(after.ops.length, 0, '消した後のバックアップには op が無い');
  assert.equal(after.households.length, 0);
  assert.equal(after.members.length, 0);
  assert.equal(after.share_tokens.length, 0);

  // 端末は記録を消さない（端末側の話だが、サーバーは消したことを伝えるだけ）。
  assert.deepEqual(deleted.body, { deleted: true });
});
