import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import worker from '../src/index.js';
import { createD1 } from './d1.mjs';

/**
 * Worker APIs are exercised against the real SQLite schema.
 * 使っているのは schema.sql と src/ そのもの。差し替えているのは D1 だけ（test/d1.mjs）。
 */

const SCHEMA = readFileSync(new URL('../schema.sql', import.meta.url), 'utf8');

/** 32バイト相当の世帯トークン。 */
const TOKEN = 'h8Qw3ZrT9xYb2LmN4PvC6SdF7GhJ1KlZ3XcV5BnM7Qa';
const OTHER_TOKEN = 'Zm9yQmFyUXV1eENvcmdlR3JhdWx0R2FycGx5SHVtcEJ1Z1dvbmQ';

const HOME = 'hh_TEST000000000000000000000000000000';
const OTHER_HOME = 'hh_OTHER0000000000000000000000000000';

function newEnv() {
  const { db, d1 } = createD1();
  db.exec(SCHEMA);
  return { env: { DB: d1 }, db };
}

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
  return { status: response.status, headers: response.headers, body };
}

function post(env, ops, { token = TOKEN, household = HOME } = {}) {
  return call(env, '/ops', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household, ops }),
  });
}

function get(env, { since = 0, limit, issue, token = TOKEN, household = HOME } = {}) {
  const query = new URLSearchParams({ household, since: String(since) });
  if (limit !== undefined) query.set('limit', String(limit));
  if (issue !== undefined) query.set('issue', String(issue));
  return call(env, `/ops?${query}`, { headers: { authorization: `Bearer ${token}` } });
}

test('論理時計は正の32bit整数だけ受け付ける', async () => {
  for (const clock of [0, -1, 1.5, 2147483648, 2 ** 53]) {
    const { env, db } = newEnv();
    try {
      const reply = await post(env, [op('boundary', clock, 'add', `boundary:${clock}`, { title: '境界' })]);
      assert.equal(reply.status, 400, `clock=${clock}`);
      assert.equal(db.prepare('SELECT COUNT(*) AS n FROM ops').get().n, 0);
    } finally {
      db.close();
    }
  }
  for (const clock of [1, 2147483647]) {
    const { env, db } = newEnv();
    try {
      const reply = await post(env, [op('boundary', clock, 'add', `boundary:${clock}`, { title: '境界' })]);
      assert.equal(reply.status, 200, `clock=${clock}`);
      assert.equal(reply.body.accepted, 1);
    } finally {
      db.close();
    }
  }
});

test('範囲外の時計が混ざるバッチは部分保存せず、正常opを再送できる', async () => {
  for (const invalidFirst of [false, true]) {
    const { env, db } = newEnv();
    try {
      const valid = op('A', 1, 'add', 'A:1', { title: '正常な依頼' });
      const invalid = op('B', 2147483648, 'add', 'B:2147483648', { title: '範囲外' });
      const reply = await post(env, invalidFirst ? [invalid, valid] : [valid, invalid]);
      assert.equal(reply.status, 400);
      assert.equal(db.prepare('SELECT COUNT(*) AS n FROM ops').get().n, 0);
      const retry = await post(env, [valid]);
      assert.equal(retry.status, 200);
      assert.equal(retry.body.accepted, 1);
      assert.equal(retry.body.duplicates, 0);
      assert.equal(db.prepare('SELECT COUNT(*) AS n FROM ops').get().n, 1);
    } finally {
      db.close();
    }
  }
});

