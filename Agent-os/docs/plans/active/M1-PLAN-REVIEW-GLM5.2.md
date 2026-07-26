# M1 Foundation Plan — Review (GLM 5.2, Planning Reviewer)

> **Reviewer:** GLM 5.2 (planning role; no code written)
> **Date:** 2026-07-26
> **Artifacts reviewed:** `M1-FOUNDATION-PLAN.md`, `ADR-0001`, `PRD §1.3/§8.2/§12/§13.1/§14/§15/§22`, live `opencode` CLI probe (v1.18.5)
> **Audience:** Kimi K3 (co-planner), DeepSeek V4 Pro (implementer)

**Verdict up front:** the plan is directionally correct and ADR-0001 cleanly resolves the upstream-vs-PRD mismatch. But it has **three blocking gaps** (no plan-file schema, no verified dispatch command, no project scaffold for T10) and **two sequencing errors** (T04→T05 inverted; T08 not actually parallel). It is also not implementable as written by DeepSeek V4 Pro without further specification — the implementer would have to invent formats, which is exactly the kind of ambiguity PRD §15.1 routes backwards. Fix the gaps below *before* handing off.

---

## 1. Gap Analysis — What Blocks the First End-to-End Feature

### G1 — `dispatch.sh` invocation is unspecified (BLOCKING)

The plan says: *"Calls `opencode` with model `deepseek-v4-pro`"* (T06, line 103). Probing the installed CLI confirms the model exists and the binary works:

- `opencode` v1.18.5 is on PATH (`/c/Users/vanga/AppData/Roaming/npm/opencode`)
- `opencode models` lists `opencode/deepseek-v4-pro` ✓
- The non-interactive entry point is `opencode run [message..] -m opencode/deepseek-v4-pro --dir <cwd>`

But the plan does not specify:
- **Exact model string** — `opencode/deepseek-v4-pro` (provider-prefixed), not `deepseek-v4-pro`. The plan's literal string will fail.
- **Interactive vs. headless** — `opencode run` defaults to non-interactive but **will block on permission prompts** unless `--auto` is passed (or the server is configured to auto-approve). For a factory, `dispatch.sh` must be headless — which means either `--auto` (dangerous, must be scoped) or pre-approved permission config. **Decision needed before T06 starts.**
- **Prompt delivery mechanism** — positional message arg, `--prompt` flag, stdin, or `-f` file attachments. The plan says "constructs agent prompt" without saying how it's passed. For long prompts with embedded plan content, `-f <plan-file>` + positional message is the only sane shape; `dispatch.sh` needs this nailed down.
- **Working directory** — `opencode run --dir <path>` is the documented cwd flag. T06 doesn't say whether the agent runs in the repo root, in `projects/<app>/`, or in a worktree. ADR-0001 defers worktrees to M2, so T06 must run in `projects/<app>/` — but the plan never says that.
- **Output capture** — `opencode run --format json` emits raw JSON events; `--format default` is human-formatted. T06 says "capture agent output to `artifacts/<task-id>/agent-output.md`" without picking one. For machine-parseable traces (which T07 needs to classify failures), `--format json` is correct; for the human-readable artifact, `default`. Likely both. Specify.

**Fix:** add a **T06a — "Verify OpenCode Go + DeepSeek V4 Pro connectivity"** task that runs a one-line `opencode run -m opencode/deepseek-v4-pro --auto --dir <tmp> "create hello.py"` and asserts the file appears. Without this, T06's "test" (*"`dispatch.sh` produces code changes"*) is unfalsifiable until the script is already written.

### G2 — Plan-file format is undefined (BLOCKING)

T05 says: *"Reads plan file, extracts `verify_cmd` from YAML frontmatter."* T10 says: *"Plan file created with: goal, stories, verify_cmd, acceptance criteria."* Neither task **defines the schema**. DeepSeek V4 Pro will invent one. That violates §15.1: a spec ambiguity that should route back to planning — except the planner (us) is the one producing the ambiguity. The minimum schema must be pinned *in this plan* before T05 starts. Recommended:

