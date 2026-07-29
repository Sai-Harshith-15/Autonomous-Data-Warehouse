I’ll review the setup guide and the repository’s `Agent-os` implementation, then produce a concrete Markdown assessment covering the latency causes, Windows-specific fixes, and a production SDLC architecture for web and mobile delivery.The guide’s key signal is important: it describes a strong target architecture, but it also says the factory is still at foundation stage with zero harness execution. I’m checking whether the repository matches that blueprint or has accumulated orchestration overhead before the smallest end-to-end loop was proven.The repository confirms the visibility complaint: it has plans, sessions, approvals, evaluations, and several scripts, but no obvious operator console or single run-status surface. It also carries duplicated harness material under `.harness-core/base`, which can increase indexing/context noise even if it is not the sole runtime bottleneck. I’m turning this into a prioritized remediation document, separating quick Windows wins from factory-level redesign.# AI Software Factory: Performance and Production-Readiness Recommendations

## 1. Executive Assessment

Your repository has a useful foundation:

- Hermes as the orchestration layer.
- Specialist SDLC skills.
- A repository harness for plans, decisions, evidence, and workflow memory.
- OmniRoute-based model routing.
- Parallel dispatch through a DAG.
- Approval records, evaluations, stories, and session reports.
- Small proof-of-concept applications.

However, it is not yet a production-ready software factory. The current implementation is closer to an orchestration prototype.

The biggest problems are:

1. **Windows and WSL boundary overhead**
2. **Unbounded or ineffective parallel execution**
3. **Agent output is hidden until completion**
4. **The dispatch implementation does not execute the complete DAG**
5. **Agent responses are saved as text instead of safely applied and validated**
6. **No robust job-control plane**
7. **No structured progress, logs, metrics, cancellation, or recovery**
8. **Quality gates exist conceptually but are not yet authoritative**
9. **Too many roles can be invoked for work that should use one agent**
10. **Mobile and web production requirements are not encoded as reusable profiles**

The correct target is not “more agents.” It is a deterministic workflow engine that invokes agents only for work requiring judgment or code generation.

---

## 2. Why Tasks Are Taking Too Long

### 2.1 Files on `D:/` are probably being accessed from WSL

If Hermes, Python, Git, Node, tests, and agents run inside WSL while repositories are stored under `/mnt/d`, every file operation crosses the Windows-to-Linux filesystem boundary.

Agent workflows perform many small file operations:

- repository scanning;
- Git status and diff operations;
- dependency discovery;
- test collection;
- package installation;
- indexing;
- recursive searches;
- writes to artifacts and logs;
- worktree creation.

This is one of the most likely causes of your latency.

### Recommendation

Run the active workspace from the native WSL filesystem:

```text
/home/<user>/factory/
├── agent-os/
├── projects/
├── worktrees/
├── state/
└── cache/
```

Use `D:/` for:

- backups;
- archived artifacts;
- completed releases;
- exported reports;
- model caches that are proven to work well from Windows storage.

Do not use `/mnt/d/...` as the hot execution workspace.

A practical design is:

```text
WSL native filesystem:
  active repositories
  Git worktrees
  Python virtual environments
  node_modules
  build directories
  temporary artifacts
  SQLite state
  test caches

D:/:
  backups
  immutable release bundles
  long-term logs
  large downloaded assets
```

This change should be measured before introducing additional agents.

---

### 2.2 Windows Defender may scan every generated file

Agentic development creates and modifies many files quickly. Defender can scan:

- `.git`;
- `node_modules`;
- `.venv`;
- build outputs;
- coverage files;
- worktrees;
- SQLite journals;
- generated artifacts.

This can make Git, npm, Python, and test execution substantially slower.

### Recommendation

After reviewing the security tradeoff, add narrow Defender exclusions for trusted factory directories only. Do not exclude the entire drive.

Suitable candidates:

```text
WSL active workspace
Hermes cache
factory worktree directory
package-manager cache
generated artifact directory
```

Keep downloaded user files, secrets, and untrusted repositories outside those exclusions.

---

### 2.3 Your parallel dispatch can overload the machine

The current `dispatch.sh` starts one process per ready node using `os.fork()`. There is no clear global concurrency limit based on:

- RAM;
- CPU;
- provider quotas;
- model rate limits;
- task priority;
- per-project limits.

