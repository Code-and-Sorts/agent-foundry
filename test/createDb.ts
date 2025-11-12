import Database from 'better-sqlite3';
import fs from 'fs';
import path from 'path';

export function createTestDb() {
  const db = new Database('file:agent-foundry?mode=memory&cache=shared');
  db.pragma('foreign_keys = ON');
  const schema = fs.readFileSync(path.join(__dirname, '../setup-script.sql'), 'utf8');
  db.exec(schema);
  return db;
}