```yaml
---
schema_version: 1
plan_id: US-0001
title: "Add /health endpoint"
status: active              # active | blocked | done
verify_cmd: "cd projects/fastapi-health && python -m pytest tests/ -x"
acceptance:
  - "pytest exits 0"
  - "curl localhost:8000/health returns JSON with status=ok"
owner_agent: sdlc-backend-engineer
model: opencode/deepseek-v4-pro
---
# Goal
<one paragraph>
## Stories
- [ ] S1 — scaffold FastAPI app
- [ ] S2 — add /health route + test
## Context for dispatcher
<files to read, ADRs to honor>
```

Without this, `verify.sh`, `dispatch.sh`, and `feedback-loop.sh` will each parse the file differently. This is a one-paragraph addition to the plan.

### G3 — First feature has no scaffold (BLOCKING)

T10 names the feature (FastAPI `/health` endpoint) and the target dir (`projects/fastapi-health/`) but does not say:
- Who creates the empty FastAPI scaffold — the agent in T10, or a T09.5 setup task?
- Where `pyproject.toml` / `requirements.txt` come from. A bare `pytest` call against a directory with no FastAPI install will fail with `ModuleNotFoundError`, not with a test failure — and `feedback-loop.sh` (T07) will misclassify that as `TEST_FAILURE` instead of `ENVIRONMENT`.
- Whether `projects/fastapi-health/` is its own git repo, a subdirectory of `Agent-os`, or a separate worktree. The plan's exit criterion *"`curl localhost:8000/health` returns JSON"* requires the server to actually be running, which means `verify.sh` needs to know how to start it (or the verify_cmd must `uvicorn … &` then poll). None of this is in T10's DoD.

**Fix:** add **T09.5 — "Scaffold `projects/fastapi-health/`"** as a manual one-time task (human or GLM 5.2): empty repo layout, `pyproject.toml` with fastapi+pytest+httpx, a single failing test, and a `Makefile` or `run.sh` that boots uvicorn in background. This isolates T10's uncertainty to "agent fills in the route" — which is the actual factory claim.

### G4 — Feedback loop has no routing table (SOFT BLOCKING)

T07 says: *"Classifies: TRANSIENT / TEST_FAILURE / CONTRACT_VIOLATION / SPEC_AMBIGUITY / ENVIRONMENT."* It doesn't say **how** a bash script classifies stderr into one of five buckets. PRD §15.1 gives detection signals (HTTP 429, exit≠0, etc.) but those signals need to be concretely mapped per failure class — and bash is the wrong tool for multi-pattern log classification. Two issues:

1. **Detection logic is non-trivial.** "TEST_FAILURE" requires knowing the verify_cmd was a test runner and that exit≠0 came from assertion failure, not from `python: command not found` (which is `ENVIRONMENT`). Doing this in `grep -E` chains inside `feedback-loop.sh` will produce brittle regex soup.
2. **Routing is undefined.** "Re-dispatches to same agent with failure context" — via what mechanism? Append a section to the plan file? Pass a new `--failure-context` flag to `dispatch.sh`? Create a new plan with `-v2` suffix? PRD §15.1 specifies contract versioning (`-v2`) but the M1 plan doesn't have contracts — only plan files.

**Fix:** T07 needs an explicit classification matrix in the plan:

| stderr / exit pattern | Class | Route |
|---|---|---|
| `command not found`, `ModuleNotFoundError`, `ECONNREFUSED` on startup | ENVIRONMENT | halt, escalate to human |
| `FAILED tests/`, `AssertionError`, pytest exit≠0 after collect | TEST_FAILURE | re-dispatch with `--failure-context artifacts/<id>/verify-output.txt` |
| `429`, `timeout`, `Temporary failure in name resolution` | TRANSIENT | sleep 2^n, retry ≤5 |
| Edit outside `outputs/` glob (post-hoc `git status` check) | CONTRACT_VIOLATION | abort, escalate |
| Agent output contains `?` in `## Open Questions` section of plan file | SPEC_AMBIGUITY | flag plan file `status: blocked`, halt |

