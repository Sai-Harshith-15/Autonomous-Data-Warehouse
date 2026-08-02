I’ll inspect the current `Agent-os` tree and the prior gap document, then assess the harness for correctness, security boundaries, leakage paths, and testability. I’ll produce a replacement Markdown audit with concrete file references and prioritized findings.The repository now contains substantial control-plane material, run records, an API/dashboard implementation, and test suites—so it is clearly more mature than the earlier shell-only prototype. I’m verifying the runtime code and its tests rather than treating plans or completion reports as proof.Below is the Markdown content for a refreshed audit. Overall: the repository is materially improved from the earlier prototype, especially around scheduling, persistence, event streaming, and the dashboard. It is now closer to a Level 1 local factory—but several implementation defects and security/operational gaps still prevent calling it reliable or production-safe.

```md
# AI Software Factory — Follow-up Audit

**Repository reviewed:** `Agent-os`  
**Audit date:** 2026-07-29  
**Scope:** Scheduler, dashboard, scripts, repository layout, evidence handling, security posture, and readiness for web/mobile SDLC automation.

## Executive Result

The factory has improved substantially since the previous gap assessment.

Notable improvements now present in the repository:

- A Python-based multi-level DAG scheduler exists in `scripts/_dag_scheduler.py`.
- The scheduler persists run, task, gate, event, and resource-pool state in SQLite.
- The scheduler implements a fuller task lifecycle, including `pending`, `ready`, `claimed`, `running`, `succeeded`, `failed`, `blocked`, `retrying`, `cancelled`, and `awaiting_approval`.
- JSONL events are written per run.
- A FastAPI dashboard exists in `scripts/dashboard.py`.
- The dashboard includes APIs for health, runs, run detail, SSE event streaming, and task-log streaming.
- The repository contains scripts for approval, checkpointing, circuit breaking, contract validation, integration, verification, replay, resume, tracing, secrets, web/mobile scaffolding, and CI/CD scaffolding.
- There are planning documents for production hardening, web/mobile delivery, dashboard work, and control-plane upgrades.
- Resource pool concepts and gate-result caching are now implemented.

This is no longer merely a shell-dispatch prototype. It has the outline of a durable local control plane.

However, the implementation still has important correctness, portability, security, and reliability gaps. Several are severe enough that the factory should not yet be trusted with unattended code changes, secrets, releases, destructive actions, or production deployments.

## Current Maturity Assessment

| Area | Earlier state | Current state | Assessment |
|---|---|---|---|
| DAG execution | Initial shell dispatch | Python scheduler with task states | Improved substantially |
| Durable state | Limited or unclear | SQLite-backed runs/tasks/events/gates/pools | Improved |
| Progress visibility | Minimal | Dashboard, JSONL, SSE, log endpoints | Improved |
| Parallelism | Unbounded process dispatch | Resource-pool concept | Improved, but has defects |
| Retry behavior | Limited | Retry status and retry count | Present, but flawed |
| Evidence | Text artifacts | Gate logs, events, cache records | Better, but incomplete |
| Coding-agent execution | Model output concerns | Not proven by scheduler implementation | Still a major gap |
| Workspace portability | Windows-heavy paths | Still hard-coded Windows paths | Not resolved |
| Security isolation | Conceptual | No clear enforced sandboxing | Still high risk |
| Web/mobile delivery | Plans and scaffolding | Profiles/gates not proven authoritative | Partially implemented |
| Production release safety | Conceptual approvals | Scripts exist | Needs enforcement audit |

**Overall maturity:** between Level 1 and early Level 2 in architecture, but operational reliability currently remains closer to Level 1.

---

# 1. Positive Findings

## 1.1 A real scheduler has replaced the earlier simple dispatcher

The repository now contains:

```text
scripts/_dag_scheduler.py
scripts/_schedule_worker.py
scripts/schedule.sh
scripts/resume.sh
scripts/replay.sh
scripts/checkpoint.sh
```

The scheduler includes a multi-state lifecycle and repeatedly evaluates task readiness based on dependency status. This is a meaningful improvement over a dispatcher that only ran root DAG nodes.

The readiness logic is now intended to:

```text
pending
  ↓
ready
  ↓
claimed
  ↓
running
  ↓
