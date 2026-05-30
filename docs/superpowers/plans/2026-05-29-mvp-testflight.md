# Pictalis Internal TestFlight MVP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working, secure internal TestFlight build with Sentry crash reporting wired up, starting from the in-progress `feat/cull-pass` branch.

**Architecture:** Four sequential phases — finish and merge the cull-pass feature branch, audit and fix security/integrity gaps, add minimum observability (Sentry), then prepare and upload the TestFlight build.

**Tech Stack:** SwiftUI (iOS 17+), Supabase Edge Functions (Deno/TypeScript), XcodeGen, Sentry Cocoa SDK, @sentry/deno

---

## File Map

### Phase 1 — Finish the branch
- Modify: `backend/supabase/functions/start-cull/index.ts` — commit existing uncommitted change
- Modify: `ios/Sources/App/Views/CullChoiceView.swift` — commit existing uncommitted change
- Modify: `backend/supabase/functions/next-cull/index.ts` — advance session to 'ranking' when done=true

### Phase 2 — Integrity + Observability
- Verify (no change needed): `backend/supabase/migrations/20260517000002_rls_policies.sql`
- Verify (no change needed): `backend/supabase/migrations/20260517000004_storage_hardening.sql`
- Create: `backend/supabase/migrations/20260529000001_rls_cull_decisions_audit.sql` — confirm RLS covers cull_decision column; no-op migration that documents the audit
- Create: `backend/supabase/functions/_shared/sentry.ts` — shared Sentry init for edge functions
- Modify: `backend/supabase/functions/next-cull/index.ts` — import Sentry, wrap handler
- Modify: `backend/supabase/functions/next-pair/index.ts` — import Sentry, wrap handler
- Modify: `backend/supabase/functions/submit-comparison/index.ts` — import Sentry, wrap handler
- Modify: `backend/supabase/functions/submit-cull/index.ts` — import Sentry, wrap handler
- Modify: `backend/supabase/functions/start-cull/index.ts` — import Sentry, wrap handler
- Modify: `backend/supabase/functions/finish-cull/index.ts` — import Sentry, wrap handler
- Modify: `backend/supabase/functions/create-session/index.ts` — import Sentry, wrap handler
- Modify: `backend/supabase/functions/register-photo/index.ts` — import Sentry, wrap handler
- Modify: `backend/supabase/functions/results/index.ts` — import Sentry, wrap handler
- Modify: `backend/supabase/functions/session-status/index.ts` — import Sentry, wrap handler
- Modify: `backend/supabase/functions/remove-photo/index.ts` — import Sentry, wrap handler
- Modify: `ios/Sources/App/picHelperApp.swift` — init Sentry before first render
- Modify: `ios/project.yml` — add Sentry Cocoa SPM dependency

### Phase 3 — TestFlight Prerequisites
- Create: `ios/Sources/Assets.xcassets/Contents.json`
- Create: `ios/Sources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Place (user action): `ios/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
- Modify: `ios/project.yml` — add ASSETCATALOG_COMPILER_APPICON_NAME setting

---

## Task 1: Commit the two open files on feat/cull-pass

**Context:** Two files are modified in the working tree but not committed. The changes are complete and correct — `start-cull` fixes a stage guard, `CullChoiceView` fixes a progress bar calculation.

**Files:**
- Modify (commit existing change): `backend/supabase/functions/start-cull/index.ts`
- Modify (commit existing change): `ios/Sources/App/Views/CullChoiceView.swift`

- [ ] **Step 1: Verify you're on the right branch**

```bash
git branch --show-current
```
Expected: `feat/cull-pass`

- [ ] **Step 2: Review the pending diff**

```bash
git diff backend/supabase/functions/start-cull/index.ts ios/Sources/App/Views/CullChoiceView.swift
```
Expected: Two small diffs — `start-cull` changes `.not('stage', 'in', ...)` to `.not('stage', 'eq', 'complete')` and updates the 409 error message; `CullChoiceView` replaces `uploadService.progress` with an explicit `completed / total` calculation.

- [ ] **Step 3: Stage and commit**