For M1, drop FLAKE / MERGE_CONFLICT / BUDGET_EXCEEDED / MODEL_UNAVAILABLE / SECURITY_FINDING / INTENT_MISMATCH — six of PRD §15.1's eleven classes are unreachable in a single-agent single-attempt loop.

### G5 — Minor gaps

- **No `task_id` allocation scheme.** T04's `run_id` is defined (`R-YYYY-MM-DD-NNN`) but `task_id` and `story_id` formats aren't. Pick `T-YYYYMMDD-NNN` and `US-NNNN` and put them in the schema (G2).
- **`events/` lifecycle.** T04 writes `events/YYYY-MM-DD.jsonl` but doesn't say whether the directory is gitignored, fsynced, or rotated. PRD §12.3 says fsync on write; for M1 bash, `>>` is fine but say so.
- **`harness-cli.exe` interaction.** T02 test calls `harness-cli.exe doctor --json` — confirmed binary exists. But T04–T09 never say whether these scripts **use** `harness-cli` or replace it. ADR-0001 implies replacement (scripts in `Agent-os/scripts/`, not `harness-cli` subcommands). Make that explicit: "M1 scripts do NOT call harness-cli; they are peer shell scripts."
- **`projects/` and `artifacts/` and `events/` directories exist but are empty.** No `.gitkeep` strategy mentioned.

---

## 2. Sequence Validation

### Dependency graph critique

The plan's stated critical path:
```
T01 → T02 → T03 → T04 → T05 → T06 → T07 → T10 → T11 → T12
                (T08, T09 "parallelizable after T04")
```

**Two errors and one missing node:**

#### E1 — T04 ↔ T05 are inverted

The plan has T04 (trace.sh) → T05 (verify.sh). But T05's DoD says *"Calls `trace.sh` with outcome"* — i.e., **verify depends on trace, not the other way around**. So the order T04 → T05 is *technically* correct, but the reason given in the plan is wrong: the plan describes the dependency as "natural order" when actually it's a hard call-graph dependency.

The real subtlety: **trace.sh is the only true leaf**. Both verify and dispatch and feedback-loop and report all call trace. So trace must come first and must be **stable** — its arg schema is a contract consumed by 4 other scripts. The plan should call this out: changing `trace.sh` args after T05+ are written breaks everything downstream. Freeze trace's interface at T04 close.

#### E2 — T08 (tool registry) is NOT parallelizable with T06

The plan claims T08 can run anytime after T04. But T06's DoD says: *"Calls `opencode` with model `deepseek-v4-pro` (or configured model)"* — "configured" implies a configuration source. Where? ADR-0001 says tool registry is `docs/TOOL_REGISTRY.md` (markdown table). If T06 reads the model ID from `TOOL_REGISTRY.md`, then **T08 must precede T06**. If T06 hardcodes the model, T08 is decorative.

Resolution: T08 must produce a machine-readable fragment (e.g., `docs/TOOL_REGISTRY.md` plus a sibling `tool-registry.yaml` or a `# Tools` section in the plan-file schema) that T06 reads. **Move T08 before T06** in the critical path. T09 (report.sh) is correctly parallel — it only consumes `events/`.

#### E3 — Missing node: T00 connectivity check

As argued in G1, a 5-minute "opencode can call DeepSeek V4 Pro" check must precede T06. Insert as **T00** before T04 (so failure surfaces early, not after trace+verify are built):

