import { DatabaseSync } from 'node:sqlite';

/**
 * Cloudflare D1 を、手元の SQLite（Node 22 の `node:sqlite`）で真似る。
 * SQL の方言はどちらも SQLite なので、ここで動けば本番でも動く（保証ではないが、強い証拠になる）。
 *
 * 真似ているのは使っている範囲だけ:
 *   prepare(sql).bind(...).run() / .all() / .first()
 *   db.batch([...])   … 1回の往復でまとめて実行（D1 と同じく、失敗したら全部巻き戻す）
 */
export function createD1(path = ':memory:') {
  const db = new DatabaseSync(path);
  return { db, d1: new D1(db) };
}

class D1 {
  constructor(db) {
    this.db = db;
  }

  prepare(sql) {
    return new Statement(this.db, sql, []);
  }

  async batch(statements) {
    this.db.exec('BEGIN');
    try {
      const results = statements.map((statement) => statement._run());
      this.db.exec('COMMIT');
      return results;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  async exec(sql) {
    this.db.exec(sql);
    return { count: 0, duration: 0 };
  }
}

class Statement {
  constructor(db, sql, params) {
    this.db = db;
    this.sql = sql;
    this.params = params;
  }

  bind(...params) {
    return new Statement(this.db, this.sql, params);
  }

  async first(column) {
    const row = this.db.prepare(this.sql).get(...this.params);
    if (row === null || row === undefined) return null;
    if (column !== undefined && column !== null) return row[column] ?? null;
    return row;
  }

  async all() {
    const results = this.db.prepare(this.sql).all(...this.params);
    return { results: results.map(plain), success: true, meta: { changes: 0, last_row_id: 0 } };
  }

  async run() {
    return this._run();
  }

  _run() {
    const info = this.db.prepare(this.sql).run(...this.params);
    return {
      results: [],
      success: true,
      meta: { changes: Number(info.changes), last_row_id: Number(info.lastInsertRowid) },
    };
  }
}

function plain(row) {
  return row === null || row === undefined ? row : { ...row };
}
