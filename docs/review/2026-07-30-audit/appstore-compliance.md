# Pictalis — App Store Submission Compliance Audit

**Scope:** Compliance / metadata / submission-process only. Swift code quality and backend/infra internals are covered by parallel tasks; this report only touches those areas where they visibly affect a submission claim (e.g. does the backend actually enforce the retention window the privacy policy promises).

**Date of audit:** 2026-07-30

## 0. Branch note (read this first)

The brief said to `git checkout origin/wip/observable-migration-and-review-docs` because the default branch was allegedly stale. That branch ref does not exist on `origin`. Investigation showed why: its work has already been squash-merged into `origin/main` as two PRs —

- `d6a5a90` — "feat(release): App Store review readiness — privacy manifest, metadata, a11y, icon fix (#13)" (2026-06-23)
- `82997e4` — "iOS Observation framework migration + code review docs (#14)" (2026-07-29)

The worktree's detached HEAD was already sitting at `82997e4` = `origin/main` HEAD. So the "stale default branch" premise was wrong at audit time; I audited current `main`, which is the most up-to-date state and a superset of the named branch's intended content. Everything below reflects `main` as of `82997e4`.

There is a second, unrelated, unmerged branch `origin/gnhf/find-ways-to-improve-a39ef0` (branched from `d6a5a90`, before the Observation migration) doing backend micro-optimizations. It independently added its own copy of `ios/Sources/PrivacyInfo.xcprivacy`. **Diffed both copies — they are byte-for-byte identical (56 lines each).** No merge conflict, no duplicate-declaration risk when that branch is eventually merged.

---

## 1. Go / No-Go Summary

**No-Go.** One hard blocker prevents even producing a submittable build; two more prevent a *complete* submission. Everything else checked out clean or was already fixed.

| # | Item | Status | Blocking? |
|---|------|--------|-----------|
| 1 | Signing (`DEVELOPMENT_TEAM`) | **Not set** — empty string in `ios/project.yml` | **Yes — cannot archive/upload at all** |
| 2 | App Store screenshots | **Not captured** — only a README with instructions, zero PNGs | **Yes — App Store Connect requires at least one screenshot set to submit for review** |
| 3 | VoiceOver hint duplication | **Partially fixed** — 2 of the app's ~5 views still have the bug | No (not an automatic rejection, but a real accessibility defect Apple reviewers are trained to notice) |
| 4 | Privacy manifest (`PrivacyInfo.xcprivacy`) | Present, valid, matches actual API/data usage | Done |
| 5 | Info.plist usage strings, version/build, bundle ID, deployment target | All present and correct | Done |
| 6 | App icon (1024×1024, no alpha) | Correct | Done |
| 7 | Privacy policy retention claim vs. backend reality | Verified accurate and enforced | Done |
| 8 | Privacy policy / support pages live | Both return HTTP 200 with matching content | Done |
| 9 | Export compliance | No custom encryption; standard HTTPS only — trivial "exempt" answer | Done (needs one ASC form answer, no code change) |
| 10 | Age rating | 4+ is correct; no user-generated content, no social features | Done |
| 11 | Monetization / StoreKit | App is genuinely free; metadata claim matches code | Done |
| 12 | Anonymous-auth review notes | Present and accurate | Done |

---

## 2. Item-by-item detail

### 2.1 Info.plist / project config (task item 1)

`ios/Pictalis/Info.plist`:
- `NSPhotoLibraryUsageDescription`: "Pictalis needs access to your photos to help you curate your favorites." — present, human-readable, matches the string the review-notes.md smoke-test checklist expects verbatim.
- `NSPhotoLibraryAddUsageDescription`: "Pictalis saves your favorite photos back to your library." — present (needed because the app writes ranked photos back via `PHPhotoLibrary`).
- `CFBundleShortVersionString`: `1.0`, `CFBundleVersion`: `1` — present directly in the committed Info.plist.
- Bundle ID: `com.matthewcross.Pictalis` (via `PRODUCT_BUNDLE_IDENTIFIER` + `bundleIdPrefix: com.matthewcross` in `ios/project.yml`).
- Deployment target: iOS 17.0 (`ios/project.yml:5`).