```
T00 (verify opencode+DS connectivity)
   │
   ▼
T01 → T02 → T03 (done)
   │
   ▼
T04 (trace.sh)  ← freeze interface
   │
   ├──→ T08 (tool registry — emits machine-readable fragment)
   │         │
   ▼         ▼
T05 (verify.sh) ──→ T06 (dispatch.sh, consumes T08) ──→ T07 (feedback-loop)
   │                                                     │
   └──→ T09 (report.sh, parallel)                        ▼
                                                   T09.5 (scaffold fastapi-health)
                                                         │
                                                         ▼
                                                   T10 (first feature)
                                                         │
                                                         ▼
                                                   T11 (failure test)
                                                         │
                                                         ▼
                                                   T12 (retrospective)
```

**Minimum viable order to T10:** T00 → T04 → T08 → T05 → T06 → T09.5 → T10. (T07 not strictly required to *reach* T10, only to *recover* from it; T09/T11/T12 are post-evidence.)

---

## 3. Risk Assessment — Top 3 Risks for M1

### R-A: `opencode` permission model blocks headless dispatch (HIGH likelihood, HIGH impact)

`opencode run` without `--auto` will pause on tool-permission prompts (file writes, shell exec). With `--auto`, it auto-approves — which is the factory's actual requirement but voids the human-oversight story for M1. Worse: `--auto` semantics are global, not scoped per-tool — `dispatch.sh` cannot say "auto-approve writes inside `projects/` but deny `git push`". This is a real §13.3 capability-broker gap that ADR-0001 explicitly defers to M2+.

**Mitigation (M1 scope):** accept `--auto` for M1 with two compensating controls: (a) `--dir projects/<app>/` so the agent's cwd is the project sandbox, (b) a pre-dispatch `git status --porcelain` and post-dispatch diff outside `projects/<app>/` = `CONTRACT_VIOLATION`. Document this as a known M1 limitation in ADR-0002. Do NOT pretend this is sandboxed.

### R-B: Failure classification in bash is brittle (MEDIUM likelihood, MEDIUM impact)

T07 will be a `case "$stderr" in` block with regexes. It will misclassify `ENVIRONMENT` as `TEST_FAILURE` (the most common confusion), and on misclassification it will re-dispatch — burning DeepSeek V4 Pro tokens to fix a problem that's actually "FastAPI not installed." Kun's data (PRD §9.3) says token-inefficient tooling is a silent tax; misclassification is the same tax in worse clothing.

**Mitigation:** for M1, **downgrade T07's ambition**. Don't auto-classify all 5 PRD classes — handle only `TEST_FAILURE` (rerun same dispatch with stderr appended) and `ENVIRONMENT` (halt + write `status: blocked` to plan file). Everything else escalates to human with the full stderr artifact. This is 30 lines of bash instead of 200, and it's honest. PRD §15.1's full taxonomy is a Milestone 2 deliverable.

### R-C: No garbage-output detection (HIGH likelihood, LOW-MEDIUM impact for M1)

The plan assumes the agent produces *code*, then `verify.sh` tells us if it's *correct*. It does not handle the case where the agent produces **plausible-looking non-code** (a markdown essay about FastAPI, a diff in the wrong directory, an empty file with a confident commit message). `verify.sh` will exit non-zero, `feedback-loop.sh` will classify as `TEST_FAILURE` and re-dispatch — and the agent will confidently produce more garbage. PRD §14 calls this "self-certification"; M1 has no defense against it.

**Mitigation (cheap, M1-scoped):** add to T06's DoD: *"`dispatch.sh` post-checks: at least one file under `projects/<app>/` was modified (git diff non-empty). Empty diff = dispatch failure, route to T07 with class `EMPTY_OUTPUT` (new, M1-specific)."* And to T10's DoD: *"After dispatch, `ls projects/fastapi-health/*.py | wc -l ≥ 2`."* This won't catch sophisticated garbage, but it catches the dominant failure mode (agent didn't actually write anything).

---

## 4. Recommended Changes — Specific Edits to M1-FOUNDATION-PLAN.md

### Add tasks

