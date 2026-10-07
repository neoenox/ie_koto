/**
 * いえこと の同期サーバー。opの出し入れは2本（docs/SYNC_DESIGN.md §3）に、
 * 世帯の始末2本（削除・トークン作り直し）を足した計4本。
 *
 *   GET  /ops?household=<id>&since=<cursor>   増分をもらう
 *   POST /ops                                 自分の op を送る
 *   DELETE /ops?household=<id>                世帯を消す（opと世帯の行。端末の記録は残る）
 *   POST /household/rotate                   トークンを作り直す
 *
 * どれも `Authorization: Bearer <世帯トークン>` が要る。
 * 世帯の行は最初のアクセスで作られる（そのとき提示されたトークンが、その世帯の鍵になる）。
 *
 * 突き合わせの中身は端末側（lib/sync/log.dart）が決める。ここは預かって順に返すだけ。
 */
import {
  MAX_OPS_PER_POST,
  clampLimit,
  deleteHousehold,
  ensureHousehold,
  hashToken,
  pullOps,
  pushOps,
  rotateToken,
} from './ops.js';

/** 世帯idは招待リンクに埋め込む乱数。推測されない長さを必須にする。 */
const HOUSEHOLD_ID = /^[A-Za-z0-9_-]{16,64}$/;

/** 32バイトの乱数なら base64url で 43 文字。短すぎるものは鍵として認めない。 */
const MIN_TOKEN_LENGTH = 32;

/** op_id は「端末id:論理時計」。論理時計は 1 以上。 */
const OP_KIND = /^[a-z_]{1,32}$/;

const MAX_BODY_BYTES = 1024 * 1024;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const cors = corsHeaders(request, env);

    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (url.pathname !== '/ops' && url.pathname !== '/household/rotate') {
      return json({ error: 'not_found' }, 404, cors);
    }

    try {
      if (url.pathname === '/household/rotate') {
        if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, cors);
        return await handleRotate(request, env, cors);
      }
      if (request.method === 'GET') return await handlePull(request, env, url, cors);
      if (request.method === 'POST') return await handlePush(request, env, cors);
      if (request.method === 'DELETE') return await handleDelete(request, env, url, cors);
      return json({ error: 'method_not_allowed' }, 405, cors);
    } catch (error) {
      console.error(error && error.stack ? error.stack : error);
      return json({ error: 'internal' }, 500, cors);
    }
  },
};

/** `GET /ops?household=<id>&since=<cursor>[&limit=<n>][&issue=<id>]` */
async function handlePull(request, env, url, cors) {
  const householdId = url.searchParams.get('household') ?? '';
  if (!HOUSEHOLD_ID.test(householdId)) return json({ error: 'bad_household' }, 400, cors);

  const since = parseCursor(url.searchParams.get('since'));
  if (since === null) return json({ error: 'bad_since' }, 400, cors);

  const limit = clampLimit(url.searchParams.get('limit'));
  if (limit === null) return json({ error: 'bad_limit' }, 400, cors);

  // 1件だけに絞る（1件リンクのページ用）。無ければ世帯の全部。
  const issueId = url.searchParams.get('issue');
  if (issueId !== null && (issueId.length === 0 || issueId.length > 128)) {
    return json({ error: 'bad_issue' }, 400, cors);
  }

  const token = bearerToken(request);
  if (token === null) return json({ error: 'unauthorized' }, 401, cors);

  const db = env.DB;
  const now = new Date().toISOString();
  const allowed = await ensureHousehold(db, householdId, await hashToken(token), now);
  if (!allowed) return json({ error: 'unauthorized' }, 401, cors);

  const page = await pullOps(db, householdId, since, limit, issueId);
  return json(page, 200, cors);
}