Parallelism helps only while the machine and providers have capacity. Past that point, it causes:

- memory pressure;
- swapping;
- API throttling;
- competing package installs;
- Git lock contention;
- slower aggregate completion;
- an unresponsive user experience.

### Recommendation

Begin with conservative limits:

```yaml
scheduler:
  global_concurrency: 2
  per_project_concurrency: 1
  expensive_model_concurrency: 1
  test_concurrency: 1
  max_retries: 2
  task_timeout_seconds: 900
```

Increase concurrency only after collecting metrics.

Use separate resource pools:

```yaml
pools:
  reasoning:
    concurrency: 1
  coding:
    concurrency: 2
  browser:
    concurrency: 1
  mobile_build:
    concurrency: 1
  security_scan:
    concurrency: 1
```

Parallelize independent lightweight work, not every role by default.

---

### 2.4 Your current DAG execution appears incomplete

The retrieved `dispatch.sh` selects nodes whose `depends_on` list is empty. It dispatches those ready nodes, waits for each group, and exits.

It does not visibly:

- mark nodes as completed;
- recalculate downstream readiness;
- execute later DAG levels;
- persist node state;
- resume a partially completed DAG;
- skip already successful nodes;
- propagate failures to dependent nodes.

That means the script is not yet a complete DAG scheduler.

### Required behavior

A production scheduler should repeat:

```text
load run state
    ↓
find pending nodes whose dependencies succeeded
    ↓
claim nodes within concurrency and quota limits
    ↓
execute nodes
    ↓
persist success/failure and evidence
    ↓
unlock downstream nodes
    ↓
repeat until complete, blocked, failed, cancelled, or awaiting approval
```

Node states should include:

```text
pending
ready
claimed
running
succeeded
failed
blocked
retrying
cancelled
awaiting_approval
```

State must be persisted after every transition so the factory can resume after a crash.

---

### 2.5 Agent output is saved, not integrated

The dispatcher asks a model to “write output to directories,” but it calls a chat completion endpoint. A chat model cannot write files unless it receives a real filesystem tool or runs inside a coding-agent process.

The script then saves the response to:

```text
artifacts/<node-id>/agent-output.md
```

This creates several problems:

- the requested project files may never be created;
- markdown fences may be returned despite prompt instructions;
- multiple files cannot be reconstructed reliably;
- paths are not validated;
- generated code is not immediately formatted or tested;
- arbitrary model text may be mistaken for executable code.

### Recommendation

Choose one of these execution contracts.

#### Contract A: Tool-enabled coding agent

Run Codex, Claude Code, or another coding agent inside an isolated Git worktree. Give it:

- a bounded working directory;
- explicit allowed paths;
- test commands;
- a task contract;
- a timeout;
- restricted shell and network permissions.

This is the preferred implementation.

#### Contract B: Structured patch output

Require a schema such as:

```json
{
  "summary": "Implemented health endpoint",
  "files": [
    {
      "path": "backend/routes/health.py",
      "operation": "create",
      "content": "..."
    }
  ],
  "commands_requested": ["pytest -q"]
}
```

Validate the schema, reject path traversal, write through trusted code, format, test, and inspect the diff.

Do not parse arbitrary conversational markdown into production files.

---

## 3. Make Progress Visible

Your statement that you “cannot see” what the factory is doing indicates an observability problem, not only a speed problem.

A ten-minute task with visible progress is manageable. A ten-minute silent task appears broken.

### 3.1 Stream events during every run

Each task should emit structured JSON Lines:

```json
{"time":"2026-07-28T16:00:00Z","run_id":"RUN-104","task_id":"BE-01","event":"queued"}
{"time":"2026-07-28T16:00:02Z","run_id":"RUN-104","task_id":"BE-01","event":"started","agent":"backend-engineer"}
{"time":"2026-07-28T16:00:05Z","run_id":"RUN-104","task_id":"BE-01","event":"tool_started","tool":"rg"}
{"time":"2026-07-28T16:00:09Z","run_id":"RUN-104","task_id":"BE-01","event":"model_waiting","provider":"openai"}
{"time":"2026-07-28T16:00:22Z","run_id":"RUN-104","task_id":"BE-01","event":"file_changed","path":"backend/main.py"}
{"time":"2026-07-28T16:00:26Z","run_id":"RUN-104","task_id":"BE-01","event":"gate_started","gate":"unit-tests"}
```