test('1件リンクは時計上限・依頼範囲・世帯管理・期限・別世帯の境界を守る', async () => {
  const { env, db } = newEnv();
  try {
    const issue = 'A:1';
    const member = 'guest';
    const shared = await call(env, '/household/share', {
      method: 'POST',
      headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
      body: JSON.stringify({ household: HOME, issue, member,
        expiresAt: new Date(Date.now() + 60_000).toISOString() }),
    });
    assert.equal(shared.status, 200);
    const claim = (clock) => ({ ...op('guest-device', clock, 'assignee', issue,
      { assigneeId: member }), member });
    const rejected = await post(env, [claim(2147483648)], { token: shared.body.token });
    assert.equal(rejected.status, 400);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM ops').get().n, 0);
    for (const outside of [
      { ...claim(1), issueId: 'other-issue' },
      { ...claim(1), member: 'other-member' },
      { ...claim(1), data: { assigneeId: 'other-member' } },
      { ...claim(1), kind: 'comment', data: { text: '権限外の投稿' } },
    ]) {
      const denied = await post(env, [outside], { token: shared.body.token });
      assert.equal(denied.status, 403);
      assert.equal(denied.body.error, 'share_scope');
      assert.equal(db.prepare('SELECT COUNT(*) AS n FROM ops').get().n, 0);
    }
    const accepted = await post(env, [claim(1)], { token: shared.body.token });
    assert.equal(accepted.status, 200);
    assert.equal(accepted.body.accepted, 1);
    const seeded = await post(env, [
      op('A', 1, 'add', issue, { title: '共有する依頼' }),
      op('A', 2, 'add', 'A:2', { title: '世帯内の別の依頼' }),
    ]);
    assert.equal(seeded.status, 200);
    const token = shared.body.token;
    assert.equal((await post(env, [op('other', 1, 'add', issue, { title: '別世帯の同じissue ID' })],
      { household: OTHER_HOME, token: OTHER_TOKEN })).status, 200);
    assert.equal((await get(env, { household: OTHER_HOME, token, issue })).status, 401);
    assert.equal((await post(env, [claim(2)], { household: OTHER_HOME, token })).status, 401);
    const otherOwner = await get(env, { household: OTHER_HOME, token: OTHER_TOKEN });
    assert.equal(otherOwner.status, 200);
    assert.equal(otherOwner.body.ops.length, 1);
    assert.equal(otherOwner.body.ops[0].data.title, '別世帯の同じissue ID');
    const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
    for (const [path, method, body] of [
      [`/ops?household=${HOME}`, 'DELETE', null],
      ['/household/rotate', 'POST', { household: HOME, token: OTHER_TOKEN }],
      [`/household/members?household=${HOME}`, 'GET', null],
      ['/household/members', 'POST', { household: HOME,
        id: 'mem_0123456789abcdef', name: '権限外の名前' }],
      ['/household/members/migrate', 'POST', { household: HOME,
        legacyMembers: [{ id: 'me', name: '権限外の移行' }] }],
      ['/household/share', 'POST', { household: HOME, issue, member,
        expiresAt: new Date(Date.now() + 60_000).toISOString() }],
    ]) {
      const denied = await call(env, path, { method, headers,
        ...(body === null ? {} : { body: JSON.stringify(body) }) });
      assert.equal(denied.status, 401, `${method} ${path}`);
    }
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM members').get().n, 0);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM member_aliases').get().n, 0);
    assert.equal((await get(env)).status, 200, '所有者tokenもデータも維持される');
    assert.equal((await get(env, { token })).status, 401);
    assert.equal((await get(env, { token, issue: 'A:2' })).status, 401);
    const scoped = await get(env, { token, issue });
    assert.equal(scoped.status, 200);
    assert.equal(scoped.body.ops.length, 2);
    assert.ok(scoped.body.ops.every((item) => item.issueId === issue));
    db.prepare('UPDATE share_tokens SET expires_at = ? WHERE household_id = ?')
      .run('2000-01-01T00:00:00.000Z', HOME);
    assert.equal((await get(env, { token, issue })).status, 401);
    assert.equal((await post(env, [claim(2)], { token })).status, 401);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM ops WHERE household_id = ?').get(HOME).n, 3);
    const owner = await get(env);
    assert.equal(owner.status, 200);
    assert.equal(owner.body.ops.length, 3);
  } finally {
    db.close();
  }
});

test('預けたopを、挿入順に取り出せる', async () => {
  const { env } = newEnv();

  const add = op('A', 1, 'add', 'A:1', { title: '牛乳を買う' });
  const done = op('A', 2, 'complete', 'A:1');
  const reply = await post(env, [add, done]);
  assert.equal(reply.status, 200);
  assert.deepEqual(reply.body, { cursor: 2, accepted: 2, duplicates: 0 });

  const all = await get(env);
  assert.equal(all.status, 200);
  assert.equal(all.body.cursor, 2);
  assert.deepEqual(
    all.body.ops.map((o) => o.id),
    ['A:1', 'A:2'],
  );
  assert.equal(all.body.ops[0].data.title, '牛乳を買う');
  assert.equal(all.body.skipped, 0);

  // since より後だけが返る。
  const diff = await get(env, { since: 1 });
  assert.deepEqual(
    diff.body.ops.map((o) => o.id),
    ['A:2'],
  );
  assert.equal(diff.body.cursor, 2);

  // もう無ければ空で、cursor は据え置き。
  const empty = await get(env, { since: 2 });
  assert.deepEqual(empty.body.ops, []);
  assert.equal(empty.body.cursor, 2);
});