succeeded / failed / retrying / blocked / cancelled
```

This is the correct architectural direction.

## 1.2 Durable control-plane state exists

The scheduler uses SQLite and enables:

```sql
PRAGMA journal_mode=WAL
PRAGMA busy_timeout=30000
```

For one local scheduler, SQLite in WAL mode is a reasonable initial choice.

The factory also records:

- runs;
- tasks;
- task states;
- events;
- gate results;
- resource-pool slots;
- retry counts;
- failure classes;
- elapsed times;
- task logs;
- run event streams.

This is much stronger than relying on shell process state.

## 1.3 Event streaming and dashboard visibility are now present

The dashboard exposes:

```text
/api/health
/api/runs
/api/runs/{run_id}
/api/events
/api/logs/{task_id}
```

The system writes events to:

```text
runs/<run-id>/events.jsonl
```

And task logs are expected in:

```text
runs/<run-id>/tasks/<task-id>/stdout.log
runs/<run-id>/tasks/<task-id>/stderr.log
```

This directly addresses the earlier problem of silent, opaque runs.

## 1.4 Gate evidence caching is a useful addition

The scheduler hashes the Git SHA and gate identity to cache successful gate results. This can reduce repeated test execution for unchanged code.

The intention is sound:

```text
same Git commit
+ same validation command
= reusable verification evidence
```

This should improve speed once corrected and carefully scoped.

## 1.5 The repository has expanded SDLC capabilities

The scripts directory now includes meaningful SDLC concerns:

```text
approve.sh
assemble.sh
broker.sh
checkpoint.sh
circuit-breaker.sh
compliance.sh
contract.sh
integration.sh
intent-gate.sh
secrets.sh
trace.sh
verify.sh
scaffold-cicd.sh
scaffold-mobile.sh
scaffold-web.sh
```

This demonstrates that the factory is moving toward an actual software-delivery harness rather than a generic multi-agent prompt runner.

---

# 2. Critical Findings

## 2.1 Critical: The retrieved Python files appear syntactically corrupted or invalid

The fetched source for both `scripts/_dag_scheduler.py` and `scripts/dashboard.py` contains formatting that would not execute as valid Python if it reflects the actual checked-in content.

Examples from the scheduler include patterns such as:

```python
import json, sys, os, time, hashlib, subprocess, threading from datetime import datetime, timezone from pathlib import Path
```

and:

```python
REPO_ROOT = Path(**file**).resolve().parent.parent
```

and:

```python
if **name** == "**main**":
```

Examples from the dashboard include:

```python
app.add_middleware(CORSMiddleware, allow_origins=["_"], allowmethods=[""], allow_headers=["*"])
```

and malformed spacing/escaping throughout.

If these representations match the real files, the scheduler and dashboard will fail to import or start.

### Risk

- The primary control plane may be non-functional.
- Existing plans may claim capabilities that are not executable.
- A failure may be masked if scripts are not covered by automated smoke tests.

### Required action

Immediately run syntax and import checks in the actual repository:

```bash
python -m py_compile scripts/_dag_scheduler.py
python -m py_compile scripts/dashboard.py
python -m py_compile scripts/_schedule_worker.py
```

Then run:

```bash
python scripts/_dag_scheduler.py --help
python scripts/dashboard.py
```

Add an automated CI gate:

```bash
python -m compileall scripts
```

Also add a basic scheduler smoke test that creates a temporary SQLite database, inserts a tiny two-task DAG, runs it, and verifies dependency sequencing.

### Acceptance criteria

- Every Python script compiles successfully.
- Dashboard imports and starts successfully.
- Scheduler can execute a two-level DAG.
- CI fails on Python syntax errors.

---

## 2.2 Critical: Hard-coded `D:/` paths remain throughout the control plane

The scheduler contains defaults such as:

```python
DB_PATH = os.environ.get("HARNESS_DB", "D:/agent-os/harness.db")
POOL_CONFIG = os.environ.get("POOL_CONFIG", "D:/hermes-factory/config/resource-pool.yaml")
RUNS_DIR = Path("D:/agent-os/runs")
```

The dashboard also defaults to:

```python
DB_PATH = os.environ.get("HARNESS_DB", "D:/agent-os/harness.db")
RUNS_DIR = Path(os.environ.get("RUNS_DIR", "D:/agent-os/runs"))
```

This creates several problems:

- It bypasses the repository root and local configuration.
- It will not work in WSL unless Windows drive mounts are intentionally used.
- It makes tests and ephemeral workspaces difficult.
- It risks putting SQLite WAL files, logs, and high-churn artifacts on the Windows filesystem.
- It conflicts with the earlier recommendation to use the WSL native filesystem for active work.

### Risk

Using `D:/` through WSL-mounted storage can cause substantial filesystem latency, especially for:

- SQLite WAL activity;
- Git worktrees;
- recursive scans;
- test caches;
- logs;
- node_modules;
- Python environments;
- browser-test artifacts.

### Required action

Make all paths configurable, relative by default, and WSL-native by default.

Recommended environment model:

```text
FACTORY_HOME=/home/<user>/factory
FACTORY_STATE_ROOT=/home/<user>/factory/state
FACTORY_RUNS_ROOT=/home/<user>/factory/runs
FACTORY_ARTIFACT_ROOT=/home/<user>/factory/artifacts
FACTORY_WORKTREE_ROOT=/home/<user>/factory/worktrees
```

Recommended Python pattern:

```python
REPO_ROOT = Path(__file__).resolve().parents[1]
FACTORY_HOME = Path(os.environ.get("FACTORY_HOME", REPO_ROOT / ".factory"))
DB_PATH = Path(os.environ.get("HARNESS_DB", FACTORY_HOME / "state" / "harness.db"))
RUNS_DIR = Path(os.environ.get("RUNS_DIR", FACTORY_HOME / "runs"))
```

Do not store the SQLite database on `/mnt/d` or `D:/` when the scheduler runs in WSL.

### Acceptance criteria

- No `D:/` path is hard-coded in scheduler, dashboard, or core scripts.
- A new checkout works without editing source files.
- The entire local factory can run from a WSL-native path.
- Production/team paths are supplied through configuration only.

---

## 2.3 Critical: Resource-pool concurrency enforcement is likely incorrect

The scheduler attempts to enforce pool capacity with:

```python
pool = conn.execute("SELECT * FROM resource_pool WHERE pool_name=?", (pool_name,)).fetchone()

