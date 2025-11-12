PRAGMA foreign_keys = ON;

-- Drop in dependency order
DROP TABLE IF EXISTS task_event_runs;
DROP TABLE IF EXISTS task_events;
DROP TABLE IF EXISTS task_event_queue;
DROP TABLE IF EXISTS task_run_edges;
DROP TABLE IF EXISTS tasks;
DROP TABLE IF EXISTS issues;

DROP TRIGGER IF EXISTS trg_edges_no_cycle_insert;
DROP TRIGGER IF EXISTS trg_edges_no_cycle_update;
DROP TRIGGER IF EXISTS trg_tasks_autoname;
DROP TRIGGER IF EXISTS trg_task_event_runs_prevent_updates;
DROP TRIGGER IF EXISTS trg_task_event_runs_prevent_deletes;
DROP TRIGGER IF EXISTS trg_tasks_prevent_attempt_overflow;
DROP TRIGGER IF EXISTS trg_issue_close_guard;
DROP TRIGGER IF EXISTS trg_task_close_guard;
DROP TRIGGER IF EXISTS trg_task_events_set_attempt;

-- ==== TABLE SCHEMAS ====

CREATE TABLE issues (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  description   TEXT NULL,
  status        TEXT NOT NULL DEFAULT 'open'
                CHECK (status IN ('open','in_progress','done','cancelled')),
  context_json  TEXT NOT NULL,
  metadata_json TEXT NULL,
  output_json   TEXT NULL,
  created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE tasks (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  issue_id            TEXT NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
  name                TEXT DEFAULT NULL,
  priority            INTEGER NOT NULL DEFAULT 100,
  status              TEXT NOT NULL DEFAULT 'queued'
                      CHECK (status IN ('queued','in_progress','blocked','done','failed','cancelled','skipped')),
  required_capability TEXT,
  attempt_no          INTEGER NOT NULL DEFAULT 0,
  max_attempts        INTEGER NOT NULL DEFAULT 3
  CHECK (attempt_no <= max_attempts),
  created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE task_run_edges (
  id          TEXT PRIMARY KEY,
  src_task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  dst_task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  edge_type   TEXT NOT NULL DEFAULT 'depends_on'
  CHECK (src_task_id <> dst_task_id),
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE task_events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id     INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  agent_name  TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'started'
              CHECK (status IN ('started','succeeded','failed','aborted')),
  event_seq   INTEGER NOT NULL CHECK (event_seq >= 1),
  attempt_no  INTEGER,
  started_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  finished_at TEXT,
  input_json  TEXT,
  output_json TEXT,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Queue (one row per task event)
CREATE TABLE task_event_queue (
  task_event_id INTEGER PRIMARY KEY REFERENCES task_events(id) ON DELETE CASCADE,
  lease_owner   TEXT,
  available_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  lease_expires TEXT,
  created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Runs (sub-steps inside an event)
CREATE TABLE task_event_runs (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  task_event_id INTEGER NOT NULL REFERENCES task_events(id) ON DELETE CASCADE,
  run_seq       INTEGER NOT NULL,
  at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  worker_name   TEXT NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('start','progress','end','error','log','metric','artifact')),
  data_json     TEXT,
  UNIQUE(task_event_id, run_seq)
);

-- ==== INDEXES ====

CREATE INDEX IF NOT EXISTS idx_tasks_issue ON tasks(issue_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_task_events_task ON task_events(task_id);
CREATE INDEX IF NOT EXISTS idx_task_events_status ON task_events(status);
CREATE INDEX IF NOT EXISTS idx_edges_src ON task_run_edges(src_task_id);
CREATE INDEX IF NOT EXISTS idx_edges_dst ON task_run_edges(dst_task_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_task_events_order
ON task_events(task_id, attempt_no, event_seq);
CREATE INDEX IF NOT EXISTS idx_task_events_task_attempt
ON task_events(task_id, attempt_no);
CREATE INDEX idx_runs_event ON task_event_runs(task_event_id);
CREATE INDEX idx_runs_event_kind ON task_event_runs(task_event_id, kind);
CREATE INDEX IF NOT EXISTS idx_teq_available ON task_event_queue(available_at);
CREATE INDEX IF NOT EXISTS idx_teq_lease
ON task_event_queue(lease_owner, lease_expires);

-- ==== TRIGGERS ====

-- DAG cycle guards

-- Prevent cycles on INSERT
CREATE TRIGGER trg_edges_no_cycle_insert
BEFORE INSERT ON task_run_edges
BEGIN
  SELECT RAISE(ABORT,'no self edges')
  WHERE NEW.src_task_id = NEW.dst_task_id;

  WITH RECURSIVE reach(x) AS (
    SELECT NEW.dst_task_id
    UNION ALL
    SELECT e.dst_task_id
    FROM task_run_edges e
    JOIN reach r ON e.src_task_id = r.x
  )
  SELECT RAISE(ABORT,'edge would create a cycle')
  WHERE EXISTS (SELECT 1 FROM reach WHERE x = NEW.src_task_id);
END;

-- Prevent cycles on UPDATE
CREATE TRIGGER trg_edges_no_cycle_update
BEFORE UPDATE OF src_task_id, dst_task_id ON task_run_edges
BEGIN
  SELECT RAISE(ABORT,'no self edges')
  WHERE NEW.src_task_id = NEW.dst_task_id;

  WITH RECURSIVE reach(x) AS (
    SELECT NEW.dst_task_id
    UNION ALL
    SELECT e.dst_task_id
    FROM task_run_edges e
    JOIN reach r ON e.src_task_id = r.x
    WHERE e.id <> NEW.id
  )
  SELECT RAISE(ABORT,'edge would create a cycle')
  WHERE EXISTS (SELECT 1 FROM reach WHERE x = NEW.src_task_id);
END;

-- Auto-name tasks if NULL
CREATE TRIGGER trg_tasks_autoname
AFTER INSERT ON tasks
WHEN NEW.name IS NULL
BEGIN
  UPDATE tasks
  SET name = 'task_' || lower(hex(randomblob(4)))
  WHERE id = NEW.id;
END;

-- Prevent UPDATES and DELETES to task_event_runs
CREATE TRIGGER trg_task_event_runs_prevent_updates
BEFORE UPDATE ON task_event_runs
BEGIN
  SELECT RAISE(ABORT, 'Updates are not allowed on task_event_runs');
END;

CREATE TRIGGER trg_task_event_runs_prevent_deletes
BEFORE DELETE ON task_event_runs
BEGIN
  SELECT RAISE(ABORT, 'Deletes are not allowed on task_event_runs');
END;

CREATE TRIGGER trg_tasks_prevent_attempt_overflow
BEFORE UPDATE ON tasks
WHEN NEW.attempt_no > NEW.max_attempts
BEGIN
  SELECT RAISE(ABORT, 'attempt_no cannot exceed max_attempts in tasks');
END;

-- Prevent status updates
CREATE TRIGGER trg_issue_close_guard
BEFORE UPDATE OF status ON issues
WHEN NEW.status IN ('done','cancelled')
BEGIN
  SELECT RAISE(ABORT,'Cannot close issue while tasks are active')
  WHERE EXISTS (
    SELECT 1
    FROM tasks t
    WHERE t.issue_id = NEW.id
      AND t.status IN ('queued','in_progress','blocked')
  );
END;

CREATE TRIGGER trg_task_close_guard
BEFORE UPDATE OF status ON tasks
WHEN NEW.status IN ('done','cancelled')
BEGIN
  SELECT RAISE(ABORT,'Cannot close task while task events are active')
  WHERE EXISTS (
    SELECT 1
    FROM task_events t
    WHERE t.task_id = NEW.id
      AND t.status IN ('started')
  );
END;

CREATE TRIGGER trg_task_events_set_attempt
AFTER INSERT ON task_events
WHEN NEW.attempt_no IS NULL
BEGIN
  UPDATE task_events
  SET attempt_no = (SELECT attempt_no FROM tasks WHERE id = NEW.task_id)
  WHERE id = NEW.id;
END;