At minimum, expose:

- current stage;
- current task;
- assigned agent and model;
- elapsed time;
- latest tool invocation;
- files changed;
- tests completed;
- token use;
- cost;
- retries;
- queue depth;
- blocked reason;
- cancellation state.

---

### 3.2 Add a local control dashboard

A useful first dashboard should show:

```text
Run ID: RUN-104
Project: todo-app
State: validating
Elapsed: 08:41
Progress: 7/10 tasks

Running:
  QA-02  integration tests        01:12
  SEC-01 dependency scan          00:27

Completed:
  REQ-01 requirements             passed
  ARCH-01 architecture            passed
  FE-01 frontend implementation   passed
  BE-01 backend implementation    passed

Blocked:
  REL-01 awaiting human approval

Actions:
  pause | cancel | retry failed | view logs | inspect diff
```

A simple FastAPI service with Server-Sent Events is sufficient initially. WebSockets are optional.

---

### 3.3 Keep logs separate from final artifacts

Use a layout such as:

```text
runs/<run-id>/
├── run.json
├── events.jsonl
├── tasks/
│   └── <task-id>/
│       ├── request.json
│       ├── stdout.log
│       ├── stderr.log
│       ├── model.json
│       ├── result.json
│       └── evidence/
├── diffs/
├── reports/
└── summary.md
```

Logs should be streamed while a task runs. Do not wait for the entire process to finish before writing output.

---

## 4. Recommended Factory Architecture

```text
                         Human Operator
                               |
                    Intake, approvals, override
                               |
                               v
+------------------------------------------------------------------+
|                    FACTORY CONTROL PLANE                         |
|                                                                  |
|  API / CLI / Dashboard                                           |
|  Run Manager                                                     |
|  Durable DAG Scheduler                                           |
|  Policy and Approval Engine                                      |
|  Model Router and Quota Manager                                  |
|  Event Stream and Metrics                                        |
+------------------------------+-----------------------------------+
                               |
                               v
+------------------------------------------------------------------+
|                    DETERMINISTIC HARNESS                         |
|                                                                  |
|  Contract validation                                             |
|  Repository inspection                                           |
|  Worktree management                                             |
|  Formatting, linting, tests                                      |
|  Security scanning                                               |
|  Evidence collection                                             |
|  Diff-size and scope enforcement                                 |
|  Release checks                                                  |
+------------------------------+-----------------------------------+
                               |
                               v
+------------------------------------------------------------------+
|                         AGENT PLANE                              |
|                                                                  |
|  Requirements agent        Architect agent                       |
|  Backend agent             Frontend agent                        |
|  Mobile agent              QA agent                              |
|  Security reviewer         Release reviewer                      |
+------------------------------+-----------------------------------+
                               |
                               v
+------------------------------------------------------------------+
|                    ISOLATED EXECUTION PLANE                      |
|                                                                  |
|  Git worktree per task                                           |
|  Container or restricted process                                 |
|  Scoped credentials                                              |
|  CPU/RAM/time limits                                             |
|  Network allowlist                                               |
+------------------------------+-----------------------------------+
                               |
                               v
+------------------------------------------------------------------+
|                   EVIDENCE AND MEMORY PLANE                      |
|                                                                  |
|  PostgreSQL or SQLite for control state                           |
|  Files/object storage for artifacts                              |
|  Git for source and durable plans                                |
|  OpenTelemetry for traces and metrics                            |
|  Curated memory, ADRs, run summaries, evaluations                |
+------------------------------------------------------------------+
```

### Architectural principle

The orchestrator should decide **what happens next**. Agents should perform bounded work. Agents should not directly decide whether their own output is production-ready.

---

## 5. Hermes Agent Setup

Hermes should operate as the control-plane coordinator, not as a universal implementation agent.

### Hermes responsibilities

Hermes should:

- accept and normalize requests;
- select the workflow profile;
- create the run and task graph;
- dispatch specialist workers;
- enforce concurrency and quotas;
- request human approval when required;
- monitor task heartbeats;
- classify failures;
- trigger bounded retries;
- summarize evidence;
- produce the final release recommendation.

Hermes should not:

- run every role for every request;
- keep the complete repository in conversational memory;
- approve its own dangerous operations;
- trust agent-written claims without command evidence;
- perform long-running builds in its own process;
- hold unrestricted production credentials.

