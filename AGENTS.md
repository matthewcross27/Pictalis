# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`Pictalis` is a photo curation iOS app. See docs/PRD.md for the full spec.

# Pictalis — Claude Code Constitution

## Project Overview
A mobile-first iOS app (SwiftUI) that helps users curate 100–300 photos
using pairwise Elo-style comparisons. See docs/PRD.md for full spec.

## Tech Stack
- iOS: SwiftUI, PhotosUI framework, async/await
- Backend: Supabase (Postgres + Edge Functions + Storage)
- Processing: Python worker (embeddings, duplicate clustering, blur detection)
- Ranking Engine: TypeScript, Elo + TrueSkill-inspired uncertainty scoring

## Architecture Constraints
- Original photos NEVER leave the device — only compressed copies upload
- Compressed working copies auto-delete after 72 hours (Supabase policy)
- API must be stateless and horizontally scalable
- Time-to-first-comparison target: < 10 seconds after upload begins

## Coding Standards
- Swift: SwiftUI only (no UIKit), async/await (no Combine), strict concurrency
- TypeScript: strict mode, Zod for all API boundary validation
- Python: type hints required, black formatter
- All new Supabase tables require a migration file in backend/supabase/migrations/
- Write tests for the ranking engine; UI tests are optional in MVP

## Key Business Rules (from PRD)
- Elo updates must happen in < 200ms (real-time feel)
- Duplicate/near-duplicate suppression is NOT implemented in v1 (descoped;
  planned for v2 - see docs/PRD.md "Future Opportunities"). `cluster_id` and
  `quality_flags` on `photos` are unused columns; do not assume they're populated.
- Users can always override/pin/remove any ranking result
- Session state persists for 24-72 hours server-side
- Every edge function enforces per-endpoint request throttling and
  `batch-pre-register` enforces the session's `photo_count` cap; both are a
  Postgres-backed token bucket / atomic RPC, not Supabase's built-in Auth
  rate limits. See `backend/supabase/functions/_shared/rate-limit.ts` and
  `backend/supabase/migrations/20260731000001_abuse_protection.sql`.

## Never Do
- Never recommend permanent cloud storage of original photos
- Never add AI-generated aesthetic scoring (PRD explicitly excluded this)
- Never block the ranking UI waiting for full upload to complete
- Never commit .env files or API keys

## Workflow
- Default branch is `main` — all feature branches and PRs target `main`
- Branch per feature, PR for review
- Run `npm test` in backend/ before pushing ranking engine changes
- Use /clear between unrelated tasks to manage context

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
