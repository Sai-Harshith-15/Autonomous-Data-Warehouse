# Tool Registry

> **Machine-readable model:** `docs/tool-registry.yaml` (adjacent — consumed by `dispatch.sh`)
> **Status:** M1 — single-agent loop only
> **Updated:** 2026-07-26

## MCP Servers

| name | kind | capability | command | responsibility | status |
|------|------|-----------|---------|----------------|--------|
| `codebase-memory` | mcp | impact-analysis | `mcp:codebase-memory-mcp` | Verification | registered |
| `obsidian-memory` | mcp | documentation-lookup | `mcp:obsidian-main-memory` | Verification | registered |
| `headroom` | mcp | context-compression | `mcp:headroom` | Verification | registered |
| `ponytail` | mcp | code-quality-instructions | `mcp:ponytail` | Implementation | registered |
| `okf-secondary` | mcp | knowledge-retrieval | `mcp:okf-secondary-brain` | Verification | registered |

## Coding Agents (Data Plane)

| name | provider | model_id | role | opencode_command |
|------|----------|---------|------|------------------|
| `ds-pro` | opencode-go | `deepseek-v4-pro` | primary-coding | `opencode run -m opencode-go/deepseek-v4-pro --auto` |
| `ds-flash` | opencode-go | `deepseek-v4-flash` | fast-coding | `opencode run -m opencode-go/deepseek-v4-flash --auto` |
| `glm-52` | opencode-go | `glm-5.2` | planning-only | `opencode run -m opencode-go/glm-5.2 --auto` |
| `kimi-k3` | opencode-go | `kimi-k3` | planning-only | `opencode run -m opencode-go/kimi-k3 --auto` |

## Deterministic Tools

| name | cli | purpose |
|------|-----|---------|
| `git` | `git` | Version control, provenance, diff |
| `pytest` | `python -m pytest` | Test runner |
| `sha256sum` | `sha256sum` | Evidence hashing |
| `python` | `python` | JSON validation, YAML parsing |
| `cygpath` | `cygpath` | MSYS ↔ Windows path conversion |

## Model Routing (M1)

| Lane | Phase | Primary | Fallback |
|------|-------|---------|----------|
| `tiny` | implementation | `ds-pro` | `ds-flash` |
| `tiny` | planning | `glm-52` | `kimi-k3` |

## Agent Command Templates

```bash
# Planning task
opencode run -m opencode-go/glm-5.2 --auto -f <plan-file> "<goal>"

# Coding task
opencode run -m opencode-go/deepseek-v4-pro --auto --dir projects/<app>/ \
  -f <plan-file> "<task description>"

# Fast coding task (chores, simple fixes)
opencode run -m opencode-go/deepseek-v4-flash --auto --dir projects/<app>/ \
  "<task description>"
```