test('同じopを二重にPOSTしても増えず、cursorも進まない', async () => {
  const { env, db } = newEnv();
  const one = op('A', 1, 'add', 'A:1', { title: '牛乳を買う' });

  const first = await post(env, [one]);
  const second = await post(env, [one]);
  assert.equal(first.body.accepted, 1);
  assert.equal(second.body.accepted, 0);
  assert.equal(second.body.duplicates, 1);
  assert.equal(second.body.cursor, first.body.cursor);

  // 同じ便に、すでにあるものと新しいものが混ざっていてもよい。
  const third = await post(env, [one, op('A', 2, 'complete', 'A:1')]);
  assert.equal(third.body.accepted, 1);
  assert.equal(third.body.duplicates, 1);

  assert.equal(Number(db.prepare('SELECT count(*) AS n FROM ops').get().n), 2);
});

test('同時に2本POSTしても、同じopは1つだけ', async () => {
  const { env, db } = newEnv();
  const one = op('A', 1, 'add', 'A:1', { title: '牛乳' });

  const [a, b] = await Promise.all([post(env, [one]), post(env, [one])]);
  assert.equal(a.status, 200);
  assert.equal(b.status, 200);
  assert.equal(a.body.accepted + b.body.accepted, 1);
  assert.equal(Number(db.prepare('SELECT count(*) AS n FROM ops').get().n), 1);
});

test('limitでページングでき、cursorが続きを指す', async () => {
  const { env } = newEnv();
  const ops = [1, 2, 3, 4, 5].map((n) => op('A', n, 'comment', 'A:1', { text: `メモ${n}` }));
  await post(env, ops);

  const page1 = await get(env, { since: 0, limit: 2 });
  assert.deepEqual(page1.body.ops.map((o) => o.id), ['A:1', 'A:2']);
  assert.equal(page1.body.cursor, 2);

  const page2 = await get(env, { since: page1.body.cursor, limit: 2 });
  assert.deepEqual(page2.body.ops.map((o) => o.id), ['A:3', 'A:4']);

  const page3 = await get(env, { since: page2.body.cursor, limit: 2 });
  assert.deepEqual(page3.body.ops.map((o) => o.id), ['A:5']);
  assert.equal(page3.body.cursor, 5);

  const page4 = await get(env, { since: page3.body.cursor, limit: 2 });
  assert.deepEqual(page4.body.ops, []);
  assert.equal(page4.body.cursor, 5);

  // limit=0 は無制限。
  const all = await get(env, { since: 0, limit: 0 });
  assert.equal(all.body.ops.length, 5);
});

test('cursorは世帯ごとに独立している', async () => {
  const { env } = newEnv();
  await post(env, [op('A', 1, 'add', 'A:1', { title: 'うちの牛乳' })]);
  await post(env, [op('B', 1, 'add', 'B:1', { title: '実家の牛乳' }), op('B', 2, 'complete', 'B:1')], {
    household: OTHER_HOME,
  });

  const home = await get(env, { household: HOME });
  const other = await get(env, { household: OTHER_HOME });
  assert.equal(home.body.ops.length, 1);
  assert.equal(other.body.ops.length, 2);
  assert.equal(home.body.ops[0].data.title, 'うちの牛乳');
  assert.equal(other.body.ops[0].data.title, '実家の牛乳');
});

test('世帯は最初のアクセスでできる（まだ何も無い世帯は空で返る）', async () => {
  const { env, db } = newEnv();
  const first = await get(env, { since: 0 });
  assert.equal(first.status, 200);
  assert.deepEqual(first.body.ops, []);
  assert.equal(first.body.cursor, 0);
  assert.equal(Number(db.prepare('SELECT count(*) AS n FROM households').get().n), 1);
  // トークンは平文で持たない。
  const hash = db.prepare('SELECT token_hash FROM households').get().token_hash;
  assert.notEqual(hash, TOKEN);
  assert.equal(hash.length, 64);
});