/** `POST /ops`  body: `{ "household": "<id>", "ops": [ ... ] }` */
async function handlePush(request, env, cors) {
  const token = bearerToken(request);
  if (token === null) return json({ error: 'unauthorized' }, 401, cors);

  const raw = await readJson(request);
  if (raw === null) return json({ error: 'bad_json' }, 400, cors);

  const householdId = typeof raw.household === 'string' ? raw.household : '';
  if (!HOUSEHOLD_ID.test(householdId)) return json({ error: 'bad_household' }, 400, cors);

  if (!Array.isArray(raw.ops)) return json({ error: 'bad_ops' }, 400, cors);
  if (raw.ops.length === 0) return json({ error: 'bad_ops' }, 400, cors);
  if (raw.ops.length > MAX_OPS_PER_POST) return json({ error: 'too_many_ops', max: MAX_OPS_PER_POST }, 400, cors);

  const ops = [];
  for (const [index, candidate] of raw.ops.entries()) {
    const op = parseOp(candidate);
    // 1件でも壊れていたら、まとめて断る（中途半端に預けると、端末の送信待ちが消える）。
    if (op === null) return json({ error: 'bad_op', index }, 400, cors);
    ops.push(op);
  }

  const db = env.DB;
  const now = new Date().toISOString();
  const allowed = await ensureHousehold(db, householdId, await hashToken(token), now);
  if (!allowed) return json({ error: 'unauthorized' }, 401, cors);

  const result = await pushOps(db, householdId, ops, now);
  return json(result, 200, cors);
}

/** `DELETE /ops?household=<id>` 世帯を消す（opと世帯の行。端末の記録は残る）。 */
async function handleDelete(request, env, url, cors) {
  const householdId = url.searchParams.get('household') ?? '';
  if (!HOUSEHOLD_ID.test(householdId)) return json({ error: 'bad_household' }, 400, cors);

  const token = bearerToken(request);
  if (token === null) return json({ error: 'unauthorized' }, 401, cors);

  const db = env.DB;
  const allowed = await ensureHousehold(db, householdId, await hashToken(token), new Date().toISOString());
  if (!allowed) return json({ error: 'unauthorized' }, 401, cors);

  return json(await deleteHousehold(db, householdId), 200, cors);
}

/** `POST /household/rotate` body: `{ "household": "<id>", "token": "<新しいトークン>" }` */
async function handleRotate(request, env, cors) {
  const oldToken = bearerToken(request);
  if (oldToken === null) return json({ error: 'unauthorized' }, 401, cors);

  const raw = await readJson(request);
  if (raw === null) return json({ error: 'bad_json' }, 400, cors);

  const householdId = typeof raw.household === 'string' ? raw.household : '';
  if (!HOUSEHOLD_ID.test(householdId)) return json({ error: 'bad_household' }, 400, cors);

  const newToken = typeof raw.token === 'string' ? raw.token.trim() : '';
  if (newToken.length < MIN_TOKEN_LENGTH) return json({ error: 'bad_token' }, 400, cors);

  const db = env.DB;
  const now = new Date().toISOString();
  // 古いトークンで認証する（ensureHousehold は合っていれば true。作るのは既存世帯だけ）。
  const allowed = await ensureHousehold(db, householdId, await hashToken(oldToken), now);
  if (!allowed) return json({ error: 'unauthorized' }, 401, cors);

  const ok = await rotateToken(db, householdId, await hashToken(newToken), now);
  if (!ok) return json({ error: 'not_found' }, 404, cors);
  return json({ rotated: true }, 200, cors);
}