### Recommended profile structure

```text
hermes/profiles/sdlc-orchestrator/
├── profile.yaml
├── policies/
│   ├── approvals.yaml
│   ├── routing.yaml
│   ├── security.yaml
│   └── budgets.yaml
├── skills/
│   └── sdlc/
├── scripts/
│   ├── dispatch.sh
│   ├── gate-check.sh
│   ├── feedback-loop.sh
│   ├── run-status.sh
│   └── cancel-run.sh
├── prompts/
├── memories/
└── cron/
```

### Recommended default budgets

```yaml
budgets:
  max_run_minutes: 60
  max_task_minutes: 15
  max_agent_turns: 8
  max_retries_per_task: 2
  max_total_model_calls: 40
  max_parallel_tasks: 2
  require_approval_above_cost_usd: 5
```

Use project-specific overrides, but always enforce a hard ceiling.

---

## 6. Use Workflow Profiles Instead of One Giant SDLC

Not every task needs eleven specialists.

### Tiny profile

Use for documentation, configuration, and very small bug fixes:

```text
intake
implementation
targeted validation
review
```

One coding agent is often enough.

### Standard feature profile

```text
requirements
architecture checkpoint
implementation
unit and integration tests
security checks
review
release evidence
```

### High-risk profile

Use for authentication, payments, data migrations, permissions, cryptography, and production infrastructure:

```text
requirements
threat model
architecture approval
implementation
independent QA
independent security review
performance validation
staging deployment
human approval
production release
post-deployment verification
```

### Mobile profile

```text
product requirements
UX flows
architecture
mobile implementation
API integration
unit tests
device/emulator tests
accessibility
security/privacy checks
signed build
store-readiness review
human approval
```

This routing substantially reduces time and cost.

---

## 7. Production SDLC Stages

### Stage 1: Intake and classification

Inputs:

- user request;
- target project;
- constraints;
- target platforms;
- risk classification.

Outputs:

- normalized feature contract;
- definition of done;
- assumptions;
- required approvals;
- workflow profile.

Gate:

- no unresolved critical ambiguity;
- acceptance criteria are testable;
- repository and ownership are known.

---

### Stage 2: Requirements

Produce:

- functional requirements;
- non-functional requirements;
- accessibility requirements;
- security and privacy requirements;
- supported platforms;
- analytics and observability requirements;
- explicit exclusions.

Gate:

- acceptance criteria map to planned verification;
- requirements do not conflict;
- high-risk behavior is flagged.

---

### Stage 3: Architecture and design

Produce:

- component changes;
- API contracts;
- data model changes;
- migration and rollback strategy;
- trust boundaries;
- dependency decisions;
- ADRs for lasting decisions.

Gate:

- architecture is compatible with repository truth;
- rollback is defined;
- data-loss risk is addressed;
- security impact is identified.

---

### Stage 4: Planning and task graph

Each node should define:

```yaml
id: BE-01
title: Implement authenticated profile endpoint
agent: sdlc-backend-engineer
depends_on:
  - ARCH-01
inputs:
  - docs/contracts/profile-api.yaml
allowed_paths:
  - backend/app/profile/**
  - backend/tests/profile/**
verification:
  - uv run ruff check backend
  - uv run pytest backend/tests/profile -q
timeout_seconds: 900
retry_policy:
  max_attempts: 2
outputs:
  - git_diff
  - test_report
  - implementation_summary
```

Gate:

- no circular dependencies;
- every task has allowed paths;
- every task has deterministic verification;
- dangerous actions require approval.

---

### Stage 5: Isolated implementation

Use one Git worktree per task:

```text
worktrees/<run-id>/<task-id>/
```

Each task should have:

- a clean baseline;
- a dedicated branch;
- restricted write paths;
- dependency cache reuse;
- timeout;
- cancellation;
- captured stdout and stderr;
- a final diff.

Gate:

- no write outside allowed paths;
- no unresolved merge conflict;
- generated files are formatted;
- diff size remains within the task budget.

---

### Stage 6: Deterministic validation

Execute, where applicable:

- formatting;
- static analysis;
- type checking;
- unit tests;
- integration tests;
- contract tests;
- database migration tests;
- frontend build;
- mobile build;
- accessibility checks;
- dependency audit;
- secret scan;
- infrastructure validation.

Gate evidence must contain actual command details:

