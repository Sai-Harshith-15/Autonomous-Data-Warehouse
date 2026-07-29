-- AI Software Factory — SQLite Schema v2
-- Path: D:/agent-os/scripts/db/schema.sql
-- Applied by: _dag_scheduler.py on first run (sqlite3 agent-os.db < schema.sql)

-- ─── Runs: Top-level pipeline execution ────────────────────

CREATE TABLE IF NOT EXISTS runs (
    run_id          TEXT PRIMARY KEY,            -- R-2026-07-28-001
    project         TEXT NOT NULL,               -- project name
    plan_path       TEXT,                        -- path to plan YAML
    git_sha         TEXT NOT NULL,               -- HEAD at run start
    git_branch      TEXT,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN (
                        'pending', 'running', 'succeeded',
                        'failed', 'cancelled', 'awaiting_approval'
                    )),
    workflow_profile TEXT DEFAULT 'standard',    -- tiny | standard | high-risk | mobile
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    started_at      TEXT,
    finished_at     TEXT,
    elapsed_ms      INTEGER,
    total_tasks     INTEGER DEFAULT 0,
    done_tasks      INTEGER DEFAULT 0,
    failed_tasks    INTEGER DEFAULT 0,
    total_cost_usd  REAL DEFAULT 0.0,
    total_tokens    INTEGER DEFAULT 0,
    metadata        TEXT DEFAULT '{}'            -- JSON blob for extras
);

-- ─── Tasks: Individual DAG nodes ───────────────────────────

CREATE TABLE IF NOT EXISTS tasks (
    task_id         TEXT PRIMARY KEY,            -- T-2026-0050
    run_id          TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    goal            TEXT NOT NULL,
    owner_skill     TEXT,                        -- sdlc-backend-engineer
    sandbox_tier    TEXT DEFAULT 'T1' CHECK (sandbox_tier IN ('T0','T1','T2','T3')),
    depends_on      TEXT DEFAULT '[]'            -- JSON array of task_ids
                    CHECK (json_valid(depends_on)),
    inputs          TEXT DEFAULT '[]',           -- JSON array of paths
    allowed_paths   TEXT DEFAULT '[]',            -- JSON array of globs
    verification    TEXT DEFAULT '[]',            -- JSON array of commands
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN (
                        'pending', 'ready', 'claimed', 'running',
                        'succeeded', 'failed', 'blocked',
                        'retrying', 'cancelled', 'awaiting_approval'
                    )),
    assigned_model  TEXT,                        -- model ID used
    agent_tool      TEXT,                        -- agent tool used (opencode, claude-code, etc.)
    timeout_seconds INTEGER DEFAULT 900,
    retry_count     INTEGER DEFAULT 0,
    max_retries     INTEGER DEFAULT 2,
    evidence_key    TEXT,                        -- sha256(git_sha + "|" + gate_name)
    failure_class   TEXT,                        -- TRANSIENT | TEST_FAILURE | etc.
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    started_at      TEXT,
    finished_at     TEXT,
    elapsed_ms      INTEGER,
    size_bytes      INTEGER,                     -- diff size in bytes
    commit_sha      TEXT,                        -- git commit SHA for this task's worktree change
    result_summary  TEXT,
    metadata        TEXT DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_tasks_run_id ON tasks(run_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_depends ON tasks(depends_on);

-- ─── Events: Immutable audit trail ─────────────────────────

CREATE TABLE IF NOT EXISTS events (
    event_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    schema_version  INTEGER DEFAULT 2,
    time            TEXT NOT NULL,               -- ISO 8601 with subseconds
    run_id          TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    task_id         TEXT,                        -- NULL for run-level events
    event_type      TEXT NOT NULL,
    agent           TEXT,
    tool            TEXT,
    file_changed    TEXT,
    gate            TEXT,
    elapsed_ms      INTEGER,
    outcome         TEXT,
    summary         TEXT,
    metadata        TEXT DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_events_run_id ON events(run_id);
CREATE INDEX IF NOT EXISTS idx_events_task_id ON events(task_id);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_time ON events(time);

-- ─── Resource Pool: Slot tracking ─────────────────────────

CREATE TABLE IF NOT EXISTS resource_pool (
    pool_name       TEXT PRIMARY KEY,            -- global | per_project | expensive | test
    max_slots       INTEGER NOT NULL,
    used_slots      INTEGER DEFAULT 0,
    last_updated    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

INSERT OR IGNORE INTO resource_pool VALUES ('global', 3, 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
INSERT OR IGNORE INTO resource_pool VALUES ('per_project', 1, 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
INSERT OR IGNORE INTO resource_pool VALUES ('expensive', 1, 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
INSERT OR IGNORE INTO resource_pool VALUES ('test', 1, 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));

-- ─── Gates: Evidence cache ─────────────────────────────────

CREATE TABLE IF NOT EXISTS gates (
    gate_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id          TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    task_id         TEXT REFERENCES tasks(task_id),
    gate_name       TEXT NOT NULL,               -- lint | typecheck | unit-tests | build | security
    git_sha         TEXT NOT NULL,
    cache_key       TEXT NOT NULL UNIQUE,         -- sha256(git_sha + "|" + gate_name)
    outcome         TEXT NOT NULL
                    CHECK (outcome IN ('pass', 'fail', 'skip', 'escalated')),
    exit_code       INTEGER,
    command         TEXT,
    stdout_path     TEXT,
    elapsed_ms      INTEGER,
    environment_digest TEXT,                     -- sha256 of env state at time of run
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    expires_at      TEXT NOT NULL,               -- created_at + 24h (don't cache forever)
    invalidated     INTEGER DEFAULT 0            -- 1 = manually invalidated
);

CREATE INDEX IF NOT EXISTS idx_gates_key ON gates(cache_key);
CREATE INDEX IF NOT EXISTS idx_gates_invalidated ON gates(invalidated);
CREATE UNIQUE INDEX IF NOT EXISTS idx_gates_active
    ON gates(cache_key) WHERE invalidated = 0;

-- ─── Housekeeping: Expire stale gates ─────────────────────

CREATE VIEW IF NOT EXISTS active_gates AS
SELECT * FROM gates
WHERE invalidated = 0
  AND expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now');

-- ─── Helpers ───────────────────────────────────────────────

-- Acquire a pool slot (transactional)
-- Usage: INSERT INTO pool_slots (pool_name, task_id) VALUES (?, ?);
CREATE TABLE IF NOT EXISTS pool_slots (
    slot_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    pool_name       TEXT NOT NULL REFERENCES resource_pool(pool_name),
    task_id         TEXT NOT NULL REFERENCES tasks(task_id),
    acquired_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE(pool_name, task_id)
);

-- Trigger: update used_slots on acquire
CREATE TRIGGER IF NOT EXISTS trg_slot_acquire
    AFTER INSERT ON pool_slots
BEGIN
    UPDATE resource_pool SET
        used_slots = used_slots + 1,
        last_updated = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE pool_name = NEW.pool_name;
END;

-- Trigger: update used_slots on release
CREATE TRIGGER IF NOT EXISTS trg_slot_release
    AFTER DELETE ON pool_slots
BEGIN
    UPDATE resource_pool SET
        used_slots = MAX(0, used_slots - 1),
        last_updated = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE pool_name = OLD.pool_name;
END;
