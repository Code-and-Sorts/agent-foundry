# Agent Foundry

## A lightweight SQLite orchestration core for agentic workflows

Agent Foundry provides a minimal schema and trigger set to coordinate LLM agents performing structured tasks.
It tracks **issues → tasks → agent events → runs** using a directed acyclic graph (DAG).

## Schema Overview

| Table                | Purpose                                   |
|----------------------|-------------------------------------------|
| **issues**           | Top-level work items (tickets). |
| **tasks**            | Units of work under each issue; include status, retries, and required capability. |
| **task_run_edges**   | DAG edges defining task dependencies (`src_task_id → dst_task_id`). |
| **task_events**      | Ordered steps (agents) for each task, e.g., dev → QA → review. |
| **task_event_queue** | Queue for ready-to-run events; supports leasing and backoff. |
| **task_event_runs**  | Immutable log of actions inside an event (start, progress, end, error). |

## Key Features

- **Dependency-safe DAG**: recursive triggers prevent cycles.
- **Task sequencing**: `event_seq` orders agent actions within a task.
- **Queue leasing**: `lease_owner`, `available_at`, and `lease_expires` coordinate work pickup.
- **Immutable logs**: updates/deletes blocked on `task_event_runs`.
- **Status guards**: prevents closing issues or tasks while active dependents remain.
- **Retry control**: prevents `attempt_no` from exceeding `max_attempts`.

## ERD

```mermaid
erDiagram
    issues ||--o{ tasks : "has"
    tasks ||--o{ task_events : "has events"
    task_events ||--o| task_event_queue : "queued as (0..1)"
    task_events ||--o{ TASK_EVENT_RUNS : "has run logs"
    tasks ||--o{ TASK_RUN_EDGES : "as dst"
    tasks ||--o{ TASK_RUN_EDGES : "as src"

    issues {
      TEXT id PK
      TEXT name
      TEXT description
      TEXT status  "open|in_progress|done|cancelled"
      TEXT context_json
      TEXT metadata_json
      TEXT output_json
      TEXT created_at
      TEXT updated_at
    }

    tasks {
      INTEGER id PK
      TEXT issue_id FK "issues.id"
      TEXT name
      INTEGER priority
      TEXT status  "queued|in_progress|blocked|done|failed|cancelled|skipped"
      TEXT required_capability
      INTEGER attempt_no
      INTEGER max_attempts
      TEXT created_at
      TEXT updated_at
    }

    TASK_RUN_EDGES {
      TEXT id PK
      INTEGER src_task_id FK "tasks.id"
      INTEGER dst_task_id FK "tasks.id"
      TEXT edge_type "depends_on"
      TEXT created_at
      TEXT updated_at
    }

    task_events {
      INTEGER id PK
      INTEGER task_id FK "tasks.id"
      TEXT agent_name
      TEXT status  "started|succeeded|failed|aborted"
      INTEGER event_seq ">= 1"
      INTEGER attempt_no
      TEXT started_at
      TEXT finished_at
      TEXT input_json
      TEXT output_json
      TEXT created_at
      TEXT updated_at
    }

    task_event_queue {
      INTEGER task_event_id PK,FK "task_events.id"
      TEXT lease_owner
      TEXT available_at
      TEXT lease_expires
      TEXT created_at
      TEXT updated_at
    }

    TASK_EVENT_RUNS {
      INTEGER id PK
      INTEGER task_event_id FK "task_events.id"
      INTEGER run_seq
      TEXT at
      TEXT worker_name
      TEXT kind "start|progress|end|error|log|metric|artifact"
      TEXT data_json
    }
```

## Basic Flow