```bash
git add backend/supabase/functions/start-cull/index.ts ios/Sources/App/Views/CullChoiceView.swift
git commit -m "fix(cull): stage guard and upload progress calculation"
```
Expected: 1 commit created on `feat/cull-pass`.

---

## Task 2: Fix next-cull to advance session stage when returning done=true

**Context:** When no photos have a non-null `cluster_id` (which is always the case until the Python worker runs), `next-cull` returns `{ done: true }` immediately. `CullView.fetchNext()` then calls `onComplete()` without calling `finish-cull`. This leaves the session in `stage = 'cull'` in the database. `next-pair` is stage-aware and can behave unexpectedly when stage isn't 'ranking' or 'dedup'. Fix: advance stage to 'ranking' inside `next-cull` when returning done.

**Files:**
- Modify: `backend/supabase/functions/next-cull/index.ts:60-64`

- [ ] **Step 1: Open `backend/supabase/functions/next-cull/index.ts` and find the early-return block**

The block currently reads (around line 60):
```typescript
if (!photos || photos.length === 0) {
  return new Response(JSON.stringify({ done: true }), {
    status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
```

- [ ] **Step 2: Replace with stage-advancing version**

```typescript
if (!photos || photos.length === 0) {
  await supabase.from('sessions').update({ stage: 'ranking' }).eq('id', session_id);
  return new Response(JSON.stringify({ done: true }), {
    status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
```

- [ ] **Step 3: Commit**

```bash
git add backend/supabase/functions/next-cull/index.ts
git commit -m "fix(next-cull): advance session to ranking when no clusters exist"
```

---

## Task 3: Open PR and merge feat/cull-pass into master

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/cull-pass
```

- [ ] **Step 2: Open a PR**

```bash
gh pr create --title "feat: cull pass end-to-end" --body "$(cat <<'EOF'
## Summary
- Completes the three-stage cull flow: choose mode → keep/drop cards → transition to ranking
- Fixes start-cull stage guard (allow cull from any non-complete stage)
- Fixes CullChoiceView upload progress bar calculation
- Fixes next-cull: advances session stage to 'ranking' when no clusters exist, preventing stage drift