test('トークンが違えば、読めないし書けない', async () => {
  const { env } = newEnv();
  await post(env, [op('A', 1, 'add', 'A:1', { title: '牛乳' })]);

  assert.equal((await get(env, { token: OTHER_TOKEN })).status, 401);
  assert.equal((await post(env, [op('A', 2, 'comment', 'A:1', { text: 'x' })], { token: OTHER_TOKEN })).status, 401);

  // 短すぎるトークンは、鍵として認めない。
  assert.equal((await get(env, { token: 'short' })).status, 401);
  const noHeader = await call(env, `/ops?household=${HOME}&since=0`, {});
  assert.equal(noHeader.status, 401);
});

test('壊れたopは、まとめて断る（400）', async () => {
  const { env, db } = newEnv();
  const good = op('A', 1, 'add', 'A:1', { title: '牛乳' });

  const mismatched = { ...op('A', 2, 'comment', 'A:1'), id: 'A:99' };
  const noKind = { ...op('A', 3, 'comment', 'A:1'), kind: '' };
  const arrayData = { ...op('A', 4, 'comment', 'A:1'), data: [1, 2] };
  const badLamport = { ...op('A', 5, 'comment', 'A:1'), lamport: 0 };
  const badAssignee = op('A', 6, 'assignee', 'A:1', { assigneeId: 42 });
  const incompleteRename = op('A', 7, 'rename', 'A:1');

  for (const broken of [mismatched, noKind, arrayData, badLamport, badAssignee, incompleteRename]) {
    const reply = await post(env, [good, broken]);
    assert.equal(reply.status, 400, `${JSON.stringify(broken)} は断られるはず`);
    assert.equal(reply.body.error, 'bad_op');
  }
  // 断った便は、1件も預からない。
  assert.equal(Number(db.prepare('SELECT count(*) AS n FROM ops').get().n), 0);
});

test('一度に送れるopの数には上限がある', async () => {
  const { env } = newEnv();
  const tooMany = Array.from({ length: 201 }, (_, i) => op('A', i + 1, 'comment', 'A:1', { text: `${i}` }));
  const reply = await post(env, tooMany);
  assert.equal(reply.status, 400);
  assert.equal(reply.body.error, 'too_many_ops');
});

test('derivedFromと日本語のdataを、そのまま預かって返す', async () => {
  const { env } = newEnv();
  const derived = {
    ...op('A', 3, 'add', 'next:A:2', { title: 'お風呂そうじ 🛁', dueDate: '2026-10-07T00:00:00.000', recurrence: null }),
    derivedFrom: 'A:2',
  };
  const reply = await post(env, [derived]);
  assert.equal(reply.status, 200);

  const [back] = (await get(env)).body.ops;
  assert.equal(back.derivedFrom, 'A:2');
  assert.equal(back.data.title, 'お風呂そうじ 🛁');
  assert.equal(back.data.dueDate, '2026-10-07T00:00:00.000');
  assert.deepEqual(back.data.recurrence, null);
});

test('issue を付けると、その1件のopだけが返る（1件リンクのページ用）', async () => {
  const { env } = newEnv();
  await post(env, [
    op('A', 1, 'add', 'A:1', { title: '牛乳を買う' }),
    op('A', 2, 'add', 'A:2', { title: 'トイレットペーパー' }),
    op('A', 3, 'comment', 'A:1', { text: '低脂肪ので' }),
    op('A', 4, 'complete', 'A:2'),
    op('A', 5, 'assignee', 'next:A:4', { assigneeId: 'partner' }),
  ]);

  const one = await get(env, { issue: 'A:1' });
  assert.equal(one.status, 200);
  assert.deepEqual(
    one.body.ops.map((o) => o.id),
    ['A:1', 'A:3'],
  );
  // 世帯のほかの案件は、1件も混ざらない（相手のブラウザに置かない）。
  assert.equal(one.body.ops.some((o) => o.issueId !== 'A:1'), false);

  // 絞っても cursor の意味は変わらない（その1件の最後の位置を指す）。
  assert.equal(one.body.cursor, 3);
  const rest = await get(env, { issue: 'A:1', since: one.body.cursor });
  assert.deepEqual(rest.body.ops, []);
  assert.equal(rest.body.cursor, 3);

  // 誰も知らないidを指しても、空で返るだけ（世帯の存在を漏らさない）。
  const unknown = await get(env, { issue: 'A:99' });
  assert.deepEqual(unknown.body.ops, []);

  // 絞らずに頼めば、これまでどおり全部が返る。
  const all = await get(env);
  assert.equal(all.body.ops.length, 5);

  assert.equal((await get(env, { issue: '' })).status, 400);
  assert.equal((await get(env, { issue: 'x'.repeat(129) })).status, 400);
});