if pool["used_slots"] >= pool["max_slots"]:
    return False

conn.execute(
    "INSERT OR IGNORE INTO pool_slots (pool_name, task_id) VALUES (?, ?)",
    (pool_name, task_id),
)
```

The issue is that the code checks `resource_pool.used_slots`, but the visible code does not update that field when adding or removing entries from `pool_slots`.

If `used_slots` is not maintained by a database trigger, every task may see the same stale count and be admitted. The intended global concurrency limit could therefore be bypassed.

### Risk

- Unbounded task concurrency.
- CPU and memory saturation.
- SQLite lock contention.
- Provider rate-limit failures.
- Concurrent Git/process conflicts.
- Slow dashboard and host instability.

### Required action

Use a transaction that derives capacity from actual slots, or maintain `used_slots` atomically.

Preferred approach:

```sql
BEGIN IMMEDIATE;

SELECT COUNT(*)
FROM pool_slots
WHERE pool_name = ?;

-- If count < max_slots:
INSERT INTO pool_slots(pool_name, task_id)
VALUES (?, ?);

COMMIT;
```

Also enforce a unique constraint:

```sql
CREATE UNIQUE INDEX IF NOT EXISTS pool_slots_unique_task
ON pool_slots(task_id);
```

Use separate resource pools such as:

```yaml
pools:
  global:
    max_slots: 2
  reasoning:
    max_slots: 1
  coding:
    max_slots: 2
  browser:
    max_slots: 1
  mobile_build:
    max_slots: 1
  security_scan:
    max_slots: 1
```

### Acceptance criteria

- A concurrency test proves no more than the configured number of tasks can run.
- Slot acquisition is atomic.
- Slots are released on success, failure, cancellation, timeout, and crash recovery.
- A task cannot hold duplicate pool slots.

---

## 2.4 Critical: Retry-state tasks are never made runnable again

The scheduler defines:

```python
STATE_RETRYING = "retrying"
```

But readiness only selects tasks with:

```python
if t["status"] != STATE_PENDING:
    continue
