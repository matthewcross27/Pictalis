# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`picHelper` is a new project with no code yet. Update this file once the project structure and tooling are established.

# Photo Ranking & Curation App — Claude Code Constitution

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
- All new Supabase tables require a migration file in backend/migrations/
- Write tests for the ranking engine; UI tests are optional in MVP

## Key Business Rules (from PRD)
- Elo updates must happen in < 200ms (real-time feel)
- Duplicate suppression only in Stage 1 — alternates remain accessible
- Users can always override/pin/remove any ranking result
- Session state persists for 24–72 hours server-side

## Never Do
- Never recommend permanent cloud storage of original photos
- Never add AI-generated aesthetic scoring (PRD explicitly excluded this)
- Never block the ranking UI waiting for full upload to complete
- Never commit .env files or API keys

## Workflow
- Branch per feature, PR for review
- Run `npm test` in backend/ before pushing ranking engine changes
- Use /clear between unrelated tasks to manage context