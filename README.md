# Pictalis

A mobile-first iOS app that helps you distill a large batch of photos into a curated set of your best memories, using rapid pairwise comparisons and an Elo-style ranking system.

## What it does

Upload 100–300 photos from a trip, party, or shoot. The app shows you two photos at a time and asks which you prefer. After a few dozen quick picks, it surfaces your top 10–20 favorites — the ones worth keeping, like a talisman. No scrolling, no file management.

## Architecture

Monorepo with four subsystems:

| Directory | Stack | Purpose |
|-----------|-------|---------|
| `ios/` | SwiftUI, PhotosUI | iPhone app — photo selection, comparison UI, results |
| `backend/` | Supabase (Postgres + Edge Functions + Storage) | Session management, ranking API, pair selection, uncertainty scoring, temporary storage |
| `ranking-engine/` | TypeScript, Jest | Elo rating engine |
| `worker/` | Python 3.11, uv | Image embeddings, duplicate clustering, blur detection |

**Key design decisions:**
- Original photos never leave your device — only compressed working copies upload
- Uploaded copies auto-delete after 72 hours
- Ranking updates happen in real-time (< 200ms target)
- No AI aesthetic scoring — the user's choices drive everything

## Getting started

### Prerequisites

- Xcode 15+ (iOS development)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- [Supabase CLI](https://supabase.com/docs/guides/cli) — `brew install supabase/tap/supabase`
- [uv](https://docs.astral.sh/uv/) — `curl -LsSf https://astral.sh/uv/install.sh | sh`
- Node.js 20+

### iOS

```bash
cd ios
xcodegen generate
open Pictalis.xcodeproj
swiftlint lint   # requires `brew install swiftlint`
```

### Ranking engine

```bash
cd ranking-engine
npm install
npm test          # 9 tests
npm run typecheck
npm run lint
npm run format:check
```

### Processing worker

```bash
cd worker
uv sync --extra dev
uv run pytest -v  # 1 placeholder test
uv run ruff check src tests
```

### Backend (local Supabase)

```bash
cd backend
supabase start    # requires Docker
supabase db reset # applies migrations
```

## CI

GitHub Actions runs on every push and PR to `main` (path-filtered per subsystem):
- **iOS** - `swiftlint lint --strict` + `xcodebuild test` on an iPhone simulator
- **Edge Functions** - `deno fmt --check` + `deno lint` + `deno check` across all entry points + `deno test`
- **Migrations** - applies all migrations to a fresh local Supabase database
- **Ranking engine** - `npm test` + `npm run typecheck`
- **Processing worker** - `ruff` + `black --check` + `mypy` (strict) + `pytest`
- **Secret scan** - `gitleaks`, on every push and PR (not path-filtered)

On push to `main`, the Migrations and Edge Functions workflows also run a `deploy` job
that pushes to the real Supabase project, gated behind required-reviewer approval on the
`production` GitHub Environment; PRs never deploy. See `AGENTS.md` for details.

## Project status

MVP feature-complete. Core flow is end-to-end functional:

| Subsystem | Status |
|-----------|--------|
| iOS app | Full flow: session setup → photo selection → pairwise comparison → results/completion |
| Backend edge functions | 12 deployed: `create-session`, `register-photo`, `batch-pre-register`, `next-pair`, `submit-comparison`, `session-status`, `results`, `remove-photo`, `mark-upload-complete`, `start-cull`, `batch-submit-cull`, `finish-cull` |
| Database | 25 migrations applied: schema, storage, RLS (+ perf hardening), atomic comparison (Elo + comparison fetch computed in-RPC), phash, session stages, adaptive ranking, dedup stage, upload pipeline, local-first cull stage, comparisons FK indexes, abuse protection (rate limiting + photo caps) |
| Ranking engine | Elo + adaptive pair selection (9 tests passing) |
| Processing worker | Scaffolded — embeddings/clustering not yet wired |

Notable implemented features:
- Photo removal during comparison: suppresses a photo and clears open comparisons
- Session stage tracking: `cull → ranking → complete`
- Adaptive pair selection: prioritizes high-uncertainty pairs for efficient convergence

Scaffolded but not wired into any handler: a cluster-first dedup stage (`photos.phash`/`photos.cluster_id` columns, `_shared/phash.ts`, `_shared/pair-selection.ts`'s `selectDedupPair`/`isDedupComplete`, and a `dedup` value still allowed by the `sessions_stage_check` constraint). No code path ever sets or reads a `dedup` stage - `create-session` always starts sessions at `ranking`.

See [`docs/PRD.md`](docs/PRD.md) for the full product spec.