**Discrepancy worth flagging (non-blocking):** the readiness plan (Task 5, Step 2) instructed adding `CFBundleShortVersionString`/`CFBundleVersion` to `project.yml`'s `info.properties` block. That never happened — `ios/project.yml` has no such keys (`ios/project.yml:22-35`). The version numbers only exist because they were written directly into the checked-in `Info.plist`. Since `xcodegen generate` merges `properties` on top of an existing plist rather than wiping it, this doesn't break today — but it's a latent trap: anyone who adds other `info.properties` entries later without also re-adding the version keys, or who deletes/regenerates `Info.plist` from scratch, will silently lose the version stamp. Recommend moving the two version keys into `project.yml` properly so `xcodegen` is the single source of truth.

**Real blocker:** `ios/project.yml:39` — `DEVELOPMENT_TEAM: ""`. This was Task 5 in the readiness plan and was never done. Confirmed by reading the file directly, not by trusting the checklist. Without a team ID, `Product → Archive` cannot produce a signed archive, so nothing can be uploaded to App Store Connect no matter how complete everything else is. This is a one-person, minutes-long fix (paste the Apple Developer Team ID) but it is currently blocking and should be called out as the #1 action item.

### 2.2 `PrivacyInfo.xcprivacy` (task item 2)

`ios/Sources/PrivacyInfo.xcprivacy` exists (56 lines) and is well-formed plist XML. Declares:
- `NSPrivacyTracking: false`, no tracking domains — correct, app does no cross-app tracking or ad attribution.
- Collected data types: `PhotosorVideos` (not linked to identity, not used for tracking, purpose = App Functionality) and `CrashData` (same). This matches actual behavior:
  - Photos: only the user-selected photos are touched; `AuthService.swift:26` uses `client.auth.signInAnonymously()` — there is no identity to link photo data to.
  - Crash data: `ios/Sources/App/PictalisApp.swift:12-15` — `SentrySDK.start { options.dsn = ...; options.debug = false; options.tracesSampleRate = 0 }`. Minimal init, no `sendDefaultPii`, no extra scopes/breadcrumbs configured beyond Sentry's defaults — consistent with "crash data only, not linked, not tracked."
- Required-reason API declarations: `NSPrivacyAccessedAPICategoryFileTimestamp` (reason `C617.1`) and `NSPrivacyAccessedAPICategoryDiskSpace` (reason `E174.1`). These map to the app's actual `FileManager` usage in the local-first upload pipeline (temp JPEG materialization, disk-space checks before upload) — plausible and appropriately scoped reason codes, not over- or under-declared.

**Cross-branch check (explicitly requested):** `origin/gnhf/find-ways-to-improve-a39ef0` independently added its own `ios/Sources/PrivacyInfo.xcprivacy`. Diffed against main's copy — **identical, 0 lines of diff.** No conflict or duplicate-declaration risk on eventual merge.

### 2.3 App icon (task item 3)

`ios/Sources/Assets.xcassets/AppIcon.appiconset/`: single `AppIcon-1024.png`, `Contents.json` declares it as `idiom: universal, size: 1024x1024` — this is Xcode 14+'s "single size" App Icon format; Xcode derives all other required sizes from this one asset at build time, so a multi-size asset catalog is not required here. Verified with `sips`: 1024×1024, RGB, **no alpha channel** (Apple rejects icons with alpha). This was Task 7 Step 2 in the readiness plan and is confirmed done — the commit `d6a5a90` message even notes "flatten app icon alpha channel."

### 2.4 Privacy policy accuracy vs. backend (task item 4)

`docs/app-store/privacy-policy.md` and `docs/app-store/review-notes.md` both claim compressed photo copies and session data are "automatically deleted within 72 hours." A parallel research pass (not backend-internals review, just checking this specific claim) confirmed this is **actually enforced**, not aspirational:

