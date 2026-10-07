import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';

import worker from '../src/index.js';
import { createD1 } from './d1.mjs';

/**
 * 手元で確かめるための HTTP サーバー。
 * 中身は本番と同じ Worker の fetch（src/index.js）。違うのは D1 を node:sqlite で真似ている点だけ。
 *
 *   npm run serve -- --port 8799                 # メモリ上のDB
 *   npm run serve -- --port 8799 --db ./local.db  # ファイルに残す
 *
 * Dartのテスト（test/sync_worker_e2e_test.dart）はこれを起動して、実際にHTTPで叩く。
 */
const SCHEMA = readFileSync(new URL('../schema.sql', import.meta.url), 'utf8');

const args = process.argv.slice(2);
const port = Number(option('--port') ?? 0);
const dbPath = option('--db') ?? ':memory:';
// リクエストを1行ずつ出す（端末が何を送ったか見たいとき）。
const verbose = args.includes('--log');

const { db, d1 } = createD1(dbPath);
db.exec(SCHEMA);

const server = createServer(async (req, res) => {
  try {
    const body = await readBody(req);
    const request = new Request(`http://127.0.0.1:${server.address().port}${req.url}`, {
      method: req.method,
      headers: req.headers,
      body: req.method === 'GET' || req.method === 'HEAD' ? undefined : body,
    });
    const response = await worker.fetch(request, { DB: d1 });
    const payload = Buffer.from(await response.arrayBuffer());
    if (verbose) {
      console.log(`${req.method} ${req.url} -> ${response.status} ${payload.toString('utf8').slice(0, 200)}`);
    }
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(payload);
  } catch (error) {
    res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'harness_failed', message: String(error) }));
  }
});

server.listen(port, '127.0.0.1', () => {
  // 呼び出した側が読めるように、ポートを1行で出す。
  console.log(`PORT=${server.address().port}`);
  console.log(`DB=${dbPath}`);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}

function option(name) {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return chunks.length === 0 ? undefined : Buffer.concat(chunks);
}