## Test plan
- [ ] Tap "Filter then rank" → cull cards appear; swipe/tap keep and drop; reaching the end transitions to comparison
- [ ] Tap "Done — start comparing" from cull screen → transitions directly to comparison
- [ ] Tap "Rank only" → skips cull, goes straight to comparison
- [ ] With no photos having cluster_id set, "Filter then rank" immediately advances to comparison (dedup skip)
EOF
)"
```

- [ ] **Step 3: Merge the PR**

```bash
gh pr merge --squash --delete-branch
```

- [ ] **Step 4: Pull master locally**

```bash
git checkout master && git pull
```

---

## Task 4: Integrity audit — RLS and data isolation

**Context:** Verify that every table has row-level security that isolates users from each other's data. The `cull_decision` column lives on `photos` (not a separate table) and is thus covered by the existing photos policy. This task documents the audit findings and writes a no-op migration as a paper trail.

**Files:**
- Read: `backend/supabase/migrations/20260517000002_rls_policies.sql`
- Read: `backend/supabase/migrations/20260516000000_init.sql`
- Create: `backend/supabase/migrations/20260529000001_rls_cull_decisions_audit.sql`

- [ ] **Step 1: Verify RLS is enabled on all tables**

Read `20260516000000_init.sql`. Confirm these three lines are present at the bottom:
```sql
ALTER TABLE sessions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE photos      ENABLE ROW LEVEL SECURITY;
ALTER TABLE comparisons ENABLE ROW LEVEL SECURITY;
```
Expected: all three present. ✅

- [ ] **Step 2: Verify policy coverage for sessions, photos, comparisons**

Read `20260517000002_rls_policies.sql`. Confirm:
- `sessions`: `FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid())` ✅
- `photos`: `FOR ALL TO authenticated USING (session_id IN (SELECT id FROM sessions WHERE user_id = auth.uid()))` ✅
- `comparisons`: same pattern as photos ✅

Note: `FOR ALL` covers SELECT, INSERT, UPDATE, DELETE — no operation is unguarded.

Note: Supabase anonymous auth creates rows in `auth.users` and issues a JWT with `role = authenticated`, so `TO authenticated` includes anonymous users. No separate anonymous policy is needed.

- [ ] **Step 3: Verify cull_decision column is covered**

The `cull_decision` column was added to `photos` in `20260525000002_cull_stage.sql`. Since RLS on `photos` uses `FOR ALL`, the existing policy covers reads and writes to this column without any additional migration.

- [ ] **Step 4: Write the audit trail migration**

Create `backend/supabase/migrations/20260529000001_rls_cull_decisions_audit.sql`:

```sql
-- Integrity audit 2026-05-29: cull_decision column RLS coverage
--
-- cull_decision is a column on public.photos (added in 20260525000002_cull_stage.sql).
-- It is covered by the "Users own photos in their sessions" policy defined in
-- 20260517000002_rls_policies.sql, which uses FOR ALL — no additional policy needed.
--
-- Verified:
--   sessions    — RLS enabled, FOR ALL policy, user_id = auth.uid()
--   photos      — RLS enabled, FOR ALL policy, scoped via session ownership
--   comparisons — RLS enabled, FOR ALL policy, scoped via session ownership
--   storage     — policies in 20260517000004_storage_hardening.sql, user-scoped by folder
--
-- No schema changes in this migration.
SELECT 1;
```

- [ ] **Step 5: Commit**

```bash
git add backend/supabase/migrations/20260529000001_rls_cull_decisions_audit.sql
git commit -m "chore(db): RLS audit trail migration for cull_decision column"
```

---

## Task 5: Integrity audit — edge function authentication

**Context:** All 11 edge functions must reject requests without a valid `Authorization` header. Verify each one, then document.

**Files:**
- Read: all `backend/supabase/functions/*/index.ts`

- [ ] **Step 1: Grep for auth checks across all functions**

```bash
for f in backend/supabase/functions/*/index.ts; do
  name=$(basename $(dirname $f))
  count=$(grep -c "Missing Authorization\|status: 401" $f 2>/dev/null || echo 0)
  echo "$name: $count"
done
```
Expected output — every function shows `2` or more:
```
create-session: 2
finish-cull: 2
next-cull: 2
next-pair: 2
register-photo: 2
remove-photo: 2
results: 2
session-status: 2
start-cull: 2
submit-comparison: 2
submit-cull: 2
```
If any function shows `0`, open it and add the standard auth guard (see pattern below) before the JSON body parsing.

- [ ] **Step 2: Confirm the pattern in one representative function**

Open `backend/supabase/functions/create-session/index.ts`. Confirm the top of `Deno.serve` reads:
```typescript
const authHeader = req.headers.get('Authorization');
if (!authHeader) {
  return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
    status: 401, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}