test('sinceを飛び越しても、実在する位置まで戻る', async () => {
  const { env } = newEnv();
  await post(env, [op('A', 1, 'add', 'A:1', { title: '牛乳' })]);

  const jumped = await get(env, { since: 99 });
  assert.deepEqual(jumped.body.ops, []);
  assert.equal(jumped.body.cursor, 1, '存在しない位置を指したままにしない');
});

test('壊れた行は飛ばして返す（1件のせいで世帯が読めなくならない）', async () => {
  const { env, db } = newEnv();
  await post(env, [op('A', 1, 'add', 'A:1', { title: '牛乳' })]);
  db.prepare('UPDATE ops SET payload = ?').run('{こわれている');

  const reply = await get(env);
  assert.equal(reply.status, 200);
  assert.deepEqual(reply.body.ops, []);
  assert.equal(reply.body.skipped, 1);
});

test('入口の検査（メソッド・世帯id・since・本文）', async () => {
  const { env } = newEnv();
  const token = { authorization: `Bearer ${TOKEN}` };

  assert.equal((await call(env, '/', { headers: token })).status, 404);
  assert.equal((await call(env, '/ops', { method: 'PUT', headers: token })).status, 405);
  assert.equal((await call(env, '/ops', { method: 'DELETE', headers: token })).status, 400);
  assert.equal((await call(env, '/ops?household=short&since=0', { headers: token })).status, 400);
  assert.equal((await call(env, `/ops?household=${HOME}&since=-1`, { headers: token })).status, 400);
  assert.equal((await call(env, `/ops?household=${HOME}&since=abc`, { headers: token })).status, 400);

  const badBody = await call(env, '/ops', {
    method: 'POST',
    headers: { ...token, 'content-type': 'application/json' },
    body: 'これはJSONではない',
  });
  assert.equal(badBody.status, 400);
  assert.equal(badBody.body.error, 'bad_json');

  const emptyOps = await post(env, []);
  assert.equal(emptyOps.status, 400);
});

