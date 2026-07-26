# ADR-0001: Harness Installation — Upstream Core vs PRD Specification

> **Status:** Accepted
> **Date:** 2026-07-26
> **Deciders:** vanga, SDLC Orchestrator
> **Context:** Phase 0 — Foundation

---

## Context

The PRD (§8.2, §17 Phase 0) specifies a `harness-cli` with commands:
`init · migrate · audit · propose · intake · story · trace · decision · tool · query · rebuild · resume · approve · reject · report`

The actual upstream `repository-harness` v0.1.7 provides:
`install · update · status · doctor`

These are **fundamentally different systems**:

| Aspect | PRD Specification | Upstream repository-harness |
|--------|-------------------|----------------------------|
| **Philosophy** | Control-plane orchestration with SQLite DB, event log, typed contracts | Repository-centered workflow with docs as system of record |
| **State** | `harness.db` (SQLite projection of events) | Git + docs (no database) |
| **Intake** | `harness-cli intake --type feature --summary "..." --lane normal` | Human writes `docs/plans/active/<plan>.md` |
| **Stories** | `harness-cli story add --id US-XXXX --verify "<cmd>"` | Plan file tracks progress |
| **Gates** | `harness-cli story verify-all` | Behavior-appropriate tests run by agents |
| **Evidence** | `gates` table with `evidence_hash` | Test output, screenshots, logs in git |
| **Events** | `events/*.jsonl` append-only log | Git history |
| **Contracts** | Typed JSON contracts with budgets, tools, models | `AGENTS.md` rules + plan context |

## Decision

**Adopt the upstream repository-harness philosophy for Milestone 1, with PRD-inspired extensions built as shell scripts.**

Rationale:

1. **The PRD over-specifies.** The upstream harness is battle-tested and simpler. The PRD's SQLite/event-sourcing layer is valuable but not required to prove the factory concept.
2. **A2 assumption failed as predicted.** The PRD itself flags this risk (§1.3 A2: "harness-cli supports all §20 subcommands — verify before Phase 1").
3. **Milestone 1 goal is proving end-to-end autonomy**, not building the full control plane. The upstream harness's `docs/plans/active/` + `AGENTS.md` rules provide enough structure for a single-agent loop.
4. **We can layer the PRD's control plane later.** The upstream harness doesn't prevent adding `harness-cli` extensions — it just doesn't provide them.

## What We Build Instead (Milestone 1)

| PRD Concept | Milestone 1 Replacement |
|-------------|------------------------|
| `harness-cli intake` | Human writes `docs/plans/active/<feature>.md` using template |
| `harness-cli story add` | Plan file has `## Stories` section with checkboxes |
| `harness-cli story verify` | `scripts/verify.sh <story-id>` runs the test command |
| `harness-cli trace` | `scripts/trace.sh <summary> <outcome>` appends to `events/YYYY-MM-DD.jsonl` |
| `harness-cli tool register` | `docs/TOOL_REGISTRY.md` markdown table |
| `harness-cli decision add` | `docs/decisions/ADR-NNNN-<title>.md` using template |
| `harness-cli approve` | Human edits plan file, changes `status: pending → approved` |
| `harness-cli report` | `scripts/report.sh` reads events + git log |

## Consequences

**Positive:**
- Milestone 1 ships in days, not weeks
- No Rust compilation needed on Windows
- Git remains the single source of truth (aligns with upstream philosophy)
- Agents can read plans and ADRs directly — no MCP translation layer

**Negative:**
- PRD's §8.3 `harness.db` schema deferred to Milestone 5+
- §12.1 typed task contracts simplified to plan files + JSON frontmatter
- §13.5 approval mechanics simplified to file edits + git commit
- §22.1 event schema exists but is minimal (trace.sh writes JSONL, not full event sourcing)

**Risks:**
- If we need the full control plane later, we'll have to migrate plan files → DB. Mitigation: keep plan files structured so migration is mechanical.
- The PRD's failure taxonomy (§15.1) has no automated enforcement. Mitigation: `scripts/feedback-loop.sh` implements classification in bash.

## References

- PRD §8.2, §17 Phase 0
- repository-harness v0.1.7: `docs/WORKFLOW.md` § Compatibility Control Plane
- Assumption A2 failure mode

---

*This ADR itself follows the upstream harness decision template.*
