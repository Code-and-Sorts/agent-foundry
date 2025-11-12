import { describe, it, expect, beforeAll } from 'vitest';
import { createTestDb } from './createDb';

let db: any;

beforeAll(() => { db = createTestDb(); });

describe('Agent Foundry e2e', () => {
  it('creates issue → task → event → queue → run', () => {
    db.prepare(`INSERT INTO issues (id,name,context_json) VALUES ('ISS-1','Demo','{}')`).run();
    const { lastInsertRowid: taskId } = db.prepare(`INSERT INTO tasks (issue_id,name) VALUES ('ISS-1','Dev')`).run();
    db.prepare(`INSERT INTO task_events (task_id,agent_name,event_seq,attempt_no) VALUES (?,?,?,?)`)
      .run(taskId, 'dev-agent', 1, 0);
    const ev = db.prepare(`SELECT id FROM task_events WHERE task_id=? AND event_seq=1`).get(taskId);
    db.prepare(`INSERT INTO task_event_queue (task_event_id) VALUES (?)`).run(ev.id);

    // lease
    db.prepare(`
      UPDATE task_event_queue
      SET lease_owner='dev', lease_expires=strftime('%Y-%m-%dT%H:%M:%fZ','now','+10 minutes')
      WHERE task_event_id=? AND lease_owner IS NULL
    `).run(ev.id);

    // log start/end
    db.prepare(`INSERT INTO task_event_runs (task_event_id,run_seq,worker_name,kind,data_json)
                VALUES (?,?,?,?,?)`).run(ev.id, 1, 'runner-1', 'start', '{}');
    db.prepare(`INSERT INTO task_event_runs (task_event_id,run_seq,worker_name,kind,data_json)
                VALUES (?,?,?,?,?)`).run(ev.id, 2, 'runner-1', 'end', '{"ok":true}');

    // complete
    db.prepare(`UPDATE task_events SET status='succeeded', finished_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(ev.id);
    db.prepare(`DELETE FROM task_event_queue WHERE task_event_id=?`).run(ev.id);

    const evRow = db.prepare(`SELECT status FROM task_events WHERE id=?`).get(ev.id);
    expect(evRow.status).toBe('succeeded');
  });
});