/** 端末が送ってきた op を1つ検査する。壊れていれば null。 */
function parseOp(raw) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return null;

  const id = typeof raw.id === 'string' ? raw.id : '';
  const deviceId = typeof raw.deviceId === 'string' ? raw.deviceId : '';
  const kind = typeof raw.kind === 'string' ? raw.kind : '';
  const issueId = typeof raw.issueId === 'string' ? raw.issueId : '';
  const at = typeof raw.at === 'string' ? raw.at : '';
  const lamport = Number.isInteger(raw.lamport) ? raw.lamport : null;

  if (id.length === 0 || id.length > 128) return null;
  if (deviceId.length === 0 || deviceId.length > 64) return null;
  if (issueId.length === 0 || issueId.length > 128) return null;
  if (at.length === 0 || at.length > 40) return null;
  if (lamport === null || lamport < 1) return null;
  if (!OP_KIND.test(kind)) return null;
  // op_id は端末側と同じ規則（`<端末id>:<論理時計>`）。ここが崩れると重複を畳めない。
  if (id !== `${deviceId}:${lamport}`) return null;

  const data = raw.data === undefined || raw.data === null ? {} : raw.data;
  if (typeof data !== 'object' || Array.isArray(data)) return null;
  if (!validKnownOpData(kind, data)) return null;

  const derivedFrom = raw.derivedFrom === undefined || raw.derivedFrom === null ? null : raw.derivedFrom;
  if (derivedFrom !== null && (typeof derivedFrom !== 'string' || derivedFrom.length === 0 || derivedFrom.length > 128)) return null;

  // 書いた人（member_id）。無ければ null。長すぎるものは壊れたopとして断る。
  const member = raw.member === undefined || raw.member === null ? null : raw.member;
  if (member !== null && (typeof member !== 'string' || member.length === 0 || member.length > 64)) return null;

  // payload には送られてきた op を丸ごと入れる（知らない項目も落とさない）。
  return { ...raw, id, deviceId, lamport, kind, issueId, at, data, derivedFrom };
}

/** Reject malformed fields understood by this server/client protocol. Preserve unknown fields. */
function validKnownOpData(kind, data) {
  const optionalString = key => !Object.hasOwn(data, key) || data[key] === null || typeof data[key] === 'string';
  const optionalDate = key => !Object.hasOwn(data, key) || data[key] === null ||
    (typeof data[key] === 'string' && data[key].length <= 40 && Number.isFinite(Date.parse(data[key])));
  const validRecurrence = value => {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
    if (value.kind === 'none' || value.kind === 'daily') return true;
    if (value.kind === 'weekdays') return Array.isArray(value.weekdays) && value.weekdays.length > 0 &&
      value.weekdays.every(day => Number.isInteger(day) && day >= 1 && day <= 7);
    if (value.kind === 'everyDays') return Number.isInteger(value.everyDays) && value.everyDays >= 1 &&
      (!Object.hasOwn(value, 'fromCompletion') || typeof value.fromCompletion === 'boolean');
    return false;
  };

  switch (kind) {
    case 'add':
      return typeof data.title === 'string' && data.title.trim().length > 0 &&
        optionalString('assigneeId') && optionalDate('dueDate') &&
        optionalString('seriesId') && optionalString('originIssueId') &&
        (!Object.hasOwn(data, 'recurrence') || data.recurrence === null || validRecurrence(data.recurrence));
    case 'rename':
      return typeof data.title === 'string' && data.title.trim().length > 0;
    case 'assignee':
      return Object.hasOwn(data, 'assigneeId') && optionalString('assigneeId');
    case 'due':
      return Object.hasOwn(data, 'dueDate') && optionalDate('dueDate');
    case 'recurrence':
      return Object.hasOwn(data, 'recurrence') && data.recurrence !== null && validRecurrence(data.recurrence);
    case 'comment':
      return typeof data.text === 'string' && data.text.trim().length > 0;
    case 'status':
      return ['open', 'doing', 'waiting', 'done'].includes(data.status);
    default:
      return true;
  }
}

function parseCursor(raw) {
  if (raw === null || raw === '') return 0;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0) return null;
  return value;
}

function bearerToken(request) {
  const header = request.headers.get('authorization') ?? '';
  const match = /^Bearer (.+)$/.exec(header.trim());
  if (match === null) return null;
  const token = match[1].trim();
  return token.length < MIN_TOKEN_LENGTH ? null : token;
}

async function readJson(request) {
  const text = await request.text();
  if (text.length === 0 || text.length > MAX_BODY_BYTES) return null;
  try {
    const parsed = JSON.parse(text);
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function corsHeaders(request, env) {
  // 本番はアプリと同じドメインに置くので CORS は要らないが、
  // 開発中（flutter run -d web-server など）は別のポートになるので開けておく。
  const allowed = (env && env.ALLOWED_ORIGIN) || request.headers.get('origin') || '*';
  return {
    'access-control-allow-origin': allowed,
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'authorization, content-type',
    'access-control-max-age': '86400',
    vary: 'origin',
  };
}

function json(body, status, cors) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', ...cors },
  });
}