test('トークンを作り直せる（古い招待文は使えなくなる）', async () => {
  const { env } = newEnv();
  await post(env, [op('A', 1, 'add', 'A:1', { title: '牛乳' })]);

  const NEW_TOKEN = 'N3wT0k3nN3wT0k3nN3wT0k3nN3wT0k3nN3wT0k3n12';
  const rotated = await call(env, '/household/rotate', {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household: HOME, token: NEW_TOKEN }),
  });
  assert.equal(rotated.status, 200);
  assert.deepEqual(rotated.body, { rotated: true });

  // 古いトークンでは読めない・書けない。opはそのまま残る。
  assert.equal((await get(env, { token: TOKEN })).status, 401);
  assert.equal((await post(env, [op('A', 2, 'complete', 'A:1')], { token: TOKEN })).status, 401);

  const kept = await get(env, { token: NEW_TOKEN });
  assert.equal(kept.status, 200);
  assert.equal(kept.body.ops.length, 1);

  // 短いトークンへの作り直しは断る。認証なしも断る。
  const short = await call(env, '/household/rotate', {
    method: 'POST',
    headers: { authorization: `Bearer ${NEW_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household: HOME, token: 'short' }),
  });
  assert.equal(short.status, 400);
  const noAuth = await call(env, '/household/rotate', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ household: HOME, token: NEW_TOKEN }),
  });
  assert.equal(noAuth.status, 401);
});

test('世帯を消せる（サーバーの記録だけ消え、端末の記録は残る）', async () => {
  const { env } = newEnv();
  await post(env, [op('A', 1, 'add', 'A:1', { title: '牛乳' })]);

  const deleted = await call(env, `/ops?household=${HOME}`, {
    method: 'DELETE',
    headers: { authorization: `Bearer ${TOKEN}` },
  });
  assert.equal(deleted.status, 200);
  assert.deepEqual(deleted.body, { deleted: true });

  // 消した後は空（最初のアクセスで世帯が作り直される）。
  const after = await get(env);
  assert.equal(after.status, 200);
  assert.deepEqual(after.body.ops, []);

  // トークンが違うと消せない。
  await post(env, [op('A', 1, 'add', 'A:1', { title: '牛乳' })]);
  const denied = await call(env, `/ops?household=${HOME}`, {
    method: 'DELETE',
    headers: { authorization: `Bearer ${OTHER_TOKEN}` },
  });
  assert.equal(denied.status, 401);
  const kept = await get(env);
  assert.equal(kept.body.ops.length, 1);
});

test('CORSの前置きに答える（開発中は別のポートから叩くため）', async () => {
  const { env } = newEnv();
  const preflight = await call(env, '/ops', {
    method: 'OPTIONS',
    headers: { origin: 'http://127.0.0.1:8080' },
  });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('access-control-allow-origin'), 'http://127.0.0.1:8080');
  assert.equal(preflight.headers.get('access-control-allow-methods'), 'GET, POST, PUT, DELETE, OPTIONS');

  const reply = await get(env);
  assert.equal(reply.headers.get('access-control-allow-origin'), '*', 'Originが無ければ * で返す');
});

test('me/partnerを同じ世帯内で一度だけ安定IDへ移行し、メンバー追加と改名を共有する', async () => {
  const { env, db } = newEnv();
  const migrate = async (names) => call(env, '/household/members/migrate', {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household: HOME, legacyMembers: names }),
  });
  const first = await migrate([{ id: 'me', name: 'あき' }, { id: 'partner', name: 'ゆう' }]);
  assert.equal(first.status, 200);
  assert.match(first.body.aliases.me, /^mem_[a-f0-9]{32}$/);
  assert.match(first.body.aliases.partner, /^mem_[a-f0-9]{32}$/);
  assert.notEqual(first.body.aliases.me, first.body.aliases.partner);
  assert.deepEqual(first.body.members.map((m) => m.name), ['あき', 'ゆう']);

  const second = await migrate([{ id: 'me', name: '別の端末の自分' }, { id: 'partner', name: '別名' }]);
  assert.deepEqual(second.body.aliases, first.body.aliases);
  assert.deepEqual(second.body.members, first.body.members);

  const addedId = `mem_${'a'.repeat(32)}`;
  const added = await call(env, '/household/members', {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household: HOME, id: addedId, name: '子ども' }),
  });
  assert.equal(added.status, 200);
  const fetched = await call(env, `/household/members?household=${HOME}`, {
    headers: { authorization: `Bearer ${TOKEN}` },
  });
  assert.equal(fetched.body.members.length, 3);

  const denied = await call(env, `/household/members?household=${HOME}`, {
    headers: { authorization: `Bearer ${OTHER_TOKEN}` },
  });
  assert.equal(denied.status, 401);
  assert.equal(Number(db.prepare('SELECT count(*) AS n FROM member_aliases').get().n), 2);
});

test('既存のmembers行もIDを維持して対応表に移す', async () => {
  const { env, db } = newEnv();
  db.prepare('INSERT INTO members (household_id, member_id, display_name) VALUES (?, ?, ?)')
    .run(HOME, 'me', 'あき');
  db.prepare('INSERT INTO members (household_id, member_id, display_name) VALUES (?, ?, ?)')
    .run(HOME, 'partner', 'ゆう');
  const response = await call(env, '/household/members/migrate', {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ household: HOME, legacyMembers: [] }),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(response.body.members.map((member) => member.name), ['あき', 'ゆう']);
  assert.equal(db.prepare('SELECT count(*) AS n FROM members WHERE household_id = ? AND member_id IN (?, ?)')
    .get(HOME, 'me', 'partner').n, 0);
});