```
And confirm the `createClient` call passes `authHeader` as `Authorization`:
```typescript
const supabase = createClient(
  Deno.env.get('SUPABASE_URL') ?? '',
  Deno.env.get('SUPABASE_ANON_KEY') ?? '',
  { global: { headers: { Authorization: authHeader } } },
);
```
This pattern means every DB query runs as the authenticated user, and Postgres RLS enforces data isolation automatically. ✅

- [ ] **Step 3: No code changes expected — commit a note if all pass**

If all 11 functions pass, no commit is needed. If you had to fix any function, commit:
```bash
git add backend/supabase/functions/<fixed-function>/index.ts
git commit -m "fix(<function>): add missing auth header validation"
```

---

## Task 6: Integrity audit — storage and data leakage

**Context:** Verify the storage bucket is not publicly readable, signed URLs have appropriate expiry, and iOS never uploads original EXIF metadata.

**Files:**
- Read: `backend/supabase/migrations/20260517000001_storage_bucket.sql`
- Read: `backend/supabase/migrations/20260517000004_storage_hardening.sql`
- Read: `ios/Sources/App/Services/ImageCompressor.swift`

- [ ] **Step 1: Confirm the working-copies bucket is private**

Read `20260517000001_storage_bucket.sql`. Confirm it creates the bucket with `public = false`:
```sql
INSERT INTO storage.buckets (id, name, public, ...)
VALUES ('working-copies', 'working-copies', false, ...);
```
If `public = true`, change it to `false` and add a migration:
```sql
UPDATE storage.buckets SET public = false WHERE id = 'working-copies';
```

- [ ] **Step 2: Verify storage policies are user-scoped**

Read `20260517000004_storage_hardening.sql`. Confirm the three policies (`INSERT`, `SELECT`, `DELETE`) all check:
```sql
(storage.foldername(name))[1] = auth.uid()::text
```
This ensures users can only access objects stored under their own user ID folder. ✅

- [ ] **Step 3: Verify signed URL expiry is appropriate**

Run:
```bash
grep -n "createSignedUrl" backend/supabase/functions/*/index.ts
```
Expected: all non-internal calls use `3600` (1 hour). The `register-photo` internal fetch uses `60` (1 minute — appropriate for an immediate server-side fetch). Signed URLs for user-facing photo display expire in 1 hour, which is shorter than the 72-hour session window but acceptable: the app fetches a fresh URL for each comparison screen. No changes needed. ✅

- [ ] **Step 4: Verify ImageCompressor strips EXIF**

Read `ios/Sources/App/Services/ImageCompressor.swift`. Trace the data flow:

1. `fetchData(from:)` calls `requestImageDataAndOrientation` — returns raw image data **with** EXIF
2. `UIImage(data: imageData)` creates a UIImage — EXIF is in the image metadata
3. `scale(_:maxDimension:)` calls `UIGraphicsBeginImageContextWithOptions` and `draw(in:)` — this renders pixels into a new context, **stripping all metadata**
4. `jpegData(compressionQuality:)` on the resulting image produces a clean JPEG with **no EXIF**

Edge case: if the image is smaller than 1920px on both sides, `scale()` returns the original `UIImage` without redrawing. In that case, step 4 (`jpegData`) is called directly on `UIImage(data: imageData)`. `UIImage.jpegData()` does **not** preserve EXIF from the source data — it only encodes pixel data. EXIF is stripped in this path too. ✅

No code changes needed. Confirm by reading the function and verifying the above trace matches what you see.

- [ ] **Step 5: Verify no sensitive data in error responses**

Run:
```bash
grep -rn "user_id\|access_token\|signedUrl\|storage_path" backend/supabase/functions/*/index.ts | grep "error\|console.log\|console.error"
```
Expected: no results. Error responses should only contain `{ error: "<message>" }` with generic strings, not user IDs or storage paths. If any are found, replace the sensitive field with a generic message and commit.

- [ ] **Step 6: Commit if any fixes were made**

```bash
git add -p
git commit -m "fix(backend): remove sensitive data from error responses"
```
If nothing needed fixing, no commit needed.

---

## Task 7: Wire Sentry iOS SDK

**Context:** Add the Sentry Cocoa SDK via Swift Package Manager. Initialize it at app startup so crashes and unhandled errors are automatically captured. No custom event tracking — crash reports only.

Before starting: create a Sentry account at sentry.io, create a project of type "Apple - iOS", and copy the DSN (looks like `https://abc123@o123.ingest.sentry.io/456`).

**Files:**
- Modify: `ios/project.yml`
- Modify: `ios/Sources/App/picHelperApp.swift`

- [ ] **Step 1: Add Sentry to project.yml packages**

Open `ios/project.yml`. In the `packages:` section, add:
```yaml
packages:
  Supabase:
    url: https://github.com/supabase/supabase-swift
    from: 2.0.0
  Sentry:
    url: https://github.com/getsentry/sentry-cocoa
    from: 8.0.0
```

- [ ] **Step 2: Add Sentry as a target dependency**

In the `targets.Pictalis.dependencies:` list, add:
```yaml
    dependencies:
      - package: Supabase
        product: Supabase
      - package: Sentry
        product: Sentry
```

- [ ] **Step 3: Add Sentry init to PictalisApp**

