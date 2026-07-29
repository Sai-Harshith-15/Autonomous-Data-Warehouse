# AI Software Factory — Mobile & Web Production Roadmap

**Target:** Production-grade mobile (React Native + Expo) and web (React 18 + TypeScript + Vite + Node.js) delivery via 5-agent parallel specialist model  
**Timeline:** 3 weeks for mobile scaffolding → 2 weeks for web → ongoing canary CI/CD  
**Performance Target:** 1–3 min per pipeline run (from 45 min today)

---

## 1. 5-Specialist Agent Model

| Agent | Model | Responsibility | Sandbox |
|-------|-------|---------------|---------|
| **Requirements Agent** | Claude Sonnet (`auto/reasoning:pro`) | Feature → Spec → Acceptance Criteria | T0 |
| **Architecture Agent** | Claude Opus (`auto/reasoning:pro`) | Spec → Design → ADRs → Interface Contracts | T0 |
| **Dev-Mobile Agent** | DeepSeek V4 Pro | React Native + Expo implementation | T1 (worktree) |
| **Dev-Web Agent** | DeepSeek V4 Pro | React 18 + Vite + Node.js implementation | T1 (worktree) |
| **QA + DevOps Agent** | DeepSeek V4 Pro | Tests → Security Scan → Docker Build → Release | T1–T2 |

### Task Contract Template (Dev-Mobile)

```json
{
  "task_id": "T-2026-0050",
  "goal": "Implement Expo onboarding screen with phone-auth flow",
  "owner_skill": "sdlc-frontend-engineer",
  "sandbox_tier": "T1",
  "inputs": ["docs/stories/US-0007.md", "docs/architecture/ADR-0004-mobile-auth.md"],
  "allowed_paths": ["mobile/src/screens/Onboarding/**", "mobile/src/navigation/**"],
  "verification": [
    "cd mobile && npx expo lint",
    "cd mobile && npx jest --passWithNoTests"
  ],
  "model": {"id": "opencode-go/deepseek-v4-pro", "temperature": 0},
  "depends_on": ["T-2026-0049"],
  "timeout_seconds": 900,
  "retry_policy": {"max_attempts": 2, "class": "TEST_FAILURE"}
}
```

### Task Contract Template (Dev-Web)

```json
{
  "task_id": "T-2026-0060",
  "goal": "Implement user dashboard page with metrics cards",
  "owner_skill": "sdlc-frontend-engineer",
  "sandbox_tier": "T1",
  "inputs": ["docs/stories/US-0008.md", "docs/architecture/ADR-0005-web-dashboard.md"],
  "allowed_paths": ["web/src/pages/Dashboard/**", "web/src/components/charts/**"],
  "verification": [
    "cd web && npx tsc --noEmit",
    "cd web && npm run lint",
    "cd web && npx vitest run"
  ],
  "model": {"id": "opencode-go/deepseek-v4-pro", "temperature": 0},
  "depends_on": ["T-2026-0059"],
  "timeout_seconds": 900
}
```

---

## 2. Mobile Workflow Profile

```
PRD Review
  │  Requirements Agent (Claude Sonnet)
  ▼
UX Flows (Figma exports or markdown wireframes)
  │  Requirements Agent + Human
  ▼
Architecture (RN + Expo + navigation + state)
  │  Architecture Agent (Claude Opus)
  ├─ ADR: State management (Zustand vs Redux vs Jotai)
  ├─ ADR: Navigation (Expo Router vs React Navigation)
  └─ ADR: API layer (tRPC vs REST vs GraphQL)
  ▼
Mobile Implementation (parallel agents)
  ├─ Dev-Mobile: Screens & Components
  └─ Dev-Mobile: API Client & Hooks
  ▼
API Integration
  │  Integration Engineer
  ▼
Unit Tests + Component Tests
  │  QA Agent
  ▼
Device/Emulator Tests (Expo Go or EAS)
  │  QA Agent
  ▼
Accessibility Checks (react-native-a11y + axe)
  │  QA Agent
  ▼
Security/Privacy Checks
  │  Security Reviewer (T0 read-only)
  ▼
Signed Build (EAS Build)
  │  DevOps Agent (T2)
  ▼
Store-Readiness Review
  │  Human Approval
  ▼
Release to TestFlight / Internal Track
  │  Release Manager
```

### Expo Project Skeleton

```
mobile/
├── app/                   # Expo Router pages
├── src/
│   ├── components/        # Reusable UI components
│   ├── screens/           # Screen-level components
│   ├── hooks/             # Custom hooks
│   ├── services/          # API client, auth, storage
│   ├── state/             # Zustand stores
│   ├── navigation/        # Expo Router config
│   ├── utils/             # Helpers
│   └── types/             # TypeScript types
├── assets/                # Images, fonts
├── __tests__/             # Jest + React Native Testing Library
├── app.json               # Expo config
├── eas.json               # EAS Build config
└── package.json
```

