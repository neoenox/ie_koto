import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import worker from '../src/index.js';
import { createD1 } from './d1.mjs';

/**
 * #67: 公開構成の認可・共有鍵・失効と、秘密情報の露出経路を最終確認するテスト。
 *
 * 既存の worker.test.mjs が押さえていない穴だけを足す:
 *   - 別世帯のトークンで「その世帯の管理操作」ができないこと
 *   - 世帯を消した後どうなるか（拒否か、作り直しか）を実際の挙動で固定する
 *   - 入力の形・サイズ上限
 *   - 平文のトークン／共有鍵が DB に残らないこと
 *   - 共有鍵の期限がサーバーで強制されること（境界を含む）
 *   - CORS は既定で任意 Origin を反射する（＝本番では ALLOWED_ORIGIN で固定する）
 *
 * 記録に実際の鍵は書かない（このファイルの値は全部テスト用のダミー）。
 */

const SCHEMA = readFileSync(new URL('../schema.sql', import.meta.url), 'utf8');

const TOKEN = 'h8Qw3ZrT9xYb2LmN4PvC6SdF7GhJ1KlZ3XcV5BnM7Qa';
const OTHER_TOKEN = 'Zm9yQmFyUXV1eENvcmdlR3JhdWx0R2FycGx5SHVtcEJ1Z1dvbmQ';
const NEW_TOKEN = 'N3wT0k3nN3wT0k3nN3wT0k3nN3wT0k3nN3wT0k3n12';

const HOME = 'hh_TEST000000000000000000000000000000';
const OTHER_HOME = 'hh_OTHER0000000000000000000000000000';

const TABLES = ['households', 'ops', 'members', 'member_aliases', 'share_tokens'];

function newEnv(extra = {}) {
  const { db, d1 } = createD1();
  db.exec(SCHEMA);
  return { env: { DB: d1, ...extra }, db };
}

function op(deviceId, lamport, kind, issueId, data) {
  return { id: `${deviceId}:${lamport}`, deviceId, lamport, kind, issueId, at: '2026-10-06T08:00:00.000', data: data ?? {} };
}

async function call(env, path, init) {
  const response = await worker.fetch(new Request(`https://ie-koto.test${path}`, init), env);
  const body = response.status === 204 ? null : await response.json();
  return { status: response.status, headers: response.headers, body };
}

function post(env, ops, { token = TOKEN, household = HOME } = {}) {
  return call(env, '/ops', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household, ops }),
  });
}

function get(env, { since = 0, token = TOKEN, household = HOME, issue } = {}) {
  const query = new URLSearchParams({ household, since: String(since) });
  if (issue !== undefined) query.set('issue', issue);
  return call(env, `/ops?${query}`, { headers: { authorization: `Bearer ${token}` } });
}

/** DBの中身をぜんぶ文字列にして、平文の秘密が紛れていないか見るため。 */
function dumpText(db) {
  const parts = [];
  for (const table of TABLES) parts.push(JSON.stringify(db.prepare(`SELECT * FROM ${table}`).all()));
  return parts.join('\n');
}