Open `ios/Sources/App/picHelperApp.swift`. Add `import Sentry` at the top alongside the existing imports.

In `init()`, add Sentry initialization as the **first** line before `configureNavigationBar()`:
```swift
init() {
    SentrySDK.start { options in
        options.dsn = "YOUR_SENTRY_DSN_HERE"
        options.debug = false
        options.tracesSampleRate = 0
    }

    let client = SupabaseClient(
        supabaseURL: SupabaseConfig.url,
        supabaseKey: SupabaseConfig.anonKey
    )
    // ... rest of init unchanged
```

Replace `"YOUR_SENTRY_DSN_HERE"` with your actual DSN from the Sentry dashboard.

- [ ] **Step 4: Regenerate the Xcode project**

```bash
cd ios && xcodegen generate
```
Expected: `Generated: Pictalis.xcodeproj` with no errors. SPM packages will resolve on first Xcode open.

- [ ] **Step 5: Verify the project builds**

```bash
cd ios && xcodebuild -scheme Pictalis -destination "generic/platform=iOS" build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add ios/project.yml ios/Sources/App/picHelperApp.swift
git commit -m "feat(ios): wire Sentry crash reporting"
```

---

## Task 8: Wire Sentry on Supabase edge functions

**Context:** Add Sentry to all 11 edge functions using a shared init module. This gives one Sentry project where both iOS crashes and backend errors surface. Use `@sentry/deno` from npm.

Before starting: in the Sentry project you created for iOS, go to Settings → Client Keys (DSN). You can use the same DSN or create a separate backend Sentry project. A single project is simpler.

**Files:**
- Create: `backend/supabase/functions/_shared/sentry.ts`
- Modify: all 11 `backend/supabase/functions/*/index.ts`

- [ ] **Step 1: Create the shared Sentry module**

Create `backend/supabase/functions/_shared/sentry.ts`:
```typescript
import * as Sentry from "npm:@sentry/deno@8";

export function initSentry(): void {
  const dsn = Deno.env.get("SENTRY_DSN");
  if (!dsn) return;
  Sentry.init({ dsn, tracesSampleRate: 0 });
}

export { Sentry };
```

- [ ] **Step 2: Add Sentry to each edge function**

For each of the 11 functions, make two changes:

**At the top of the file**, after the existing imports, add:
```typescript
import { initSentry, Sentry } from "../_shared/sentry.ts";
initSentry();
```

**Wrap the Deno.serve handler** to capture unhandled rejections. Replace:
```typescript
Deno.serve(async (req) => {
  // ...handler body...
});
```
With:
```typescript
Deno.serve(async (req) => {
  try {
    // ...handler body (move entire existing body here)...
  } catch (err) {
    Sentry.captureException(err);
    await Sentry.flush(2000);
    return new Response(JSON.stringify({ error: "Internal server error" }), {
      status: 500, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
```

Repeat for all 11 functions: `create-session`, `finish-cull`, `next-cull`, `next-pair`, `register-photo`, `remove-photo`, `results`, `session-status`, `start-cull`, `submit-comparison`, `submit-cull`.

- [ ] **Step 3: Add SENTRY_DSN as an edge function secret**

```bash
cd backend
supabase secrets set SENTRY_DSN=https://YOUR_KEY@oXXX.ingest.sentry.io/YOUR_PROJECT_ID
```
Replace the DSN with your actual value.

Expected:
```
Finished supabase secrets set
```

- [ ] **Step 4: Verify the shared module is importable locally**

```bash
cd backend
supabase functions serve next-cull --env-file .env.local 2>&1 | head -10
```
Expected: function starts without import errors. (Ctrl-C to stop.)

- [ ] **Step 5: Commit**

```bash
git add backend/supabase/functions/
git commit -m "feat(backend): wire Sentry on all edge functions"
```

---

## Task 9: Create app icon asset catalog

**Context:** No `.xcassets` exists in the project. Xcode and App Store Connect both require at least a 1024×1024 app icon. XcodeGen auto-discovers `.xcassets` under the `sources` path (`ios/Sources/`).