### Mobile Gate Checklist

| Gate | Tool/Command | Exit |
|------|-------------|------|
| TypeScript | `npx tsc --noEmit` | exit 0 |
| Lint | `npx expo lint` | exit 0 |
| Unit Tests | `npx jest --passWithNoTests` | exit 0 |
| A11y | `npx react-native-a11y-checker` | exit 0 |
| Build | `npx eas build --platform all --local` | exit 0 |
| Bundle Size | `npx expo-analyzer` | ≤ 2MB gzip |

---

## 3. Web Workflow Profile

```
PRD Review
  │  Requirements Agent (Claude Sonnet)
  ▼
Architecture (React 18 + Vite + Node.js)
  │  Architecture Agent (Claude Opus)
  ├─ ADR: API design (REST + tRPC hybrid)
  ├─ ADR: State management (React Query + Context)
  └─ ADR: Auth strategy (JWT + refresh tokens)
  ▼
Parallel Implementation
  ├── Dev-Web Frontend: Components, Pages (React 18 + TS + Vite)
  │     allowed_paths: [web/src/**]
  │     verification: [npx tsc --noEmit, npm run lint, npx vitest run]
  │
  └── Dev-Web Backend: API Routes, DB Access (Node.js + Express/Fastify)
        allowed_paths: [backend/src/**]
        verification: [npx tsc --noEmit, npm run lint, npm run test]
  ▼
Integration (merge frontend + backend)
  │  Integration Engineer
  ▼
E2E Tests (Playwright)
  │  QA Agent
  │  verification: [npx playwright test]
  ▼
Security Scan
  │  Security Reviewer
  │  tools: [npm audit, trivy]
  ▼
Docker Build
  │  DevOps Agent
  │  verification: [docker build --no-cache -t app:latest .]
  ▼
Canary Deploy
  │  Release Manager + Human Approval
  ▼
Production
```

### Web Project Skeleton

```
web/
├── src/
│   ├── components/        # Shared UI (shadcn/ui or custom)
│   ├── pages/             # Route pages
│   ├── hooks/             # Custom React hooks
│   ├── services/          # API client (tRPC or fetch wrapper)
│   ├── stores/            # State management
│   ├── utils/             # Helpers
│   └── types/             # TypeScript types
├── public/                # Static assets
├── tests/
│   ├── unit/              # Vitest unit tests
│   └── e2e/               # Playwright E2E tests
├── vite.config.ts
├── tsconfig.json
├── tailwind.config.js     # Tailwind v3
├── postcss.config.js
└── package.json

backend/
├── src/
│   ├── routes/            # API route handlers
│   ├── middleware/         # Auth, rate-limit, validation
│   ├── services/          # Business logic
│   ├── db/                # Database access + migrations
│   └── utils/             # Helpers
├── tests/
│   ├── unit/
│   └── integration/
├── Dockerfile
├── tsconfig.json
└── package.json
```

---

## 4. Canary Deployment Config

### Release Pipeline

```
Initial:  main branch tagged v1.x.x
            │
            ▼
GitHub Actions Workflow
            │
    ┌───────┴───────┐
    │               │
  Build Web      Build Mobile
  (npm build)    (eas build)
    │               │
  Docker Push    EAS Submit
    │               │
    ▼               ▼
  Canary 5%      TestFlight
    │
  15min watch period
    │
   error_rate > 1%? ──YES──► Rollback + Alert
    │ NO
    ▼
  Canary 25%
    │
  30min watch period
    │
   p99_latency > 2s? ──YES──► Rollback + Alert
    │ NO
    ▼
  Gradual 100%
    │
  60min watch period
    │
   crash_rate > 0.1%? ──YES──► Rollback + Alert
    │ NO
    ▼
  Production (stable)
```

### Canary Config (GitHub Actions)

```yaml
# .github/workflows/canary-deploy.yml
name: Canary Deploy

on:
  push:
    tags:
      - 'v*'

env:
  DOCKER_IMAGE: ghcr.io/${{ github.repository }}/app
  CANARY_PERCENTAGES: 5 25 100
  WATCH_MINUTES: 15 30 60

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      deployments: write

    steps:
      - uses: actions/checkout@v4

      - name: Build Docker image
        run: docker build -t $DOCKER_IMAGE:${{ github.sha }} .

      - name: Push to registry
        run: |
          docker push $DOCKER_IMAGE:${{ github.sha }}

      - name: Deploy canary (5%)
        run: |
          kubectl set image deployment/app app=$DOCKER_IMAGE:${{ github.sha }}
          kubectl scale deployment/app --replicas=$((TOTAL_REPLICAS * 5 / 100))
          sleep 900  # 15 min watch

      - name: Check rollback triggers
        run: |
          ERROR_RATE=$(curl -s $HEALTH_ENDPOINT/metrics | grep error_rate | cut -d' ' -f2)
          if (( $(echo "$ERROR_RATE > 1" | bc -l) )); then
            echo "Error rate $ERROR_RATE% exceeds 1% — rolling back"
            kubectl rollout undo deployment/app
            exit 1
          fi

      - name: Deploy canary (25%)
        if: success()
        run: |
          kubectl scale deployment/app --replicas=$((TOTAL_REPLICAS * 25 / 100))
          sleep 1800  # 30 min watch

      - name: Deploy 100%
        if: success()
        run: kubectl scale deployment/app --replicas=$TOTAL_REPLICAS
```