```json
{
  "gate": "unit-tests",
  "command": "uv run pytest -q",
  "exit_code": 0,
  "started_at": "2026-07-28T16:00:00Z",
  "finished_at": "2026-07-28T16:00:18Z",
  "stdout_path": "runs/RUN-104/tasks/QA-01/stdout.log",
  "git_sha": "abc123",
  "environment_digest": "sha256:..."
}
```

An agent saying “tests passed” is not evidence.

---

### Stage 7: Independent review

Review should evaluate:

- behavior against acceptance criteria;
- correctness;
- maintainability;
- scope;
- security;
- testing gaps;
- compatibility;
- operational impact.

Use semantic verification for important behavior. Passing tests alone does not prove the correct feature was built.

Examples:

- inspect changed API behavior against the contract;
- run UI workflows through Playwright;
- compare screenshots for key states;
- verify migration behavior with representative data;
- check denied authorization paths;
- verify logs and metrics appear.

---

### Stage 8: Integration

Before merging:

- rebase or merge the current target branch;
- rerun affected tests;
- run contract and integration suites;
- detect dependency conflicts;
- verify generated artifacts;
- confirm no unrelated files changed.

Do not merge agent branches merely because their isolated tests passed.

---

### Stage 9: Release readiness

Required evidence:

- release version;
- changelog;
- build provenance;
- artifact digest;
- dependency/SBOM report;
- vulnerability report;
- migration plan;
- rollback plan;
- runtime configuration validation;
- deployment manifest;
- approvals.

---

### Stage 10: Deployment and verification

Use progressive delivery:

```text
development
staging
canary or internal distribution
production
```

After deployment, run:

- health checks;
- smoke tests;
- synthetic user journey;
- log and error inspection;
- metric comparison;
- rollback trigger checks.

Production deployment should require explicit approval until the factory has substantial reliability history.

---

## 8. Quality Gates

### Universal gates

Every change should satisfy:

- acceptance criteria;
- clean working tree before execution;
- no unauthorized paths modified;
- formatting;
- linting;
- relevant tests;
- no committed secrets;
- dependency lock consistency;
- review evidence;
- traceability from requirement to verification.

### Web frontend gates

- TypeScript type checking;
- ESLint;
- unit/component tests;
- production build;
- Playwright critical-path tests;
- accessibility testing;
- responsive desktop/mobile screenshots;
- bundle-size budget;
- client-side error reporting;
- security headers validation;
- performance budget.

### Backend gates

- formatter/linter;
- type checking;
- unit tests;
- integration tests;
- API contract tests;
- authorization negative tests;
- migration up/down validation;
- dependency audit;
- container build;
- health/readiness endpoints;
- structured logs;
- timeout and retry behavior.

### Mobile gates

- platform-specific linting;
- unit tests;
- component/widget tests;
- emulator or simulator flows;
- API compatibility;
- offline/error-state verification;
- secure storage checks;
- permission usage validation;
- accessibility checks;
- signed release build;
- crash reporting initialization;
- deep-link verification;
- store metadata and privacy declarations.

For early cross-platform development, prefer one supported mobile stack, such as React Native with Expo or Flutter. Supporting native Android, native iOS, Flutter, and React Native simultaneously will multiply toolchain and test complexity.

---

## 9. Security Model

Agents must be treated as untrusted automation.

### Isolation requirements

Each task should execute with:

- a bounded working directory;
- no unrestricted access to the host filesystem;
- no production secrets;
- scoped temporary credentials;
- a network allowlist;
- CPU, memory, process, and time limits;
- command logging;
- a kill switch.

### Approval-required operations

Require a human decision for:

- production deployment;
- destructive database operations;
- credential creation or rotation;
- DNS changes;
- cloud IAM changes;
- payment configuration;
- mobile signing-key access;
- dependency updates with major versions;
- running downloaded executables;
- broad network access;
- bypassing failed gates.

### Secret handling

Use a proper secret manager. Inject secrets only into the task that requires them. Never place secrets in:

- prompts;
- Git;
- run summaries;
- unrestricted logs;
- agent memory;
- model request payloads unless strictly required and approved.

### Supply-chain controls

Add:

- dependency lock files;
- package integrity checks;
- SBOM generation;
- vulnerability scanning;
- secret scanning;
- container image scanning;
- artifact signing;
- provenance metadata;
- dependency-license policy.