- `backend/supabase/migrations/20260516000000_init.sql:5` — `sessions.expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '72 hours'`
- `backend/supabase/migrations/20260517000001_storage_bucket.sql:41-59` — `cleanup_expired_sessions()` deletes expired sessions' `storage.objects` in the `working-copies` bucket, then deletes the `sessions` rows (cascades to `photos`/`comparisons`)
- `backend/supabase/migrations/20260517000001_storage_bucket.sql:1-2,62,72-76` — `pg_cron` scheduled hourly: `cron.schedule('cleanup-expired-sessions', '0 * * * *', 'SELECT public.cleanup_expired_sessions()')`, function locked to postgres-only via `REVOKE ALL ... FROM PUBLIC`
- `backend/supabase/migrations/20260517000004_storage_hardening.sql:1-28` — supersedes with `CREATE OR REPLACE`, additionally purges orphaned pending comparisons after 24h, same 72h session/storage window

Policy text and implementation agree. No flag here.

**Publication check:** both `https://pictalis.app/privacy/` and `https://pictalis.app/support/` return HTTP 200 (verified via `curl`, GitHub Pages-hosted), and the served content matches the repo's markdown (`<title>Privacy Policy — Pictalis</title>`, "Last updated: June 22, 2026", "72 hours" both present). The readiness plan flagged this as a manual follow-up step that "must be completed by the developer" — it has been. Good; this is one fewer blocker than the plan's own checklist would suggest if read literally without verifying live.

### 2.5 Export compliance (task item 5)

`ios/Sources/App/Services/APIClient.swift` uses plain `URLSession.shared.data(for:)` throughout (14 call sites) — no certificate pinning, no `CryptoKit`/`swift-crypto` usage anywhere in `ios/Sources` (grepped, zero hits), no `ITSAppUsesNonExemptEncryption` key set in `Info.plist` or `project.yml`. The only network dependency is the Supabase Swift SDK, which itself uses standard HTTPS/TLS. This qualifies for Apple's standard TLS exemption — at upload, the "Does your app use encryption?" question should be answered as exempt (standard HTTPS only). No code change needed; this is purely a form answer in App Store Connect / Xcode Organizer at upload time. Not currently documented in `review-notes.md`, but it's a one-click answer, not a blocker.

### 2.6 Accessibility & age rating (task item 6)

**Age rating:** 4+ is correct. No user-generated content visible to others, no social/sharing features, no objectionable content categories apply. `docs/app-store/metadata-en-US.md` and `review-notes.md` both state this consistently.

**VoiceOver / MASTER-REVIEW item #10 — NOT fully resolved.** `docs/review/MASTER-REVIEW.md` item #10 and `docs/review/implementation-plan.md` batch 5a flagged that `accessibilityHint` strings across the app began with "Double-tap to …", which VoiceOver reads twice (VoiceOver already announces "double tap to activate" before speaking the hint). Commit `82997e4` (2026-07-29, after the original readiness commit) fixed this in the four files the review listed:

- `ios/Sources/App/Views/CullView.swift:180,221,232` — fixed ("Expand this photo", "Remove this photo from ranking", "Add this photo to the ranking round")
- `ios/Sources/App/Views/ComparisonView.swift:171,186` — fixed, and the RTL-unsafe "Left photo"/"Right photo" labels (batch 5b) were also correctly changed to "First photo"/"Second photo" (`ComparisonView.swift:170`)
- `ios/Sources/App/Views/CompletionView.swift:71,92,97,104` — fixed
- `ios/Sources/App/Views/ResultsView.swift:77,140,149` — fixed

But **`ios/Sources/App/Views/SessionSetupView.swift:73` and `:99` still say**:
```
73:     .accessibilityHint("Double-tap to open your photo library and select photos to curate")
99:     .accessibilityHint("Double-tap to begin curating your selected photos")
```
This view wasn't in MASTER-REVIEW's original 10-site list (it was scoped to the other four view files), so the July cleanup pass never touched it — it's a residual instance of the exact same defect, on the very first screen a VoiceOver user hits. Two-line fix (`Edit` to drop the "Double-tap to " prefix, matching the style of every other view), but it is currently un-fixed on `main`.

This is not, by itself, an automatic Apple rejection — but degraded/duplicated VoiceOver output on the entry screen is exactly the kind of accessibility rough edge App Review has been increasingly willing to bounce apps for, and it's inconsistent with the app's own stated accessibility bar in `PRODUCT.md` ("basic VoiceOver labels on interactive elements"). Recommend fixing before submission since the pattern is already established elsewhere in the codebase.

