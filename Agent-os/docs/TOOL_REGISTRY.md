# Tool Registry — v2 (Multi-Provider)

> **Updated:** 2026-07-27 — OmniRoute integration
> **Machine-readable:** `docs/tool-registry.yaml`

## Architecture

```
dispatch.sh (orchestrator)
  │
  ├── PRIMARY: opencode-go/deepseek-v4-pro (best quality coding)
  ├── FALLBACK: opencode-go/deepseek-v4-flash (fast, cheap coding)
  ├── OVERFLOW: omniroute → auto/coding:fast (load-balances Claude/Gemini)
  │
  └── PLANNING: opencode-go/glm-5.2 + opencode-go/kimi-k3
```

OmniRoute acts as a **multi-provider proxy** — single endpoint, routes to cheapest available:
- `auto/coding:free` → free models across all providers
- `auto/coding:fast` → fastest coding model available
- `auto/best-coding` → best quality, cost not considered

## MCP Servers

| name | kind | capability | command | status |
|------|------|-----------|---------|--------|
| `codebase-memory` | mcp | impact-analysis | `mcp:codebase-memory-mcp` | registered |
| `obsidian-memory` | mcp | documentation-lookup | `mcp:obsidian-main-memory` | registered |
| `headroom` | mcp | context-compression | `mcp:headroom` | registered |
| `ponytail` | mcp | code-quality-instructions | `mcp:ponytail` | registered |
| `okf-secondary` | mcp | knowledge-retrieval | `mcp:okf-secondary-brain` | registered |

## Coding Agents — Provider → Model Map

### OpenCode Go (primary — rate-limited, resets periodically)
| model_id | role | cost | verified |
|----------|------|------|----------|
| `deepseek-v4-pro` | primary-coding | $ | ✅ live |
| `deepseek-v4-flash` | fast-coding | ¢ | ✅ live |
| `glm-5.2` | planning | $ | ✅ live |
| `kimi-k3` | planning | $ | ✅ live |

### OpenCode Zen (free tier — no auth/credits)
| model_id | role | verified |
|----------|------|----------|
| `deepseek-v4-flash-free` | overflow-coding | ✅ |
| `nemotron-3-ultra-free` | overflow-coding | ✅ |
| `laguna-s-2.1-free` | overflow-coding | ✅ |

### OmniRoute → Antigravity (Pro plan — API via localhost:20128)
| routing_id | resolves to | role | verified |
|------------|-------------|------|----------|
| `auto/coding:free` | best free | overflow-coding | ✅ |
| `auto/coding:fast` | fastest available | fast-coding | ✅ |
| `auto/coding` | balanced | primary-overflow | ✅ |
| `auto/best-free` | best free quality | backup-planning | ✅ |
| `antigravity/claude-sonnet-5` | Claude 5 | architecture | ✅ |
| `antigravity/gemini-3.1-pro-high` | Gemini Pro | planning | ✅ |
| `antigravity/claude-opus-4-6-thinking` | Claude Opus | deep-reasoning | ✅ |

### OmniRoute API
```
Endpoint:  http://localhost:20128/api/v1/chat/completions
Format:    OpenAI-compatible (SSE streaming)
Auth:      None (local)
```

## Deterministic Tools

| name | cli | purpose |
|------|-----|---------|
| `git` | `git` | Version control, provenance |
| `pytest` | `python -m pytest` | Test runner |
| `sha256sum` | `sha256sum` | Evidence hashing |
| `python` | `python` | JSON/YAML parsing |
| `cygpath` | `cygpath` | MSYS ↔ Windows conversion |
| `pi` | `pi --print` | Alternative harness (v0.82.1) |

## Dispatch Priority (M1)

1. **Try** `opencode-go/deepseek-v4-pro` (best quality)
2. **Failover** `opencode-go/deepseek-v4-flash` (same provider, cheaper)
3. **Overflow** `opencode/deepseek-v4-flash-free` (Zen free)
4. **Last resort** `curl -> OmniRoute -> auto/coding:free` (any free provider)

## Known Issues

- OmniRoute: SSE streaming only — dispatch.sh must handle streaming or use `stream:false`
- OpenCode Zen: `--base-url` flag doesn't exist — OmniRoute must be called via curl
- Pi agent: Untested with OmniRoute; standalone CLI at `C:/Users/vanga/AppData/Local/pi-node/current/pi`