---

## 10. Model Routing and Quota Management

Route by task complexity instead of assigning expensive models by job title alone.

```yaml
routing:
  classify_and_summarize:
    model_class: fast
  simple_code_change:
    model_class: coding_fast
  architecture:
    model_class: reasoning_strong
  complex_debugging:
    model_class: coding_strong
  independent_review:
    model_class: reasoning_strong
```

Add fallback rules:

```yaml
fallback:
  rate_limit:
    action: requeue_with_backoff
  provider_outage:
    action: switch_provider
  context_overflow:
    action: regenerate_context_pack
  repeated_test_failure:
    action: escalate_to_stronger_model
  budget_exceeded:
    action: await_approval
```

Do not call multiple models speculatively unless the task is high risk. For ordinary tasks, this creates cost and latency without reliable benefit.

---

## 11. Context Management

Do not send the entire repository and complete PRD to every agent.

Build a context pack containing:

```text
task contract
relevant AGENTS.md instructions
selected architecture decisions
affected file map
relevant source files
relevant tests
API/data contracts
recent failure evidence
allowed paths
verification commands
```

Use deterministic retrieval first:

- dependency graph;
- import graph;
- symbols;
- file ownership;
- test mapping;
- recent Git changes.

Use semantic retrieval only as a supplement.

Cache repository maps by Git commit so every task does not rescan the whole repository.

---

## 12. Failure Handling

Use a deterministic failure taxonomy:

```text
agent_error
tool_error
test_failure
environment_error
rate_limit
timeout
policy_violation
merge_conflict
invalid_output
infrastructure_failure
human_rejection
```

Retry only transient failures automatically.

```yaml
retry:
  rate_limit:
    max_attempts: 5
    strategy: exponential_backoff
  network_timeout:
    max_attempts: 3
  invalid_model_output:
    max_attempts: 1
  deterministic_test_failure:
    max_attempts: 0
  policy_violation:
    max_attempts: 0
```

For deterministic test failures, create a new repair task with the failure evidence. Blindly rerunning the same prompt wastes time and quota.

---

## 13. Windows and WSL Configuration

### Recommended operating model

Run the factory in WSL2:

- Hermes;
- orchestrator;
- Git;
- Python;
- Node;
- Docker client;
- scheduler state;
- active repositories.

Use Windows for:

- browser and IDE UI;
- Android Studio if required;
- device/emulator integration;
- archive storage;
- host monitoring.

### WSL resource configuration

Create `%UserProfile%\.wslconfig` with values appropriate for your machine:

```ini
[wsl2]
memory=12GB
processors=6
swap=4GB
localhostForwarding=true

[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
```

Do not copy these values blindly.

- On a 16 GB host, assigning 12 GB to WSL may leave Windows constrained.
- On a 32 GB host, 12-16 GB is generally more practical.
- Leave sufficient CPU and RAM for Windows, the browser, IDE, and mobile emulator.
- Restart WSL after changing configuration:

```powershell
wsl --shutdown
```

### Additional performance settings

- Keep active repositories in the WSL ext4 filesystem.
- Keep `.venv` and `node_modules` beside the WSL repository.
- Reuse package-manager caches.
- Avoid rebuilding containers unnecessarily.
- Use Docker BuildKit cache mounts.
- Avoid recursive file watchers across `/mnt/d`.
- Limit browser and Android emulator concurrency.
- Run mobile builds serially on typical desktop hardware.
- Enable Git maintenance for large repositories.
- Exclude artifacts and worktrees from language-server indexing where appropriate.

---

## 14. Repository-Specific Recommendations

Based on the visible repository contents, I would make these changes first.

### 14.1 Replace the current dispatcher

Rewrite `scripts/dispatch.sh` as a proper application, preferably Python or Rust, with:

- durable task state;
- complete dependency scheduling;
- concurrency control;
- subprocess execution without `os.fork()`;
- streamed logs;
- cancellation;
- task heartbeats;
- retries by failure class;
- resource pools;
- schema validation;
- resumability;
- graceful shutdown.

Shell is suitable for bootstrap and wrappers. It is a poor foundation for a durable multi-agent scheduler.

### 14.2 Normalize agent names

The repository contains names such as:

```text
sdlc-requirements-analyst
sdlc-software-architect
```

The dispatcher mapping appears to use:

