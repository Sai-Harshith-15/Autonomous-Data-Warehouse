# M2 Implementation Plan

> **Planned by:** GLM 5.2 (via OmniRoute auto/reasoning:pro)
> **Executed by:** SDLC Orchestrator + DeepSeek V4 Pro
> **Date:** 2026-07-27

## Architecture

```
Planner (GLM 5.2) → DAG → dispatch.sh v3
                              ├── Backend Agent → projects/todo-app/backend/
                              ├── Frontend Agent → projects/todo-app/frontend/
                              └── QA Agent → projects/todo-app/qa/
                                         ↓
                              integration.sh → merge + verify
```

## Steps

| Step | What | File | Model | DoD |
|------|------|------|-------|-----|
| **M2-S1** | 3 specialist skill files | `skills/sdlc/{backend,frontend,qa}/SKILL.md` | DS V4 Pro | Each has goal, tools, sandbox_tier |
| **M2-S2** | contract.sh | `scripts/contract.sh` | DS V4 Pro | Takes plan → outputs valid JSON contract |
| **M2-S3** | dag.sh | `scripts/dag.sh` | DS V4 Pro | Takes task list → outputs DAG JSON |
| **M2-S4** | dispatch.sh v3 | `scripts/dispatch.sh` | DS V4 Pro | Reads DAG, routes 3 agents in parallel |
| **M2-S5** | integration.sh | `scripts/integration.sh` | DS V4 Pro | Merges outputs, checks no overlap |
| **M2-S6** | Todo app: 3 agents parallel | `projects/todo-app/` | 3× DS V4 Pro | Backend API + Frontend HTML + QA tests |
| **M2-S7** | Output isolation proof | verify.sh | DS V4 Pro | No two agents wrote to same file |
| **M2-S8** | Integration merge + gate | integration.sh + verify.sh | DS V4 Pro | Merged app passes all tests |

## Dependencies

```
M2-S1 ──→ M2-S6 (agents need skills)
M2-S2 ──→ M2-S4 (dispatch needs contracts)
M2-S3 ──→ M2-S4 (dispatch needs DAG)
M2-S4 ──→ M2-S6 (dispatch routes agents)
M2-S6 ──→ M2-S7 (isolation check on outputs)
M2-S6 ──→ M2-S5 (integration needs outputs)
M2-S5 ──→ M2-S8 (merge proof)
M2-S7 ──→ M2-S8 (both needed for gate)
```