### 2.7 Monetization (task item 7)

`PRODUCT.md` describes no paywall or subscription — Pictalis is positioned as a one-time-use curation tool with no monetization language at all. `docs/app-store/metadata-en-US.md` states "No subscription required" and lists pricing as free in the review-notes checklist. Confirmed by grep across `ios/`, `backend/`, `docs/` for StoreKit/IAP/subscription/paywall/purchase: the only hit is the metadata doc's own prose claim — zero StoreKit imports, product IDs, purchase flow, or paywall UI exist in `ios/Sources`. Metadata and code agree; nothing to reconcile.

### 2.8 Screenshots — the second hard blocker (task item 8 / readiness plan Task 4)

`docs/app-store/screenshots/` contains **only `README.md`** with capture instructions (`xcrun simctl io booted screenshot ...` commands) — zero actual PNG files. The commit that touched this directory (`d6a5a90`) added the instructions file, not the screenshots themselves ("docs: add App Store screenshots directory with capture instructions" per its own commit message). App Store Connect requires at least one screenshot set uploaded before an app can be submitted for review — this is a hard submission blocker, not just a nice-to-have. Someone needs to actually boot the iPhone 16 Pro Max (or 15 Pro Max) simulator, run the five capture commands already documented in the README, and upload the results.

### 2.9 `docs/review/implementation-plan.md` checklist status (task item 8, out-of-lane items summarized only)

This document (generated 2026-06-28, after the readiness commit but before the Observation-migration commit) is a Swift code-quality checklist, not an App Store checklist — it's the other task's lane. Spot-checked for completion since explicitly requested:

- **Batch 1 (secrets):** appears done — the real `SupabaseConfig.swift` no longer exists in the repo; only `SupabaseConfig.swift.example` is tracked (config presumably injected via a gitignored real file / build setting).
- **Batch 2 (force-unwrap crashes) / Batch 3 (session-dir deletion bug) / Batch 4 (deprecated `cornerRadius`) / Batch 6 (`@Observable` migration):** all show as resolved by grep (no `ObservableObject`/`@Published` remnants in `Services/*.swift`, no `.cornerRadius(` call sites left, `PhotoPipeline.swift` only removes the session subdirectory now, not the parent).
- **Batch 5 (accessibility):** done except the `SessionSetupView.swift` gap detailed in §2.6 above.
- **Batch 7 (type safety):** partially done — `PairPhoto`/`RankedPhoto` gained `Equatable` (7c), but `createdAt`/`expiresAt`/`signedUrl`/`photoUrl` are still `String` rather than `Date`/`URL` (7a/7b not done). Not an App Store compliance issue.
- Batches 8–9 (cleanup, concurrency hygiene) not spot-checked — genuinely out of scope for this audit and owned by the Swift-quality task.

None of batch 7–9's remaining gaps affect submission readiness.

---

## 3. Recommendation — what's actually blocking submission right now

1. **Set `DEVELOPMENT_TEAM` in `ios/project.yml:39`** (currently `""`) to a real Apple Developer Team ID, run `xcodegen generate`, and confirm an archive build succeeds. Nothing can be uploaded without this.
2. **Capture and commit the 5 App Store screenshots** using the commands already written in `docs/app-store/screenshots/README.md`. Apple will not accept a submission with zero screenshots.
3. **Fix the two remaining "Double-tap to…" VoiceOver hints in `SessionSetupView.swift:73,99`** to match the fix already applied everywhere else in the app. Low effort, closes out MASTER-REVIEW item #10 completely rather than leaving one view behind.

Everything else audited — privacy manifest accuracy, Info.plist strings, icon format, privacy-policy-vs-backend accuracy, live policy/support pages, export-compliance posture, age rating, and the free/no-paywall claim — is genuinely done and matches reality, not just claimed done in a checklist. The readiness plan's own checklist should not be trusted at face value without verification: it lists screenshots and signing as steps without marking them incomplete, and this audit found both still outstanding by reading the actual files rather than the checklist's checkboxes.

No code changes were made during this audit; it is read-only. Given finding #3 is a trivial, unambiguous two-line fix that matches an already-established pattern in four other files, it may be worth promoting for someone to just ship rather than re-auditing later.