```text
requirements-analyst
software-architect
```

These mismatches can cause fallback models or prompts to be selected silently.

Use a single registry:

```yaml
agents:
  sdlc-requirements-analyst:
    skill: .agents/skills/sdlc-requirements-analyst/SKILL.md
    default_model_class: reasoning_strong
  sdlc-software-architect:
    skill: .agents/skills/sdlc-software-architect/SKILL.md
    default_model_class: reasoning_strong
```

Validate all DAG agent references before a run begins.

### 14.3 Remove hard-coded endpoint behavior

The script defines an `OMNIROUTE_URL`, but the embedded Python visibly calls a literal localhost URL. Make all providers and endpoints configuration-driven and validate connectivity at startup.

### 14.4 Stop using fork-based orchestration

`os.fork()` is not a portable Windows primitive and is an awkward fit across Git Bash, Cygwin, and WSL. Use:

- `asyncio.create_subprocess_exec`;
- a queue worker;
- a process supervisor;
- or container jobs.

### 14.5 Remove backup files from source

The visible tree includes:

```text
projects/fastapi-health/tests/test_health.py.bak
```

Backups should not be committed beside active tests. They can confuse search, indexing, and agents.

### 14.6 Separate examples from factory internals

Place sample applications in a clear area:

```text
examples/
```

Keep actual factory runtime projects elsewhere:

```text
workspaces/
```

This prevents agents from treating examples as control-plane code.

### 14.7 Establish authoritative documents

The repository contains installed harness core documents, the PRD, active plans, and project documents. Define precedence explicitly:

```text
consumer application code/tests/CI
    ↓
consumer AGENTS.md
    ↓
accepted product and architecture docs
    ↓
active execution plan
    ↓
factory defaults
    ↓
historical/upstream material
```

Without precedence rules, agents can follow stale or generic instructions.

---

## 15. Production Readiness Levels

### Level 0: Prototype

- manual execution;
- text artifacts;
- no persistent scheduler;
- no reliable visibility;
- no isolation.

Your implementation appears near this level.

### Level 1: Reliable local factory

- WSL-native workspace;
- durable scheduler;
- limited concurrency;
- streamed progress;
- worktree isolation;
- deterministic gates;
- cancellation and resume;
- evidence bundles.

This should be your immediate target.

### Level 2: Team-ready factory

- central run API;
- authentication and RBAC;
- PostgreSQL control plane;
- shared artifact storage;
- CI integration;
- policy engine;
- cost and quota controls;
- audit logs;
- staging deployment.

### Level 3: Production delivery factory

- isolated ephemeral workers;
- signed artifacts and provenance;
- secret manager;
- progressive delivery;
- rollback automation;
- service-level objectives;
- disaster recovery;
- independent security controls;
- regular agent evaluations.

Do not attempt Level 3 directly. First prove that Level 1 is reliable across dozens of small tasks.

---

## 16. Implementation Roadmap

### Phase 1: Measure and remove the largest bottlenecks

1. Move the active repository into WSL-native storage.
2. Record timings for Git, search, install, lint, tests, and model calls.
3. Limit concurrency to two workers.
4. Stream stdout, stderr, and status.
5. Add cancellation.
6. Add timestamps around every task phase.
7. Review Defender overhead using narrow exclusions where justified.

Success criteria:

- the UI remains responsive;
- every active task is visible;
- the system can be cancelled;
- time spent by category is measurable.

### Phase 2: Build a durable scheduler

1. Replace shell DAG execution with a scheduler service.
2. Persist run and task states.
3. Execute all DAG levels.
4. Add heartbeats and stale-task recovery.
5. Add resource pools and provider quotas.
6. Add bounded retries.
7. Support resume after process restart.

Success criteria:

- interrupted runs resume correctly;
- downstream nodes start only after dependencies pass;
- failed nodes block dependents;
- parallelism never exceeds configured capacity.

### Phase 3: Safe coding workers

1. Create one worktree per implementation task.
2. Run real tool-enabled coding agents.
3. Enforce allowed paths.
4. Capture diffs and commands.
5. Apply deterministic formatting and tests.
6. Reject invalid or out-of-scope output.
7. clean up worktrees only after preserving evidence.

Success criteria:

- model text is never blindly treated as code;
- workers cannot modify control-plane files unless authorized;
- every code change has a validated diff and test evidence.