| ID | Title | Purpose | Effort |
|---|---|---|---|
| **T00** | Verify OpenCode Go + DeepSeek V4 Pro connectivity | Run one-shot `opencode run -m opencode/deepseek-v4-pro --auto --dir /tmp/oc-test "create hello.py"`; assert file exists. Blocks T06 if it fails. | 30 min |
| **T04.5** | Freeze plan-file schema (G2) | Add the YAML frontmatter schema from §G2 above into the plan as a fenced block; reference from T05/T06/T07/T10. | 15 min |
| **T09.5** | Scaffold `projects/fastapi-health/` | Empty FastAPI repo: `pyproject.toml`, one failing test, `run.sh` boots uvicorn. Manual task, owner: GLM 5.2. | 1 hr |

### Reorder

- Move **T08 before T06** (T06 consumes the registry's model ID).
- Keep T04 → T05 order, but annotate: *"T04 freezes `trace.sh` arg schema; downstream tasks (T05–T07, T09) consume it as a contract."*

### Edit existing tasks

**T05 DoD — add:**
- [ ] Plan-file schema is the one defined in T04.5 (no ad-hoc parsing)
- [ ] `verify.sh` exits with the verify_cmd's exit code (not its own wrapper code)
- [ ] On non-zero exit, `verify.sh` writes stderr to `artifacts/<story-id>/verify-output.txt` AND appends a one-line summary to `artifacts/<story-id>/failure-class.txt` containing exactly one of: `TEST_FAILURE`, `ENVIRONMENT`, `UNKNOWN` (per R-B downgrade)

**T06 DoD — replace "Calls `opencode` with model `deepseek-v4-pro`" with:**
- [ ] Reads model ID from `docs/TOOL_REGISTRY.md` machine-readable fragment (not hardcoded)
- [ ] Invokes: `opencode run -m <model-id> --auto --dir projects/<app>/ -f <plan-file> "<task-description>"`
- [ ] Captures JSON event stream to `artifacts/<task-id>/agent-output.jsonl` AND human-readable to `agent-output.md`
- [ ] Post-check: `git -C projects/<app>/ status --porcelain` non-empty, else class `EMPTY_OUTPUT`

**T07 — reduce scope (per R-B):**
- [ ] Classifies ONLY: `TEST_FAILURE` (re-dispatch with failure context appended to prompt) and `ENVIRONMENT` (halt, set plan `status: blocked`)
- [ ] All other stderr patterns → `UNKNOWN` → halt + escalate to human
- [ ] Max 2 re-dispatches per story, then halt
- [ ] Re-dispatch prompt includes `artifacts/<story-id>/verify-output.txt` verbatim

**T10 DoD — add:**
- [ ] Pre-condition: T09.5 scaffold complete, `pytest` fails with `ModuleNotFoundError: fastapi` BEFORE dispatch
- [ ] Post-condition: `pytest` exits 0 AND `curl -s localhost:8000/health | jq -r .status` returns `ok`
- [ ] Server startup is part of verify_cmd (e.g., `./run.sh & sleep 2 && pytest && curl … && kill %1`)

### Remove

- **Drop from M1:** the `CONTRACT_VIOLATION`, `SPEC_AMBIGUITY`, `TRANSIENT` auto-handling in T07. These need worktree isolation (M2) and structured contracts (M2) to detect reliably. Handling them in bash is theatre.

---

## 5. Definition of Done for M1 (rewritten)

The current exit criterion — *"One real feature shipped through the factory with full evidence, zero human intervention after intake"* — is unfalsifiable. "Real" and "full" are vibes. Here is a measurable replacement:

### M1 is DONE when ALL of the following are true:

| # | Criterion | Measure | Target |
|---|---|---|---|
| **D1** | Connectivity | `opencode run -m opencode/deepseek-v4-pro --auto --dir <tmp> "create hello.py"` produces a file | 1 success in ≤ 2 attempts |
| **D2** | Trace infrastructure | `scripts/trace.sh --summary "smoke" --outcome success` appends a line to `events/$(date +%F).jsonl` that `jq` parses cleanly | exit 0, valid JSON |
| **D3** | Plan schema | `docs/plans/active/US-0001-health-endpoint.md` exists, validates against the T04.5 schema, has `verify_cmd` and ≥ 2 acceptance criteria | yaml parses, schema fields present |
| **D4** | Dispatch round-trip | `scripts/dispatch.sh --plan docs/plans/active/US-0001-health-endpoint.md --task "implement S1+S2"` runs to completion without human keystrokes | exit 0, `git -C projects/fastapi-health/ status --porcelain` non-empty |
| **D5** | Verification gate | `scripts/verify.sh US-0001` exits 0 AND `artifacts/US-0001/verify-output.txt` contains the string `passed` AND `artifacts/US-0001/evidence.sha256` exists | exit 0, 3 artifacts present |
| **D6** | End-to-end behavior | `curl -sS -m 5 http://localhost:8000/health` returns HTTP 200 with body matching `{"status":"ok","timestamp":"*"}` | `jq -r .status` = `ok` |
| **D7** | Failure recovery | After deliberately breaking `tests/test_health.py` (change assertion), `scripts/verify.sh` exits non-zero, `scripts/feedback-loop.sh` classifies as `TEST_FAILURE`, re-dispatch produces a fix, second `verify.sh` exits 0 — all without human edits to `projects/fastapi-health/` | exactly 1 re-dispatch, total time < 30 min |
| **D8** | Trace completeness | `events/$(date +%F).jsonl` contains ≥ 1 event of each: `TaskDispatched`, `GateChecked{passed}`, `GateChecked{failed}`, `TaskCompleted` — each with `schema_version`, `run_id`, `task_id`, `story_id`, `actor`, `outcome` | `jq -r .event | sort -u` covers the 4 types |
| **D9** | Time-box | M1 closes within **14 calendar days** of T04 start. If D7 not met by day 14, **descope** — drop T11, ship D1–D6, mark M1.1 for the feedback loop. | calendar check |

**Hard descope rule (echoing PRD R5):** if D7 hasn't fired by end of Week 2, M1 is **not** "almost done" — it's failed the autonomy claim. Cut scope, don't extend time.

### Explicitly NOT required for M1 DoD

- Token cost per story (S3) — no cost tracking in M1
- First-try gate pass rate > 70% (§22.3) — no baseline yet
- Autonomy rate ≥ 60% (S1) — one story is not a rate
- Any use of `harness-cli` beyond `doctor` — ADR-0001 defers

---

## 6. Notes for Kimi K3 (co-planner)

- The T04.5 schema is the single highest-leverage edit. If you change one thing, change that.
- The T00 connectivity check should run **today** — if `opencode/deepseek-v4-pro` isn't actually reachable from this profile, the entire M1 schedule is fiction. I verified the binary and model list, but I did **not** execute a real dispatch (would burn quota on a planning task).
- Consider whether T12 (retrospective) should be split: the *template* for the retrospective is plannable now; the *content* obviously isn't.

## 7. Notes for DeepSeek V4 Pro (implementer)

- Do **not** invent file formats. If T04.5 is not yet in the plan when you start T05, **stop and request it** — that's a SPEC_AMBIGUITY route-back, not a TODO.
- The `opencode run` invocation in T06 is exact. Do not paraphrase the flags. `--auto` is intentional and scoped to M1; ADR-0002 will record the risk.
- T07 is intentionally minimal. If you find yourself writing a regex longer than 80 chars to classify stderr, you've left M1 scope — halt and flag.
- All paths in scripts are repo-relative POSIX (`projects/fastapi-health/`, not `D:\GitRepo\…`). PRD §21.1 W6.

---

*Review by GLM 5.2 · planning-only · no code written · 2026-07-26*
