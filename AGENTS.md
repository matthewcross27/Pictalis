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

## iOS build gotchas
- The Swift compiler's own fix-it on `'nonisolated(unsafe)' has no effect ... consider using 'nonisolated'`
  is wrong for `@Observable`-tracked mutable `var` properties (and for mutable stored properties in
  general, macro or not): `nonisolated` cannot apply to a mutable stored property, only to `let`s,
  computed properties, or functions. Applying it produces a hard compile error
  ("'nonisolated' cannot be applied to mutable stored properties"), not a silent fix. Verified against
  Xcode 26.6 / this project's toolchain. Leave `nonisolated(unsafe)` in place on these properties
  (e.g. `LocalCardProvider.fillTask`/`memoryWarningObserver`, `PhotoPipeline.backgroundTasks`) despite
  the warning.
- `TaskGroup.addTask { @MainActor in await self.foo() }` inside a `@MainActor`-isolated type can trip
  the region-based isolation checker ("this is an error in the Swift 6 language mode"). Dropping the
  explicit `@MainActor in` and just writing `group.addTask { await self.foo() }` resolves it — the
  `await` call to an actor-isolated method already performs the hop, so the extra annotation is both
  unnecessary and what confuses the checker.
- After adding a new Source file, `xcodegen generate` must be re-run before `xcodebuild` will see it
  (the generated `Pictalis.xcodeproj` is gitignored and rebuilt from `project.yml` + folder contents).
- `ios/Sources/App/SupabaseConfig.swift` is gitignored (holds the real project URL/anon key) and has
  no automated provisioning - a fresh checkout/worktree only has the placeholder template
  (`YOUR_PROJECT_REF`/`YOUR_ANON_KEY_HERE`). There's no env var, keychain, or xcconfig injection for
  it; running the app against a real backend requires manually filling in real values (never commit
  them). Anonymous sign-in errors surface as `AuthError` from `supabase-swift`, not `APIError`; see
  `ErrorPresentation.swift` for how both get mapped to user-facing text.
- `Package.resolved` currently pins `Sentry` to `9.24.0`, but `project.yml`'s `from: 8.0.0` only
  permits `<9.0.0`. Any `xcodegen generate` + fresh package resolution downgrades it to the latest
  8.x (`8.58.4` as of writing) and dirties `Package.resolved` in the diff - this is pre-existing
  drift, not something a given change caused. Don't fold an incidental revert/bump of this file into
  an unrelated commit; if it needs a real fix, either bump `project.yml`'s Sentry constraint to allow
  9.x or intentionally re-pin `Package.resolved` to 8.x in its own change.

## Supabase deploy pipeline
- `.github/workflows/migrations.yml` and `.github/workflows/edge-functions.yml` each have a `deploy`
  job (in addition to the existing `validate`/`test` job that runs on every push and PR). `deploy`
  only runs on push to `main`, only after its validation job passes, and is gated behind the
  `production` GitHub Environment - a run pauses for required-reviewer approval before
  `supabase db push` / `supabase functions deploy` touches the real project. PRs never deploy.
- Real deploys require three secrets on the `production` environment: `SUPABASE_ACCESS_TOKEN`,
  `SUPABASE_DB_PASSWORD`, `SUPABASE_PROJECT_REF`. The Supabase CLI reads the first two from env
  automatically (no explicit login/password flag needed); `SUPABASE_PROJECT_REF` is passed via
  `--project-ref`. `SUPABASE_SERVICE_ROLE_KEY` is not used in CI, and no user-facing edge function
  uses it - all of those rely on RLS + the caller's forwarded JWT. The one exception is the
  `cleanup-expired-sessions` admin function below, which by necessity bypasses RLS; don't follow its
  pattern for anything a normal client calls.

## Storage retention cleanup (pg_cron -> pg_net -> Edge Function)
- `cleanup_expired_sessions()` (`backend/supabase/migrations/20260517000001_storage_bucket.sql`,
  amended by `20260803000001_cleanup_via_storage_api.sql`) now only purges abandoned pending
  comparisons. Deleting expired sessions' storage objects and then the session rows themselves
  happens in the `cleanup-expired-sessions` Edge Function
  (`backend/supabase/functions/cleanup-expired-sessions/`), invoked hourly by a separate `pg_cron` +
  `pg_net.http_post` job. A raw SQL `DELETE FROM storage.objects` is rejected by the platform's
  `protect_delete()` trigger (not defined in this repo - it's a Supabase-managed guard); deletion
  must go through the Storage API, which is why this can't live in the SQL function.
- `pg_net.http_post` is fire-and-forget from Postgres's side (queued, executes post-commit, no
  synchronous response available to the calling SQL) - so the "delete storage, confirm it worked,
  then delete the DB rows" ordering is enforced inside the Edge Function itself, not by the cron
  job. If storage removal fails, the function returns an error without touching `sessions`, and the
  next hourly tick retries the same rows (the expiry query has no lower bound, and Storage `remove()`
  is a no-op for paths already gone).
- The cron job reads two Supabase Vault secrets that must be created by hand (dashboard SQL editor
  or Vault UI) after this ships - they are not, and must never be, embedded in a migration:
  `select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');` and
  `select vault.create_secret('<the project''s service_role key>', 'service_role_key');`. Until both
  exist, the cron job's HTTP calls fail (visible in `cron.job_run_details` / `net._http_response`,
  not as a migration failure). Verify a real run in `cron.job_run_details` (or storage usage
  dropping) after setting them - don't assume success from the migration alone.
- The Edge Function authorizes callers by comparing the request's `Authorization: Bearer` token to
  its own `SUPABASE_SERVICE_ROLE_KEY` env var (see `isAuthorizedCronCaller` in
  `backend/supabase/functions/_shared/cleanup-expired-sessions.ts`) - `verify_jwt = true` alone only
  proves *some* valid Supabase-signed JWT, not that the caller is the scheduled job, since any
  logged-in user's JWT would also pass it.
- `backend/supabase/config.toml` currently has no `[functions.*]` blocks, so there are no per-function
  `verify_jwt` overrides. The Supabase CLI's default (`verify_jwt = true` for every function) is what's
  deployed, which matches the RLS + forwarded-JWT model - don't add a `[functions.*]` override to
  disable JWT verification on any function without a specific reason.

## Ranking engine build gotchas
- `ranking-engine/jest.config.ts` is a TypeScript config file, so Jest requires `ts-node` to parse it.
  `ts-jest` used to pull `ts-node` in transitively; as of `ts-jest@29.4.x` it no longer does, so `ts-node`
  is now an explicit devDependency in `ranking-engine/package.json`. Don't drop it when bumping `ts-jest`
  or `jest` without first confirming `npm test` still runs.
- `typescript` is pinned to `~6.0.3` (tilde, not caret) in `ranking-engine/package.json`.
  `typescript-eslint@8.65.0`'s peer requirement caps compatible `typescript` at `<6.1.0`, so a caret range
  would let a routine `npm install` drift to `6.1.0+` and break `npm ci`/lint. Don't bump past `6.0.x`
  without first re-checking `typescript-eslint`'s peer range, and don't loosen the pin to a caret.
- As of `typescript@6.0.3`, `tsc` no longer implicitly type-checks against every package under
  `node_modules/@types` the way `5.9.x` did - `ranking-engine/tsconfig.json` sets
  `compilerOptions.types: ["jest", "node"]` explicitly to keep jest globals (`describe`, `it`, `expect`)
  and Node globals (`performance`, etc.) resolving in `src/__tests__/**`. If a future `@types/*` package
  is added and its globals silently stop resolving, add it to that `types` array rather than removing it.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
