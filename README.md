# Pictalis

A mobile-first iOS app that helps you distill a large batch of photos into a curated set of your best memories, using rapid pairwise comparisons and an Elo-style ranking system.

## What it does

Upload 100–300 photos from a trip, party, or shoot. The app shows you two photos at a time and asks which you prefer. After a few dozen quick picks, it surfaces your top 10–20 favorites — the ones worth keeping, like a talisman. No scrolling, no file management.

## Architecture

Monorepo with four subsystems:

| Directory | Stack | Purpose |
|-----------|-------|---------|
| `ios/` | SwiftUI, PhotosUI | iPhone app — photo selection, comparison UI, results |
| `backend/` | Supabase (Postgres + Edge Functions + Storage) | Session management, ranking API, temporary storage |
| `ranking-engine/` | TypeScript, Jest | Elo rating engine, pair selection, uncertainty scoring |
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
```

### Ranking engine

```bash
cd ranking-engine
npm install
npm test          # 9 tests
npm run typecheck
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

GitHub Actions runs on every push and PR to `main`:
- **Ranking engine** — `npm test` + `npm run typecheck`
- **Processing worker** — `pytest` + `ruff`

## Project status

MVP feature-complete. Core flow is end-to-end functional:

| Subsystem | Status |
|-----------|--------|
| iOS app | Full flow: session setup → photo selection → pairwise comparison → results/completion |
| Backend edge functions | 7 deployed: `create-session`, `register-photo`, `next-pair`, `submit-comparison`, `session-status`, `results`, `remove-photo` |
| Database | 9 migrations applied: schema, storage, RLS, atomic comparison, phash, session stages, adaptive ranking, dedup stage |
| Ranking engine | Elo + adaptive pair selection + cluster-first dedup stage (9 tests passing) |
| Processing worker | Scaffolded — embeddings/clustering not yet wired |

Notable implemented features:
- Cluster-first dedup stage: surfaces intra-cluster comparisons before broad ranking begins
- Photo removal during comparison: suppresses a photo and clears open comparisons
- Session stage tracking: `dedup → ranking → refine → complete`
- Adaptive pair selection: prioritizes high-uncertainty pairs for efficient convergence

See [`docs/PRD.md`](docs/PRD.md) for the full product spec.