```

When a task fails and is eligible for retry, it is set to `retrying`:

```python
update_task_status(
    run_id,
    task_id,
    STATE_RETRYING,
    ...
)
```

There is no visible transition from `retrying` back to `pending` or `ready`.

This can leave tasks permanently stuck in the retrying state. The main loop then sees an active task, waits, and may eventually finish incorrectly or hit its iteration limit.

### Risk

- Runs may hang.
- Retry behavior may not actually retry.
- The factory can report misleading run outcomes.
- The dashboard may display tasks as active after their worker has already ended.

### Required action

Define an explicit retry policy and state transition.

For example:

```text
failed validation
  ↓
retrying
  ↓
backoff until retry_at
  ↓
pending
  ↓
ready
  ↓
claimed
  ↓
running
```

Store `retry_at` in the task table. The scheduler should promote a task from `retrying` to `pending` only when backoff has elapsed.

Do not automatically retry deterministic failures such as:

- lint failures;
- failing unit tests;
- contract failures;
- path-policy violations;
- invalid output;
- missing required evidence.

Those failures should create a repair task with failure evidence, not blindly rerun the same command.

### Acceptance criteria

- A transient task failure retries after backoff.
- A deterministic test failure does not loop automatically.
- Retry count and next retry time are visible in the dashboard.
- A run cannot remain stuck indefinitely in `retrying`.

---

## 2.5 Critical: Scheduler task execution does not appear to run coding agents

The scheduler’s `dispatch_task()` function is described as:

```python
"""Execute a task: runs verify_cmd, captures evidence."""
```

Its visible behavior is to run `verification` commands and mark a task successful if those commands pass.

It does not visibly:

- launch a coding agent;
- create a Git worktree;
- apply a structured patch;
- validate allowed paths;
- collect a code diff;
- run implementation commands;
- commit or merge changes;
- require an implementation result.

A task with no verification commands is automatically marked succeeded:

```python
if not verification_cmds:
    update_task_status(run_id, task_id, STATE_SUCCEEDED, elapsed_ms=0)
```

### Risk

A task can be marked successful without any implementation occurring.

This is a severe control-plane integrity issue. A scheduler must distinguish between:

```text
implementation completed
```

and:

```text
verification command exited successfully
```

### Required action

Introduce an explicit worker execution contract.

Each task should include:

```yaml
id: BE-01
kind: implementation
worker:
  type: coding_agent
  command:
    - codex
    - exec
    - --task-file
    - task-contract.json
workspace:
  mode: git_worktree