### Phase 4: Production SDLC profiles

1. Implement tiny, standard, high-risk, web, backend, and mobile profiles.
2. Encode quality gates for each stack.
3. Add threat modeling and release approvals.
4. Add Playwright web validation.
5. Add emulator/simulator mobile validation.
6. Add staging deployment and smoke tests.

Success criteria:

- each project declares its stack profile;
- required gates are selected automatically;
- missing evidence blocks release.

### Phase 5: Observability and operations

1. Add OpenTelemetry traces.
2. Export task duration, queue, cost, and failure metrics.
3. Add a dashboard.
4. Create retention and redaction policies.
5. Define recovery procedures.
6. Run regular evaluation suites.

Success criteria:

- task latency can be broken down by queue, model, tool, and tests;
- regressions are detected from historical runs;
- logs do not expose secrets.

---

## 17. Metrics to Track

Track at least:

```text
run lead time
task queue time
model response time
tool execution time
test execution time
retry count
success rate by agent
success rate by model
first-pass gate success
human intervention rate
cost per successful feature
tokens per task
files changed per task
rollback rate
escaped-defect rate
mean time to recovery
```

Useful service-level objectives might be:

```text
95% of tiny tasks complete within 15 minutes
90% of standard runs require no scheduler recovery
100% of production releases contain gate evidence
100% of production deployments are cancellable before approval
0 secrets recorded in model transcripts or logs
```

These should initially be treated as targets, then adjusted using measured data.

---

## 18. Recommended Technology Choices

For the next implementation stage:

```text
Control API:       FastAPI
Scheduler:         Python asyncio initially
State:             SQLite WAL locally, PostgreSQL for team use
Event stream:      JSONL + Server-Sent Events
Observability:     OpenTelemetry
Metrics:           Prometheus
Dashboard:         Small React or server-rendered web UI
Artifacts:         filesystem locally, S3-compatible storage later
Isolation:         Git worktrees + containers
Web validation:    Playwright
Mobile validation: emulator/simulator + framework-native tests
Policy:            YAML rules initially, OPA when policy complexity warrants it
```

SQLite is acceptable for one local scheduler when configured correctly:

- WAL mode;
- busy timeout;
- a single writer pattern;
- short transactions;
- no database file on `/mnt/d`.

Move to PostgreSQL when multiple scheduler or worker processes need concurrent writes at team scale.

---

## 19. Immediate Configuration Baseline

```yaml
factory:
  workspace_root: /home/<user>/factory/workspaces
  worktree_root: /home/<user>/factory/worktrees
  state_root: /home/<user>/factory/state
  artifact_root: /home/<user>/factory/artifacts

scheduler:
  global_concurrency: 2
  per_project_concurrency: 1
  task_timeout_seconds: 900
  heartbeat_seconds: 15
  stale_after_seconds: 60

retries:
  transient_max_attempts: 3
  invalid_output_max_attempts: 1
  deterministic_failure_max_attempts: 0

limits:
  max_agent_turns: 8
  max_changed_files: 30
  max_diff_lines: 2000
  max_run_minutes: 60

security:
  network_default: deny
  production_credentials: deny
  path_enforcement: true
  secret_redaction: true
  require_approval_for:
    - production_deploy
    - database_destructive_change
    - iam_change
    - signing_key_access

observability:
  events_jsonl: true
  stream_logs: true
  opentelemetry: true
  capture_model_usage: true
  capture_tool_timings: true
```

---

## 20. Final Recommendation

Your highest-value next steps are:

1. Move active execution from `D:/` or `/mnt/d` to the WSL-native filesystem.
2. Limit the factory to two concurrent workers.
3. Replace the current shell dispatcher with a durable, observable scheduler.
4. Run real coding agents inside isolated Git worktrees.
5. Stream task progress and logs in real time.
6. Make deterministic quality gates authoritative.
7. Use small workflow profiles instead of invoking all specialists.
8. Add web and mobile stack-specific gate profiles.
9. Keep human approval for production, secrets, destructive data changes, and signing operations.
10. Prove reliability on small applications before increasing autonomy.

The main issue is not that Hermes needs more capability. The factory currently needs stronger control, execution, visibility, and evidence layers around Hermes. Once those layers are reliable, specialist agents can produce web and mobile applications without making Windows unusable or leaving you unable to tell whether a run is progressing.