test('別世帯のトークンでは、その世帯の管理操作ができない（401）', async () => {
  const { env, db } = newEnv();
  await post(env, [op('A', 1, 'add', 'A:1', { title: '牛乳' })]); // TOKEN で HOME を作る

  const asOther = (path, method, body) => call(env, path, {
    method,
    headers: { authorization: `Bearer ${OTHER_TOKEN}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });

  const attempts = [
    [`/household/members?household=${HOME}`, 'GET', undefined],
    ['/household/members', 'POST', { household: HOME, id: 'mem_0123456789abcdef', name: '権限外' }],
    ['/household/members/migrate', 'POST', { household: HOME, legacyMembers: [{ id: 'me', name: '権限外' }] }],
    ['/household/members/merge', 'POST', { household: HOME, from: 'mem_0123456789abcdef', into: 'mem_fedcba9876543210' }],
    ['/household/members/remove', 'POST', { household: HOME, id: 'mem_0123456789abcdef' }],
    ['/household/rotate', 'POST', { household: HOME, token: NEW_TOKEN }],
    ['/household/share', 'POST', { household: HOME, issue: 'A:1', member: 'mem_0123456789abcdef', expiresAt: new Date(Date.now() + 60_000).toISOString() }],
    [`/ops?household=${HOME}`, 'DELETE', undefined],
  ];
  for (const [path, method, body] of attempts) {
    assert.equal((await asOther(path, method, body)).status, 401, `${method} ${path}`);
  }

  // 何も作られていない・変わっていない。HOME の1件だけ。
  assert.equal(db.prepare('SELECT count(*) AS n FROM members').get().n, 0);
  assert.equal(db.prepare('SELECT count(*) AS n FROM member_aliases').get().n, 0);
  assert.equal(db.prepare('SELECT count(*) AS n FROM share_tokens').get().n, 0);
  assert.equal(db.prepare('SELECT count(*) AS n FROM households').get().n, 1);
  assert.equal(db.prepare('SELECT id FROM households').get().id, HOME);
  assert.equal((await get(env)).status, 200, '所有者のトークンは変わらず使える');
  db.close();
});

test('世帯を消した後は、トークンを持つ端末が空の世帯を作り直す（データは戻らない）', async () => {
  const { env, db } = newEnv();
  await post(env, [op('A', 1, 'add', 'A:1', { title: '牛乳' })]);
  assert.equal(db.prepare('SELECT count(*) AS n FROM ops').get().n, 1);

  const deleted = await call(env, `/ops?household=${HOME}`, { method: 'DELETE', headers: { authorization: `Bearer ${TOKEN}` } });
  assert.equal(deleted.status, 200);
  assert.equal(db.prepare('SELECT count(*) AS n FROM households').get().n, 0, '世帯の行も消える');

  // 「最初のアクセスで世帯ができる」ので、同じトークンで叩くと空の世帯ができる。
  // 消えるのはデータ。トークンを持つ端末が自分の世帯をやり直すのは想定内（残存リスクとして記録）。
  const again = await get(env);
  assert.equal(again.status, 200);
  assert.deepEqual(again.body.ops, [], '消した op は戻らない');
  assert.equal(again.body.cursor, 0);
  assert.equal(db.prepare('SELECT count(*) AS n FROM households').get().n, 1, '空の世帯が作り直される');

  // 別のトークンでは、もう（他人の）世帯を作れない。
  assert.equal((await get(env, { token: OTHER_TOKEN })).status, 401);
  assert.equal(db.prepare('SELECT id FROM households').get().id, HOME);
  db.close();
});

test('入力の形・サイズ上限を守る（本文が大きすぎる・配列・文字列は400）', async () => {
  const { env, db } = newEnv();
  const headers = { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' };

  const tooBig = await call(env, '/ops', { method: 'POST', headers, body: 'x'.repeat(1024 * 1024 + 1) });
  assert.equal(tooBig.status, 400);
  assert.equal(tooBig.body.error, 'bad_json');

  for (const body of ['[1,2]', '"ただの文字列"', 'null', '']) {
    const bad = await call(env, '/ops', { method: 'POST', headers, body });
    assert.equal(bad.status, 400, body);
    assert.equal(bad.body.error, 'bad_json');
  }

  // 形は正しいが世帯idが不正。
  const badHome = await call(env, '/ops', { method: 'POST', headers, body: JSON.stringify({ household: 'short', ops: [] }) });
  assert.equal(badHome.status, 400);
  assert.equal(badHome.body.error, 'bad_household');

  assert.equal(db.prepare('SELECT count(*) AS n FROM ops').get().n, 0);
  db.close();
});

test('平文のトークン・共有鍵はDBに残らない（ハッシュのみ）', async () => {
  const { env, db } = newEnv();
  await post(env, [op('A', 1, 'add', 'A:1', { title: '牛乳' })]);
  const share = await call(env, '/household/share', {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household: HOME, issue: 'A:1', member: 'mem_0123456789abcdef', expiresAt: new Date(Date.now() + 60_000).toISOString() }),
  });
  assert.equal(share.status, 200);
  const shareToken = share.body.token;

  for (const [value, table] of [[TOKEN, 'households'], [shareToken, 'share_tokens']]) {
    const stored = db.prepare(`SELECT token_hash FROM ${table}`).all();
    assert.equal(stored.length, 1);
    assert.match(stored[0].token_hash, /^[0-9a-f]{64}$/);
    assert.notEqual(stored[0].token_hash, value);
  }

  // DBの中身を丸ごと見ても、平文は1文字も出てこない。
  const text = dumpText(db);
  assert.ok(!text.includes(TOKEN), '世帯トークンの平文が無い');
  assert.ok(!text.includes(shareToken), '共有鍵の平文が無い');
  assert.ok(!text.includes('token_hash": "'), 'ハッシュは16進のみ');
  db.close();
});

test('共有鍵の期限はサーバーで強制される（同じ時刻は拒否）', async () => {
  const { env, db } = newEnv();
  await post(env, [op('A', 1, 'add', 'A:1', { title: '共有する依頼' })]);
  const share = await call(env, '/household/share', {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household: HOME, issue: 'A:1', member: 'mem_0123456789abcdef', expiresAt: new Date(Date.now() + 60_000).toISOString() }),
  });
  const token = share.body.token;

  const claim = { ...op('guest', 1, 'assignee', 'A:1', { assigneeId: 'mem_0123456789abcdef' }), member: 'mem_0123456789abcdef' };
  assert.equal((await get(env, { token, issue: 'A:1' })).status, 200);
  assert.equal((await post(env, [claim], { token })).status, 200);

  // 期限を「いま」にすると、その瞬間から拒否（`expires_at > now` の厳密比較）。
  db.prepare('UPDATE share_tokens SET expires_at = ? WHERE household_id = ?').run(new Date().toISOString(), HOME);
  assert.equal((await get(env, { token, issue: 'A:1' })).status, 401);
  assert.equal((await post(env, [{ ...claim, lamport: 2, id: 'guest:2' }], { token })).status, 401);
  db.close();
});

test('CORSは既定で任意のOriginを反射する（本番は ALLOWED_ORIGIN で固定する）', async () => {
  const { env } = newEnv();
  const loose = await call(env, '/ops', { method: 'OPTIONS', headers: { origin: 'https://evil.example', 'access-control-request-method': 'GET' } });
  assert.equal(loose.status, 204);
  assert.equal(loose.headers.get('access-control-allow-origin'), 'https://evil.example', '既定は反射（開発用。本番では固定する）');
  assert.equal(loose.headers.get('access-control-allow-headers'), 'authorization, content-type');

  const fixed = newEnv({ ALLOWED_ORIGIN: 'https://ie-koto.example' });
  const pinned = await call(fixed.env, '/ops', { method: 'OPTIONS', headers: { origin: 'https://evil.example' } });
  assert.equal(pinned.headers.get('access-control-allow-origin'), 'https://ie-koto.example', 'ALLOWED_ORIGIN があれば固定される');
  fixed.db.close();
});