allowed_paths:
  - backend/app/**
  - backend/tests/**
verification:
  - uv run ruff check .
  - uv run pytest -q
required_evidence:
  - git_diff
  - changed_files
  - command_log
  - test_report
```

The scheduler should only mark an implementation task succeeded when all of the following are true:

- the worker process exited successfully;
- the result schema is valid;
- a permitted Git diff exists when a code change is expected;
- only allowed paths were modified;
- required deterministic gates passed;
- required evidence files were created.

### Acceptance criteria

- Implementation tasks actually invoke a bounded coding worker.
- No task is marked successful solely because it has no verification command.
- Every implementation task records its Git diff and changed-file list.
- Out-of-scope changes fail the task.

---

## 2.6 Critical: Arbitrary shell execution remains a command-injection risk

The scheduler uses:

```python
subprocess.run(
    cmd,
    shell=True,
    capture_output=True,
    text=True,
    timeout=...
)
```

If task definitions, agent outputs, plans, user requests, or external content can influence `verification` strings, this is a direct shell-injection path.

### Risk

A malicious or compromised task plan could execute arbitrary host commands.

Examples of dangerous effects include:

- reading local files;
- exfiltrating environment variables;
- deleting workspaces;
- modifying scheduler state;
- accessing SSH keys;
- installing untrusted software;
- opening network connections;
- changing system configuration.

### Required action

Do not use `shell=True` for untrusted or model-generated command content.

Use a command allowlist and structured arrays:

```yaml
verification:
  - name: unit-tests
    argv:
      - uv
      - run
      - pytest
      - -q
    cwd: backend
```

Then execute with:

```python
subprocess.run(
    argv,
    cwd=working_directory,
    shell=False,
    capture_output=True,
    text=True,
    timeout=timeout_seconds,
)
```

For any remaining shell wrapper, allow only factory-owned, versioned scripts from a known directory.

### Acceptance criteria

- Model-generated strings never go directly into a shell.
- Validation commands are structured arrays.
- Commands execute with `shell=False`.
- Commands are logged as an argument array plus working directory.
- The worker environment has restricted credentials and network access.

---

# 3. High-Severity Findings

## 3.1 No demonstrated task isolation or worktree enforcement

The current scheduler operates from shared configured directories and does not visibly create a dedicated Git worktree for each task.

### Risk

Without isolation, concurrent tasks can:

- overwrite each other’s files;
- produce nondeterministic test failures;
- create Git index locks;
- contaminate validation results;
- hide unrelated changes;
- modify factory control-plane files;
- corrupt shared dependency state.

### Required action

Use one worktree per task:

```text
worktrees/<run-id>/<task-id>/
```

Recommended sequence:

```text
base repository commit
  ↓
create isolated worktree
  ↓
run coding worker within worktree
  ↓
validate diff and gates
  ↓
preserve evidence
  ↓
merge through integration stage
```

Do not run two coding agents against the same working tree.

---

## 3.2 Dashboard CORS configuration is unsafe or malformed

The visible dashboard configuration includes:

```python
allow_origins=["_"]
allowmethods=[""]
allow_headers=["*"]
```

If the intended configuration is permissive, it should not be exposed beyond localhost without authentication. If the spelling in the retrieved source is literal, it is also invalid.

### Risk

A remotely accessible unauthenticated dashboard can leak:

- task names;
- source paths;
- run summaries;
- logs;
- failure details;
- internal topology;
- possibly secrets accidentally written to logs.

### Required action

For local-only use:

```python
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1:8199", "http://localhost:8199"],
    allow_credentials=False,
    allow_methods=["GET"],
    allow_headers=["Content-Type"],
)
```

Bind development dashboard to loopback only:

```bash
uvicorn dashboard:app --host 127.0.0.1 --port 8199
```

For team use, add:

- authentication;
- authorization;
- CSRF handling where relevant;
- audit logs;
- TLS termination;
- a reverse proxy;
- strict CORS origins.

---

## 3.3 Dashboard event and log endpoints expose data without authorization

Endpoints such as:

```text
/api/events
/api/logs/{task_id}
/api/runs/{run_id}
```

appear to have no authentication or access control.

### Risk

Anyone who can reach the service may inspect run activity and logs. Logs are a common source of accidental secret leakage.

### Required action

Until authentication exists:

- bind the service to `127.0.0.1` only;
- do not expose it through port forwarding or a public reverse proxy;
- do not use wildcard CORS;
- redact secret-like values before writing logs;
- document that it is a trusted local-development tool only.

For team deployment, require login and role-based permissions.

---

## 3.4 SQLite database safety needs schema and writer review

SQLite WAL is suitable for a local factory, but the implementation opens many short-lived connections from scheduler threads and dashboard endpoints.

Potential concerns:

- concurrent writes from worker threads;
- event insert contention;
- slot allocation races;
- database placement on Windows-mounted storage;
- no visible migration/version process;
- no visible backup/recovery process;
- possible corruption after abrupt shutdown if data is not handled carefully.

### Required action

- Keep the database on WSL ext4 storage.
- Use a schema migration tool or versioned SQL migrations.
- Use short transactions.
- Use a single scheduler writer or serialized database write queue if contention appears.
- Add `integrity_check` to a maintenance procedure.
- Back up state and artifacts separately.
- Add tests for concurrent event insertions and slot claims.

---

## 3.5 The scheduler’s stale-claim recovery is incomplete

The scheduler tracks stale claims in process memory:

```python
stale_claims = {}
```

A scheduler restart loses this in-memory tracking. It also only appears to recover tasks in `claimed`, not tasks stuck in `running`.

### Risk

After a crash, tasks can remain:

```text
claimed
running
retrying
```

without a reliable mechanism to determine whether the worker is alive.

### Required action

Persist heartbeat data in the database:

```text
claimed_at
started_at
heartbeat_at
worker_pid
worker_id
attempt_id
lease_expires_at
```

Use leases:

```text
worker claims task
  ↓
task lease expires unless heartbeats renew it
  ↓
scheduler recovers expired leases
```

On scheduler startup:

- detect expired claims and running leases;
- verify whether the worker is still alive where possible;
- mark abandoned tasks recoverable;
- release all associated pool slots;
- record an explicit recovery event.

---

# 4. Medium-Severity Findings

## 4.1 The run completion logic may report success despite blocked tasks

The scheduler selects final status using:

```python
run_status = STATE_SUCCEEDED if failed == 0 else STATE_FAILED
```

Blocked tasks do not appear to cause the run to be marked failed or incomplete.

A run with:

```text
failed = 0
blocked = 3
```

could be reported as succeeded.

### Required action

Use explicit final status rules:

```text
all tasks succeeded
  → succeeded

one or more failed tasks
  → failed

one or more blocked tasks and no failures
  → blocked

one or more awaiting approvals
  → awaiting_approval

run cancelled
  → cancelled
```

A blocked or awaiting-approval run must never be represented as successful.

---

## 4.2 Cache logic needs more complete invalidation keys

The gate cache is based on a Git SHA and gate identity. This is a good beginning, but gate outcomes also depend on:

- operating system;
- runtime version;
- lockfile;
- environment variables;
- dependency cache state;
- container image;
- test command version;
- tool version;
- external service version;
- hardware or emulator configuration.

### Required action

At minimum include:

```text
git_sha
gate_name
command
working_directory
environment_digest
toolchain_digest
lockfile_digest
```

Do not cache:

- deployment checks;
- integration tests against mutable external services;
- security scans with changing vulnerability databases;
- tests whose result depends on secrets or external state.

---

## 4.3 Gateway and provider credentials are not visibly protected

The factory includes provider routing, brokers, secrets scripts, and model operations, but the visible scheduler/dashboard code does not demonstrate:

- scoped credentials;
- secret injection policy;
- redaction;
- token rotation;
- provider request audit;
- payload minimization;
- network restrictions.

### Required action

Implement these baseline rules:

- Keep secrets outside the repository.
- Use a secret manager or OS credential store.
- Inject only task-specific short-lived credentials.
- Never include secrets in prompts, event records, JSONL, or task logs.
- Redact known key patterns before persistence.
- Do not give coding workers production credentials.
- Require human approval for production-secret access.

---

## 4.4 No authoritative agent registry is visible

The repository has skills under:

```text
.agents/skills/sdlc-backend-engineer
.agents/skills/sdlc-frontend-engineer
.agents/skills/sdlc-qa-engineer
.agents/skills/sdlc-security-reviewer
.agents/skills/sdlc-software-architect
```

Earlier concerns included names being inconsistent between plans and dispatch mappings. A central registry should make such mistakes impossible.

### Required action

Add an agent registry:

```yaml
agents:
  sdlc-backend-engineer:
    skill_path: .agents/skills/sdlc-backend-engineer/SKILL.md
    worker_type: coding_agent
    model_class: coding_strong
    allowed_task_kinds:
      - backend_implementation
      - backend_repair

  sdlc-security-reviewer:
    skill_path: .agents/skills/sdlc-security-reviewer/SKILL.md
    worker_type: review_agent
    model_class: reasoning_strong
    allowed_task_kinds:
      - security_review
```

Validate every task’s agent ID before creating a run.

---

## 4.5 Backup test files remain committed

The repository includes:

```text
projects/fastapi-health/tests/test_health.py.bak
```

It duplicates the active test file.

### Risk

- Confuses agents and code search.
- Increases context noise.
- May be collected unexpectedly by some tooling.
- Makes it unclear which artifact is authoritative.

### Required action

Remove it from the active repository or move historical material to an archive location outside executable projects.

Add ignore rules for:

```text
*.bak
*.orig
*~
```

---

## 4.6 Factory internals and example projects remain mixed

The repository currently contains:

```text
Agent-os/scripts/
Agent-os/docs/
Agent-os/projects/fastapi-health/
Agent-os/projects/hello-test/
Agent-os/projects/todo-app/
```

Examples and active factory-managed workspaces should be clearly differentiated.

### Required action

Use a layout like:

```text
Agent-os/
├── control-plane/
├── skills/
├── profiles/
├── policies/
├── scripts/
├── tests/
├── examples/
│   ├── fastapi-health/
│   └── todo-app/
└── workspaces/
    └── <managed-projects>
```

Keep runtime state out of the Git repository:

```text
.factory/
runs/
artifacts/
worktrees/
state/
cache/
```

These should generally be ignored by Git.

---

# 5. Possible Information Leaks

## 5.1 Logs and JSONL are the primary leak surface

The dashboard streams:

```text
runs/<run-id>/events.jsonl
runs/<run-id>/tasks/<task-id>/stdout.log
```

Potential leaked data includes:

- API keys printed by tools;
- bearer tokens;
- connection strings;
- Git remote URLs containing credentials;
- private package registry tokens;
- stack traces containing environment values;
- source code;
- user data used by tests;
- database records;
- internal hostnames;
- cloud account IDs.

### Required action

Implement a log-redaction layer before data is persisted or sent via SSE.

Redact at least:

```text
OPENAI_API_KEY
ANTHROPIC_API_KEY
GITHUB_TOKEN
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
DATABASE_URL
JWT secrets
Bearer tokens
private keys
password assignments
connection strings
```

Use both:

- exact environment-variable value redaction; and
- pattern-based redaction.

Do not depend only on regexes. Register active secret values at run startup and redact them from output.

---

## 5.2 Model requests may leak repository or secret context

A factory that sends large repository context to providers risks exposing:

- proprietary code;
- secrets accidentally committed;
- user data;
- private architecture documents;
- credentials in configuration;
- internal URLs and IP addresses.

### Required action

Before every model call:

- construct a small context pack;
- scan included files for secrets;
- exclude `.env`, key files, credential folders, production configuration, and local state;
- record a content manifest, not raw sensitive prompt payloads;
- require explicit policy approval for external-provider use with sensitive repositories.

---

## 5.3 Local dashboard must not become remotely exposed by accident

The dashboard should be treated as private operational tooling. Do not bind it to all interfaces unless it has authentication and secure transport.

Safe default:

```bash
uvicorn dashboard:app --host 127.0.0.1 --port 8199
```

Unsafe default until security is implemented:

```bash
uvicorn dashboard:app --host 0.0.0.0 --port 8199
```

---

# 6. Missing Controls for Production-Ready Web and Mobile Delivery

The repository has web/mobile scaffolding and planning documents, but the control plane needs reusable, authoritative workflow profiles.

## 6.1 Required web profile

```yaml
profile: web-standard
required_gates:
  - format
  - lint
  - typecheck
  - unit_tests
  - production_build
  - dependency_audit
  - secret_scan
  - accessibility_check
  - browser_smoke_test
  - responsive_screenshot_check
  - security_headers_check
```

For high-risk web changes, add:

```yaml
  - authorization_negative_tests
  - API_contract_tests
  - performance_budget
  - threat_model_review
```

## 6.2 Required backend profile

```yaml
profile: backend-standard
required_gates:
  - format
  - lint
  - typecheck
  - unit_tests
  - integration_tests
  - API_contract_tests
  - migration_test
  - authorization_negative_tests
  - dependency_audit
  - secret_scan
  - container_build
  - health_endpoint_check
```

## 6.3 Required mobile profile

```yaml
profile: mobile-standard
required_gates:
  - lint
  - typecheck
  - unit_tests
  - component_tests
  - emulator_or_simulator_smoke_test
  - release_build
  - permission_audit
  - secure_storage_check
  - accessibility_check
  - deep_link_check
  - offline_error_state_check
  - privacy_manifest_review
```

Mobile signing operations must require human approval.

---

# 7. Recommended Immediate Remediation Order

## Priority 0: Prove the current control plane executes

1. Compile every Python script.
2. Start the dashboard locally.
3. Run a two-level DAG smoke test.
4. Confirm scheduler events, task logs, task states, and dashboard updates work.
5. Confirm `retrying` tasks re-enter the scheduler correctly.
6. Confirm concurrency limits work under simultaneous load.

## Priority 1: Remove critical unsafe defaults

1. Eliminate hard-coded `D:/` paths.
2. Keep active state, SQLite, worktrees, virtual environments, caches, and logs on WSL-native storage.
3. Remove `shell=True` from task execution.
4. Use structured command arrays and a command allowlist.
5. Bind dashboard only to localhost.
6. Add log redaction.
7. Add a formal coding-worker execution contract.

## Priority 2: Add isolation and integrity guarantees

1. Create one Git worktree per implementation task.
2. Enforce allowed file paths.
3. Capture Git diff and changed files for every task.
4. Require deterministic verification evidence.
5. Add integration-stage validation before merge.
6. Implement leases and persistent heartbeats.
7. Ensure blocked tasks prevent successful run status.

## Priority 3: Make profiles authoritative

1. Add tiny, standard, high-risk, web, backend, and mobile profiles.
2. Make profile gates mandatory, not advisory.
3. Add a central agent registry.
4. Require explicit approval for secrets, deployments, signing keys, destructive database changes, IAM, and DNS.
5. Add a release evidence bundle.

---

# 8. Validation Test Plan

Before treating the factory as reliable, run the following tests.

## Test A: Scheduler dependency test

Create a DAG:

```text
REQ-01
  ↓
ARCH-01
  ↓
BE-01
  ↓
QA-01
```

Verify:

- `ARCH-01` does not start before `REQ-01` succeeds.
- `BE-01` does not start before `ARCH-01` succeeds.
- `QA-01` does not start before `BE-01` succeeds.
- all state transitions are recorded.
- events appear in the dashboard.

## Test B: Failure propagation test

Cause `ARCH-01` to fail.

Verify:

- downstream tasks become `blocked`;
- run state becomes `failed` or `blocked`, never `succeeded`;
- blocked reason identifies the failed dependency;
- resource slots are released.

## Test C: Concurrency-limit test

Configure:

```yaml
global:
  max_slots: 2
```

Create five independent tasks that each run for a known amount of time.

Verify:

- no more than two tasks are concurrently running;
- queued tasks begin only after slots release;
- no slot leak remains after completion.

## Test D: Retry test

Create one transiently failing task.

Verify:

- task is marked `retrying`;
- it receives a scheduled retry time;
- it returns to `pending` or `ready`;
- it runs again;
- retry count is correct;
- it either succeeds or terminally fails;
- the run does not hang.

## Test E: Crash recovery test

Kill the scheduler while a task is running.

Verify:

- task state and latest heartbeat persist;
- the next scheduler startup recognizes an expired lease;
- stale pool slots are released;
- task is recovered or safely failed;
- no task remains permanently `running`.

## Test F: Secret-redaction test

Pass a known test secret through a worker’s stdout/stderr.

Verify that the secret:

- does not appear in `stdout.log`;
- does not appear in `stderr.log`;
- does not appear in `events.jsonl`;
- does not appear in dashboard SSE responses;
- does not appear in database event records.

## Test G: Path-policy test

Have a coding worker attempt to modify:

```text
scripts/_dag_scheduler.py
```

when its contract only permits:

```text
projects/todo-app/backend/**
```

Verify that the task fails with a policy violation and the unauthorized change is not merged.

---

# 9. Final Verdict

The factory is clearly better than the earlier version. The introduction of a Python scheduler, SQLite persistence, task state modeling, event streams, log streaming, a dashboard, gate caching, and broader SDLC scripts represents meaningful progress.

The strongest improvements are:

- better visibility;
- a more complete DAG model;
- durable state;
- a dashboard foundation;
- an emerging control plane;
- broader workflow and quality-gate coverage.

The biggest remaining concerns are:

1. Confirm the Python source is valid and executable.
2. Remove hard-coded `D:/` paths and move active state to WSL-native storage.
3. Fix resource-pool slot accounting.
4. Fix retry-state scheduling.
5. Do not mark tasks successful without actual worker execution and evidence.
6. Remove `shell=True` from task execution.
7. Add worktree isolation and path enforcement.
8. Redact logs and prevent unauthenticated dashboard access.
9. Add persistent worker leases and crash recovery.
10. Make web, backend, and mobile profiles authoritative.

Do not yet use the factory for unattended production deployment, real production secrets, mobile-signing keys, destructive database operations, IAM changes, or public dashboard exposure.

The appropriate next milestone is:

```text
Reliable Local Factory
```

Its completion criteria should be:

- fully runnable scheduler and dashboard;
- WSL-native state and workspace paths;
- concurrency verified under load;
- retry and crash recovery verified;
- isolated worker worktrees;
- safe structured command execution;
- redacted logs;
- deterministic quality gates;
- evidence-backed implementation tasks;
- local-only authenticated or strictly loopback dashboard.

Once those controls are proven through repeated small projects, the factory will have a credible foundation for building and validating web and mobile applications.
```