### Auto-Rollback Triggers

| Trigger | Threshold | Check Interval | Action |
|---------|-----------|---------------|--------|
| Error rate | > 1% | 15s | Immediate rollback |
| p99 latency | > 2s | 30s | Rollback after 3 consecutive readings |
| Crash rate | > 0.1% | 60s | Immediate rollback |
| Failed health checks | > 5 consecutive | 10s | Immediate rollback |
| 5xx responses | > 2% of total | 15s | Rollback after 1min sustained |

---

## 5. Terraform + GitHub Actions CI/CD Skeleton

### Terraform Module Structure

```
infra/
├── environments/
│   ├── dev/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── terraform.tfvars
│   ├── staging/
│   │   └── ...
│   └── prod/
│       └── ...
├── modules/
│   ├── web-app/           # ECS/Fargate + ALB + CloudFront
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── mobile-api/        # API Gateway + Lambda (if using serverless)
│   │   └── ...
│   ├── database/          # RDS or DynamoDB
│   │   └── ...
│   └── monitoring/        # CloudWatch dashboards + alarms
│       └── ...
├── main.tf                # Root module
├── variables.tf
└── outputs.tf
```

### CI/CD Matrix

| Target | Build | Test | Package | Deploy |
|--------|-------|------|---------|--------|
| **Web Frontend** | `npm run build` | `npx vitest run` + `npx playwright test` | Docker → ghcr.io | ECS Fargate / Vercel |
| **Web Backend** | `npm run build` | `npm test` + `npm run test:integration` | Docker → ghcr.io | ECS Fargate |
| **Mobile iOS** | `eas build --platform ios` | `npx jest` | IPA → TestFlight | App Store Connect |
| **Mobile Android** | `eas build --platform android` | `npx jest` | AAB → Play Console | Internal Track |

### GitHub Actions Workflow Skeleton

```yaml
name: Build & Test

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  lint-and-test:
    strategy:
      matrix:
        project: [web, backend, mobile]
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20

      - name: Install dependencies
        working-directory: ${{ matrix.project }}
        run: npm ci

      - name: Lint
        working-directory: ${{ matrix.project }}
        run: npm run lint

      - name: Type check
        working-directory: ${{ matrix.project }}
        run: npx tsc --noEmit

      - name: Test
        working-directory: ${{ matrix.project }}
        run: npm test -- --coverage

  docker-build:
    needs: [lint-and-test]
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4
      - name: Build & push
        run: |
          docker build -t ghcr.io/${{ github.repository }}/web:${{ github.sha }} ./web
          docker push ghcr.io/${{ github.repository }}/web:${{ github.sha }}
```

---

## 6. Speed Timeline

| Stage | Description | Estimated Time | Steps |
|-------|-------------|---------------|-------|
| **Current** | No resource limits, no caching, single-threaded agents | **15–45 min** | — |
| **After Resource Limits** | `global_concurrency: 3`, Defender exclusions, resource pools | **8–12 min** | Day 1–2 |
| **After Evidence Cache** | Gate results keyed by git SHA, 24h TTL, skip unchanged gates | **3–5 min** | Day 2–3 |
| **After Parallel Workers** | 3-agent parallel dispatch, worktree isolation, DAG scheduler | **1–3 min** | Day 3–5 |
| **Mobile Scaffolding** | Expo project, navigation shell, API client template | **Week 2** | — |
| **Web Scaffolding** | Vite project, component library, backend API skeleton | **Week 2–3** | — |
| **Canary CI/CD** | GHA workflows, Terraform modules, canary deploy logic | **Week 3–4** | — |

### Bottleneck-Breaking Priority

```
Priority 1: Resource Limits + Defender Exclusions
  └── Simple config changes, immediate 4-5x speedup

Priority 2: Evidence Caching
  └── Rewrite verify.sh, add gates table, skip unchanged gates
  └── 2-3x additional speedup

Priority 3: Parallel DAG Scheduler
  └── Replace dispatch.sh with _dag_scheduler.py
  └── Full state machine, worktree isolation, resource pools

Priority 4: Dashboard + Observability
  └── FastAPI SSE server, live event streaming, health metrics
  └── Makes speed gains visible — critical for trust

Priority 5: Mobile + Web Scaffolds
  └── Expo + Vite project skeletons, task contracts, CI/CD

Priority 6: Canary Deploy + Production Release
  └── Terraform modules, GHA workflows, monitoring
```
