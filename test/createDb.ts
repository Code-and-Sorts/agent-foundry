import Database from 'better-sqlite3';
import fs from 'fs';

export function createTestDb() {
  const db = new Database('file:agent-foundry?mode=memory&cache=shared');
  db.pragma('foreign_keys = ON');
  const schema = fs.readFileSync('../setup-script.sql', 'utf8');
  db.exec(schema);
  return db;
}