This task sets up the asset catalog structure. You must supply the actual 1024×1024 PNG image file yourself.

**Files:**
- Create: `ios/Sources/Assets.xcassets/Contents.json`
- Create: `ios/Sources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Place (manual): `ios/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
- Modify: `ios/project.yml`

- [ ] **Step 1: Create the asset catalog root**

Create `ios/Sources/Assets.xcassets/Contents.json`:
```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 2: Create the AppIcon set**

Create `ios/Sources/Assets.xcassets/AppIcon.appiconset/Contents.json`:
```json
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 3: Place your icon image**

Copy or export your 1024×1024 PNG to:
```
ios/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```
Requirements: exactly 1024×1024 pixels, RGB PNG, no alpha channel, no transparency.

If you don't have a final icon yet, create a placeholder with any image tool and replace it before the App Store submission.

- [ ] **Step 4: Add ASSETCATALOG_COMPILER_APPICON_NAME to project.yml**

In `ios/project.yml`, under `targets.Pictalis.settings.base`, add:
```yaml
    settings:
      base:
        SWIFT_VERSION: "5.9"
        DEVELOPMENT_TEAM: ""
        SWIFT_STRICT_CONCURRENCY: complete
        ENABLE_USER_SCRIPT_SANDBOXING: YES
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

- [ ] **Step 5: Regenerate and verify the build includes the icon**

```bash
cd ios && xcodegen generate
xcodebuild -scheme Pictalis -destination "generic/platform=iOS" build 2>&1 | grep -i "icon\|error" | head -20
```
Expected: `** BUILD SUCCEEDED **` with no asset catalog errors.

- [ ] **Step 6: Commit**

```bash
git add ios/Sources/Assets.xcassets/ ios/project.yml
git commit -m "feat(ios): add app icon asset catalog"
```

---

## Task 10: Set DEVELOPMENT_TEAM in project.yml

**Context:** `DEVELOPMENT_TEAM` is currently an empty string. It must be set to your Apple Developer Team ID to sign a distribution build for TestFlight.

**Files:**
- Modify: `ios/project.yml`

- [ ] **Step 1: Find your Team ID**

Log into developer.apple.com → Account. Your Team ID is a 10-character string like `AB12CD34EF`. It also appears in Xcode under Preferences → Accounts → your Apple ID → team details.

- [ ] **Step 2: Update project.yml**

In `ios/project.yml`, replace:
```yaml
        DEVELOPMENT_TEAM: ""
```
With:
```yaml
        DEVELOPMENT_TEAM: "YOUR_TEAM_ID"
