import Database from 'better-sqlite3';
import fs from 'fs';

export function createTestDb() {
  // shared in-memory so multiple connections in the SAME process can see the DB
  // Note: for true multi-process, use a temp file path instead.
  const db = new Database('file:agent-foundry?mode=memory&cache=shared');
  db.pragma('foreign_keys = ON');
  const schema = fs.readFileSync('../setup-script.sql', 'utf8');
  db.exec(schema);
  return db;
}
