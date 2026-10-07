import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createD1 } from './d1.mjs';
import { ensureHousehold, pushOps, pullOps } from '../src/ops.js';

test('遅れたPOSTの記録も、先に返したcursorの続きから取得できる', async () => {
  const { db, d1 } = createD1();
  db.exec(readFileSync(new URL('../schema.sql', import.meta.url), 'utf8'));
  const home = 'household12345678';
  await ensureHousehold(d1, home, 'hash', 'now');
  let release;
  let reached;
  const gate = new Promise(resolve => { release = resolve; });
  const waiting = new Promise(resolve => { reached = resolve; });
  const delayed = {
    prepare: (...args) => d1.prepare(...args),
    batch: async statements => { reached(); await gate; return d1.batch(statements); },
  };
  const op = deviceId => ({ id: `${deviceId}:1`, deviceId, lamport: 1, kind: 'add',
    issueId: `${deviceId}:1`, at: '2026-10-07T00:00:00', data: { title: deviceId } });
  const pending = pushOps(delayed, home, [op('A')], 'now');
  try {
    await waiting;
    await pushOps(d1, home, [op('B')], 'now');
    const before = await pullOps(d1, home, 0, 1000);
    assert.deepEqual(before.ops.map(op => op.id), ['B:1']);
    const quiet = await pullOps(d1, home, before.cursor, 1000);
    assert.deepEqual(quiet.ops, []);
    release();
    await pending;
    const after = await pullOps(d1, home, before.cursor, 1000);
    assert.deepEqual(after.ops.map(op => op.id), ['A:1']);
    assert.ok(after.cursor > before.cursor);
  } finally {
    release();
    await pending;
    db.close();
  }
});
