# Pictalis — Internal TestFlight MVP Roadmap

**Date:** 2026-05-29
**Goal:** Get a working, secure build into internal TestFlight for feedback-driven iteration.
**Timeline:** ~1 week of focused work

---

## Context

Pictalis is a SwiftUI iOS app for pairwise photo curation using Elo-style ranking. The core
flow (session setup → photo selection → pairwise comparison → cull pass → results/export) is
feature-complete. The `feat/cull-pass` branch is the last active feature branch; two files
remain uncommitted.

**Key decisions made:**
- Free app, no IAP
- Internal TestFlight only (up to 100 testers, no Beta App Review required)
- Processing worker (embeddings/dedup clustering) deferred to v1.1 — dedup stage will be
  skipped gracefully when no clusters exist rather than stalling
- No privacy policy or App Store screenshots required at this stage

---

## Phase 1: Finish the Branch (1–3 days)

Complete the two open files on `feat/cull-pass`:

- `backend/supabase/functions/start-cull/index.ts` — modified, not committed
- `ios/Sources/App/Views/CullChoiceView.swift` — modified, not committed

Add a dedup skip guard so `start-cull` / `next-cull` bypasses the dedup stage when no
cluster data exists, rather than stalling or producing confusing behavior.

Merge `feat/cull-pass` → `master` once complete.

---

## Phase 2: Integrity + Observability Audit (2–3 days)

### Security / integrity

**Supabase RLS policies:**
- Every table (sessions, photos, comparisons, cull_decisions) must enforce that users can
  only read/write rows belonging to their own `user_id`
- Verify policies cover all operations: SELECT, INSERT, UPDATE, DELETE
- Anonymous auth users must be properly isolated from each other

**Edge function authentication:**
- All 11 edge functions must validate the JWT from the `Authorization` header and reject
  unauthenticated requests with 401
- Verify no function is callable without a valid session token

**Storage bucket policies:**
- Compressed working copy bucket must be scoped so a user can only access their own objects
- Signed URLs must have a reasonable expiry (≤ 72 hours, matching the auto-delete policy)
- Verify no bucket allows public unauthenticated reads

**Data integrity:**
- Confirm only compressed working copies are uploaded — no original EXIF metadata or
  full-resolution data reaches the server
- Error messages and server logs must not emit user IDs, access tokens, or signed photo URLs
  in plain text

### Observability (minimum viable)

**Sentry iOS SDK:**
- Capture unhandled crashes and Swift errors
- No custom event tracking required at this stage — crash reports are sufficient to debug
  user-reported issues

**Sentry on edge functions:**
- Wire Sentry into the Supabase edge function runtime so backend panics and unhandled
  rejections appear in the same Sentry project as iOS crashes

---

## Phase 3: TestFlight Prerequisites (half a day)

The following are required to produce and upload a distribution build:

| Item | Status | Action |
|------|--------|--------|
| `NSPhotoLibraryUsageDescription` | ✅ Present in Info.plist + project.yml | None |
| `NSPhotoLibraryAddUsageDescription` | ✅ Present in Info.plist + project.yml | None |
| App icon (1024×1024) | ❌ No `.xcassets` found | Create AppIcon asset catalog |
| `DEVELOPMENT_TEAM` in project.yml | ❌ Empty string | Set Apple Developer team ID |
| `SupabaseConfig.swift` | ❌ Only `.example` committed | Populate locally with prod credentials |
| New edge functions deployed to prod | ❌ `start-cull`, `next-cull`, `submit-cull`, `finish-cull` | Deploy via Supabase CLI |

---

## Phase 4: Archive + Distribute (1 hour)

1. Run `xcodegen generate` in `ios/`
2. Archive in Xcode (Product → Archive)
3. Upload to App Store Connect via Xcode Organizer
4. Add internal testers in App Store Connect
5. Distribute build

---

## Post-TestFlight Backlog

Driven by what surfaces in Sentry and user feedback — not pre-scheduled:

- **Onboarding / first-run experience** — no empty state exists for cold-start users
- **Session resume UX** — backend supports 24–72hr persistence but there is no UI to resume
  an in-progress session
- **Error state polish** — network failures currently surface raw error strings
- **Processing worker** — embeddings + dedup clustering (v1.1), skipped for MVP
- **Privacy policy** — required before external TestFlight or App Store submission

---

## Out of Scope for This Roadmap

- App Store submission (screenshots, description, review notes)
- External TestFlight / Beta App Review
- Monetization / IAP
- Android, desktop, or web
- Video ranking, collaborative ranking, social features