```mermaid
flowchart TD
  %% Lanes
  subgraph UserSystem["User/System"]
    A[Create Issue]
    B[Create Tasks under Issue]
    C["Define Task Dependencies<br/>(task_run_edges)"]
    D["Define Task Events<br/>(agent_name, event_seq, attempt_no)"]
  end

  subgraph Orchestrator
    E{"All upstream task deps done?"}
    F["Enqueue First Event<br/>(task_event_queue)"]
    G{"Queue item available<br/>and unleased?"}
    H["Lease Event<br/>(set lease_owner,<br/>lease_expires)"]
    I["Start Event<br/>(task_events.status='started')"]
    J["Append Run Logs<br/>(task_event_runs: start/progress/...)"]
    K{"Event Finished?"}
    L{"Succeeded?"}
    M["Mark Event Succeeded<br/>(status='succeeded', finished_at)"]
    N[Dequeue Event]
    O{"Next event_seq exists?"}
    P[Enqueue Next Event]
    Q["Mark Task Done<br/>(when no more events)"]
    R["Mark Event Failed<br/>(status='failed', finished_at)"]
    S{"Attempts left?"}
    T["Increment tasks.attempt_no,<br/>backoff queue.available_at,<br/>restart from event_seq=1"]
    U[Mark Task Failed]
    V{"All tasks terminal<br/>(done/skipped/failed)?"}
    W[Issue may be closed]
  end

  %% Flow
  A --> B --> C --> D --> E
  E -- "No" --> E
  E -- "Yes" --> F --> G
  G -- "No" --> G
  G -- "Yes" --> H --> I --> J --> K
  K -- "No" --> J
  K -- "Yes" --> L
  L -- "Yes" --> M --> N --> O
  O -- "Yes" --> P --> G
  O -- "No"  --> Q --> V
  L -- "No"  --> R --> S
  S -- "Yes" --> T --> F
  S -- "No"  --> U --> V
  V -- "Yes" --> W
  V -- "No"  --> E
```

### Create an issue

 ```sql
 INSERT INTO issues (id, name, context_json) VALUES ('ISS-1', 'Demo Issue', '{}');
 ```

### Create tasks

 ```sql
 INSERT INTO tasks (issue_id, name, required_capability) VALUES ('ISS-1', 'Dev Work', 'dev');
 INSERT INTO tasks (issue_id, name, required_capability) VALUES ('ISS-1', 'QA Review', 'qa');
 ```

### Define dependencies

 ```sql
 INSERT INTO task_run_edges (id, src_task_id, dst_task_id)
 VALUES ('edge1', 1, 2); -- task 2 waits for task 1
 ```

### Create task events

 ```sql
 INSERT INTO task_events (task_id, agent_name, event_seq, attempt_no)
 VALUES (1, 'dev-agent', 1, 0),
(2, 'qa-agent', 1, 0);
 ```

### Queue the first event

 ```sql
 INSERT INTO task_event_queue (task_event_id) VALUES (1);
 ```

### Lease and process

 ```sql
 UPDATE task_event_queue
 SET lease_owner='dev-agent',
 lease_expires=strftime('%Y-%m-%dT%H:%M:%fZ','now','+10 minutes')
 WHERE task_event_id=1
 AND lease_owner IS NULL
 AND available_at <= strftime('%Y-%m-%dT%H:%M:%fZ','now');
 ```

### Log runs

 ```sql
 INSERT INTO task_event_runs (task_event_id, run_seq, worker_name, kind, data_json)
 VALUES (1, 1, 'worker-a', 'start', '{}'),
(1, 2, 'worker-a', 'end', '{"result":"ok"}');
 ```

### Complete event

 ```sql
 UPDATE task_events
 SET status='succeeded', finished_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
 WHERE id=1;
 DELETE FROM task_event_queue WHERE task_event_id=1;
 ```

## Concept Summary

- **Issues** are containers for **tasks**.
- **Tasks** depend on one another (DAG edges).
- Each **task** is executed through ordered **agent events**.
- **Events** enter the **queue** when ready and are leased to agents.
- Agents append **run logs** to `task_event_runs` as immutable facts.
- When all tasks in an issue succeed, the issue can be closed.

## Integration Notes

- Use with any language via SQLite (Node, Python, Go, etc.).
- Works offline and embeds cleanly in agentic frameworks.
- Combine with a lightweight orchestrator script to enqueue, lease, and monitor progress.
- Define each flow as a tool for your agents to use.