```

- [ ] **Step 3: Regenerate**

```bash
cd ios && xcodegen generate
```

- [ ] **Step 4: Commit**

```bash
git add ios/project.yml
git commit -m "chore(ios): set DEVELOPMENT_TEAM for distribution signing"
```

---

## Task 11 (Manual): Pre-flight checklist before archiving

These steps require manual action in the Supabase dashboard and your local environment. They cannot be scripted.

**Files:**
- Create locally (do not commit): `ios/Sources/App/SupabaseConfig.swift`

- [ ] **Step 1: Enable anonymous sign-ins in the Supabase production project**

In the Supabase dashboard for your production project:
- Go to Authentication → Configuration → Sign In / Up
- Enable "Allow anonymous sign-ins"
- Save

Without this, `AuthService.signInAnonymously()` will fail and the app won't function.

- [ ] **Step 2: Populate SupabaseConfig.swift locally**

Copy the example file and fill in your production values:
```bash
cp ios/Sources/App/SupabaseConfig.swift.example ios/Sources/App/SupabaseConfig.swift
```

Edit `ios/Sources/App/SupabaseConfig.swift` and replace the placeholders:
```swift
enum SupabaseConfig {
    static let url = URL(string: "https://YOUR_PROJECT_REF.supabase.co")!
    static let anonKey = "YOUR_ANON_KEY_HERE"
}
```
Find these values in Supabase Dashboard → Project Settings → API.

**Do not commit this file.** Verify `.gitignore` includes `SupabaseConfig.swift`.

- [ ] **Step 3: Verify SupabaseConfig.swift is gitignored**

```bash
git check-ignore -v ios/Sources/App/SupabaseConfig.swift
```
Expected: the file path is listed as ignored. If not, add it:
```bash
echo "ios/Sources/App/SupabaseConfig.swift" >> .gitignore
git add .gitignore && git commit -m "chore: gitignore SupabaseConfig.swift"
```

- [ ] **Step 4: Deploy the new edge functions to production**

```bash
cd backend
supabase functions deploy start-cull --project-ref YOUR_PROJECT_REF
supabase functions deploy next-cull --project-ref YOUR_PROJECT_REF
supabase functions deploy submit-cull --project-ref YOUR_PROJECT_REF
supabase functions deploy finish-cull --project-ref YOUR_PROJECT_REF
```

Replace `YOUR_PROJECT_REF` with your project reference from the Supabase dashboard URL (e.g., `abcdefghijklmnop`).

Expected for each:
```
Deployed Function start-cull on project YOUR_PROJECT_REF
```

Also apply the new migration to production:
```bash
supabase db push --project-ref YOUR_PROJECT_REF
```
Expected: `Applying migration 20260529000001_rls_cull_decisions_audit.sql ... done`

- [ ] **Step 5: Set the SENTRY_DSN secret in the production project**

```bash
supabase secrets set SENTRY_DSN=https://YOUR_KEY@oXXX.ingest.sentry.io/YOUR_PROJECT_ID --project-ref YOUR_PROJECT_REF
```

---

## Task 12 (Manual): Archive and distribute to internal TestFlight

These steps are done in Xcode and App Store Connect. An active Apple Developer Program membership ($99/year) is required.

- [ ] **Step 1: Open the project in Xcode**

```bash
cd ios && xcodegen generate && open Pictalis.xcodeproj
```

- [ ] **Step 2: Set the run destination to "Any iOS Device (arm64)"**

In the Xcode toolbar, click the device selector and choose **Any iOS Device (arm64)**. You cannot archive for a simulator.

- [ ] **Step 3: Bump the build number**

In Xcode: select the Pictalis target → General → Identity. Increment `Build` (e.g., from `1` to `2`). Version can stay `1.0`.

Alternatively in project.yml, update `CFBundleVersion` and regenerate.

- [ ] **Step 4: Archive**

Menu: **Product → Archive**

Xcode builds a release archive. This takes 1-3 minutes. The Organizer window opens automatically when done.

- [ ] **Step 5: Upload to App Store Connect**

In the Organizer:
1. Select your archive
2. Click **Distribute App**
3. Choose **App Store Connect**
4. Choose **Upload**
5. Leave all options at defaults (automatic signing, include symbols)
6. Click **Upload**

This takes 2-5 minutes. You'll see "Upload Successful."

- [ ] **Step 6: Add internal testers in App Store Connect**

1. Open appstoreconnect.apple.com
2. Go to your app → TestFlight → Internal Testing
3. Click the **+** to create a new internal group or use the default "App Store Connect Users" group
4. Add testers by their Apple ID (must be a member of your Developer team)
5. Select your build once it finishes processing (5-15 minutes after upload)
6. Testers receive an email invite — they install via the TestFlight app

---

## Self-Review Checklist

After completing all tasks, verify:
- [ ] `feat/cull-pass` is merged into `master`
- [ ] `next-cull` advances stage to 'ranking' when no clusters exist
- [ ] All 11 edge functions have the Sentry try/catch wrapper
- [ ] Sentry iOS SDK initializes before any UI in `PictalisApp.init()`
- [ ] App icon is a valid 1024×1024 PNG in the asset catalog
- [ ] `DEVELOPMENT_TEAM` is set in `project.yml`
- [ ] `SupabaseConfig.swift` is populated locally and gitignored
- [ ] Anonymous sign-ins are enabled in the production Supabase project
- [ ] New edge functions are deployed to production
- [ ] `SENTRY_DSN` secret is set in the production project
- [ ] Build archives and uploads successfully
- [ ] At least one internal tester has received a TestFlight invite
