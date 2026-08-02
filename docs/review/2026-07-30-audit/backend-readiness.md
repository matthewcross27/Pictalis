# Pictalis Backend/Infra Launch Readiness — Report

Scope owned: `backend/`, `worker/`, `ranking-engine/`, `supabase/`, CI. iOS Swift quality and App Store Connect metadata/compliance are separate tasks.

## What I did

- `origin/wip/observable-migration-and-review-docs` (PR #14) was already merged to `origin/main` at commit `82997e4` before I started (merged 2026-07-30T04:03:27Z). The worktree HEAD was already at that commit, so I worked directly from it — no checkout needed. Confirmed via `gh pr view 14 --json state,mergedAt,baseRefName,headRefName`.
- Read every edge function under `backend/supabase/functions/` (15 functions + `_shared/`), all 16 migrations, both `config.toml` files, `docs/review/MASTER-REVIEW.md`, `docs/app-store/privacy-policy.md`.
- Ran the real test suites: `deno test --allow-env _shared/` (installed Deno 2.9.4 locally), `deno fmt --check .`, `deno lint .`, `deno check` on all 15 entry points, `npm test` in `ranking-engine/`, `npm audit`.
- Checked GitHub Actions status for all 6 workflows via `gh api .../actions/workflows` and PR #14's status checks.
- Grepped `backend/`, `worker/`, `ranking-engine/`, `supabase/` for hardcoded secrets/keys/tokens.

`uv`/Python were not available in this environment to run `worker/`'s pytest locally, but `worker/` has no real implementation (see below), so this doesn't materially affect the assessment — I confirmed via the Worker workflow's last recorded run (green) and by reading the (trivial) test content directly.

---

## Blocking / risky for launch

### 1. Duplicate/blur detection ("Stage 1 dedup") appears to be dead code — not wired to any request path
CLAUDE.md states "Duplicate suppression only in Stage 1" as a business rule, and the PRD describes a Python worker doing embeddings/duplicate clustering/blur detection. In this codebase:
- `backend/supabase/functions/_shared/phash.ts` implements `computeDHash` and `computeBlurScore` correctly (tests pass), but `computeDHash`/`computeBlurScore` are **never called from any edge function** — `grep -rln "computeDHash\|computeBlurScore" backend/supabase/functions` matches only `phash.ts` and `phash.test.ts` themselves.
- `photos.cluster_id` (used by ranking/pair-selection to suppress duplicates, e.g. `backend/supabase/functions/_shared/pair-selection.ts`, `next-pair/index.ts`, `results/index.ts`) is **read in several places but never written anywhere** in `backend/`, `worker/`, or `ios/Sources` — `grep -rn "cluster_id\s*="` over `backend/supabase` returns nothing.
- `photos.quality_flags` (blur flags) is likewise only read (`results/index.ts`) and never written.
- `worker/` — the component the PRD assigns this job to — is an unimplemented stub: `worker/src/worker/__init__.py` is empty, and `worker/tests/test_placeholder.py` just asserts the package imports. `git log` shows `worker/src/` hasn't been touched since the initial scaffold commit (`75d6552`, "bootstrap monorepo scaffold").

**Net effect:** the duplicate-suppression feature that CLAUDE.md and the PRD claim exists does not appear to run anywhere end-to-end. If this is actually expected to work for launch, it needs to be built; if it was intentionally descoped, the docs/business rules should say so instead of claiming Stage 1 dedup is implemented.

### 2. No application-level rate limiting or abuse protection on any business endpoint
None of the 15 edge functions implement throttling — `grep -rn "rate.?limit\|throttle\|429"` over `backend/supabase/functions` (excluding `node_modules`) returns nothing. `backend/supabase/config.toml`'s `[auth.rate_limit]` block only covers Supabase Auth operations (anonymous sign-in creation: 30/hr/IP, token refresh, sign-in/sign-up) — it does **not** cover `create-session`, `register-photo`, `batch-pre-register`, `submit-comparison`, etc. Since anonymous sign-ins are enabled (`enable_anonymous_sign_ins = true` in the real backend config) and no CAPTCHA is configured (`[auth.captcha]` commented out), an already-authenticated (anonymous) caller can hit any business endpoint an unlimited number of times.
- Concretely: `backend/supabase/functions/batch-pre-register/index.ts:58-85` accepts up to 300 `photo_ids` per call (bounded by `_shared/batch-pre-register.ts:5`, `z.array(...).min(1).max(300)`), but nothing stops calling it repeatedly with fresh UUIDs to accumulate an unbounded number of `photos` rows per session — there's no check against the session's declared `photo_count` (validated only at `create-session` time, `create-session/index.ts:13`, capped 2-300).
- This is a real storage/DB cost and abuse exposure once the API is public. Recommend at minimum: enforce total-photos-per-session ≤ declared `photo_count` in `batch-pre-register`/`register-photo`, and add per-user/IP request throttling (Supabase doesn't provide this out of the box for Edge Functions; needs an explicit solution — e.g., a Postgres-backed token bucket, or a proxy/WAF in front of the functions).

### 3. No evidence of a real production Supabase project, and no CI/CD deploy pipeline
- `backend/supabase/config.toml` and the stray top-level `supabase/config.toml` are both **local CLI dev config only** — ports, `127.0.0.1` URLs, no project ref. Neither file, nor anything else in the repo, names an actual `<ref>.supabase.co` project.
- `gh secret list --repo matthewcross27/Pictalis` returns **empty** — no repo secrets are configured at all, and none of the 6 GitHub Actions workflows reference any (`grep -rn "secrets\." .github/workflows/*.yml` only shows `secrets.GITHUB_TOKEN` in the gitleaks scan).
- None of the workflows (`migrations.yml`, `edge-functions.yml`) actually deploy anything — `migrations.yml` only runs `supabase db start` (ephemeral local DB) to validate migrations apply cleanly; `edge-functions.yml` only lints/typechecks/tests. There is no `supabase db push`, `supabase functions deploy`, or equivalent anywhere in the repo.
- **Conclusion:** deployment to whatever Supabase project actually backs the shipped app is entirely manual and undocumented in this repo. I cannot confirm from the repo whether that project is a genuine production-tier project or a personal/dev project someone deploys to by hand — there's simply no infra-as-code or CI evidence either way. This needs to be answered directly (ask whoever runs `supabase link`/`supabase db push` today) before launch, and a repeatable deploy process (even a manual runbook, ideally an authenticated CI job) should exist so migrations and function updates aren't applied ad hoc against production.

### 4. Two divergent, stray Supabase config directories in the repo
- `supabase/config.toml` (top-level) has `project_id = "picHelper"`, `enable_anonymous_sign_ins = false`.
- `backend/supabase/config.toml` (the one actually used — CI's `migrations.yml` runs from `backend/`) has `project_id = "backend"`, `enable_anonymous_sign_ins = true`.
- `git log` shows the top-level one was committed 2026-05-29 (`408aebf`, "feat: cull pass end-to-end") and never touched since — it looks like a leftover from running `supabase init` in the wrong directory early on. It's dead but committed, and its differing `enable_anonymous_sign_ins` value could mislead someone into thinking anonymous auth is off. Recommend deleting `supabase/config.toml` and `supabase/.gitignore` from the repo.

### 5. worker/ and ranking-engine/ are both orphaned, not part of the running system
- `ranking-engine/src/elo.ts` is a **separate, drifted duplicate** of `backend/supabase/functions/_shared/elo.ts` (different function signatures, extra `initialRating()`/`DEFAULT_RATING` not present in the real one) — confirmed via `diff`. Nothing imports `ranking-engine` from `backend/`, `worker/`, or `ios/` (`grep -rln "ranking-engine" backend worker ios` → empty). It has its own `package.json`, its own Jest suite (9 tests, all pass), but it is not the ranking engine actually running in production — that's `backend/supabase/functions/_shared/{elo,ranking-logic,pair-selection}.ts` (tested separately via Deno, 57 tests, all pass).
- Both `worker/src/` and `ranking-engine/src/` haven't been touched since the initial scaffold commit (`75d6552`). Their CI workflows (`worker.yml`, `ranking-engine.yml`) are green, but that's because there's nothing to fail — they're testing placeholder/orphaned code, not production logic.
- Recommend either deleting both (if the architecture has genuinely moved to "everything in Deno edge functions") or actually wiring them in — right now they're maintenance burden and a source of confusion (e.g. someone "fixing a bug in the ranking engine" in `ranking-engine/elo.ts` would fix nothing in production).

---

## Solid — already in good shape

### Security / auth / RLS
- **MASTER-REVIEW.md item #1 (hardcoded Supabase anon key) is fixed.** `ios/Sources/App/SupabaseConfig.swift` does not exist in the repo or anywhere in git history (`git log --all --oneline -- '**/SupabaseConfig.swift'` → empty); only `SupabaseConfig.swift.example` (placeholders) is committed. The real file is explicitly gitignored at `.gitignore:38` (`ios/Sources/App/SupabaseConfig.swift`).
- No other hardcoded secrets found. Grepped `backend/`, `worker/`, `ranking-engine/`, `supabase/` for JWT-shaped strings, `sk_live`/`sk_test`, `service_role`, generic `secret=`/`password=`/`token=` literals, and committed `.env*` files — all clean. A `secret-scan.yml` GitHub Actions workflow (gitleaks) runs on every push/PR and is green.
- **All 15 edge functions use the anon key + forward the caller's `Authorization` header** to `createClient()` (never the service-role key — `grep -rn "SERVICE_ROLE"` over `backend/supabase/functions` is empty), so every DB query runs under the caller's own Postgres role with RLS enforced. This is the correct pattern.
- **RLS is real, not just assumed.** `sessions`, `photos`, `comparisons` all have `ENABLE ROW LEVEL SECURITY` (`backend/supabase/migrations/20260516000000_init.sql:49-51`) with `FOR ALL TO authenticated USING (user_id = auth.uid())`-style policies (`20260517000002_rls_policies.sql`), scoped through session ownership for `photos`/`comparisons`. Storage bucket policies (`20260517000001_storage_bucket.sql`, hardened in `20260517000004_storage_hardening.sql`) restrict upload/read/delete to the caller's own UID-prefixed folder, with a NULL-guard fix already applied for root-path uploads.
- Only 3 of 15 functions call `auth.getUser()` explicitly (`create-session`, `register-photo`, `batch-pre-register`) — I initially flagged this as a gap, but on inspection it's intentional and safe: the other 12 rely on RLS as the authorization boundary (e.g. `submit-comparison/index.ts:60-65` explicitly comments "RLS ensures this comparison belongs to the caller's session"), and the one place that does mutation via RPC (`submit_comparison_atomic`, `backend/supabase/migrations/20260517000003_atomic_submit_comparison.sql`) is `SECURITY INVOKER`, so RLS stays active even inside the function — it can't be used to cross session boundaries even if called directly via PostgREST RPC, not just through the edge function.

### Data retention
- Matches `docs/app-store/privacy-policy.md`'s claim ("automatically deleted within 72 hours" / "deleted within 72 hours of session creation"). `sessions.expires_at` defaults to `NOW() + INTERVAL '72 hours'` at creation (`20260516000000_init.sql:5`), and `public.cleanup_expired_sessions()` (hardened in `20260517000004_storage_hardening.sql`) deletes storage objects + session rows (photos/comparisons cascade via `ON DELETE CASCADE`) past `expires_at`, scheduled hourly via `pg_cron`: `SELECT cron.schedule('cleanup-expired-sessions', '0 * * * *', ...)`.
- Minor nuance worth knowing (not a mismatch, but a rounding edge): because cleanup runs hourly rather than continuously, a session could in the worst case still exist for up to ~1 hour past the stated 72-hour mark before actual deletion. Not worth flagging in the privacy policy copy (that's the App Store Connect task's call), but worth knowing operationally.
- The same hardened cleanup function also purges abandoned pending comparisons after 24 hours, which isn't mentioned in the privacy policy but isn't a user-facing retention claim either.

### Monitoring
- Backend **does** have equivalent error monitoring to iOS's Sentry integration. `backend/supabase/functions/_shared/sentry.ts` initializes `@sentry/deno` from a `SENTRY_DSN` env var, and **all 15 edge functions** call `Sentry.captureException(err)` + `await Sentry.flush(2000)` in their catch blocks (verified via grep — 15/15 have both `initSentry` and `Sentry.captureException`). A production incident in an edge function would not go unnoticed, provided `SENTRY_DSN` is actually set as a secret on the deployed project — I can't verify that from the repo (see point #3 above: no CI/CD, so this would be set manually via `supabase secrets set`), and I have no visibility into whether Sentry alert rules/notifications are configured on the dashboard side.
- `worker/` has no Sentry/monitoring wiring, but since `worker/` doesn't do anything (see point #1/#5), this isn't currently a gap in practice — it would need to be added if/when `worker/` is actually implemented.

### CI status
All 6 GitHub Actions workflows are currently green — no failing runs found:

| Workflow | Latest run | Branch | Conclusion |
|---|---|---|---|
| iOS | 2026-07-30 | main | success |
| Secret Scan | 2026-07-30 | main | success |
| Edge Functions | 2026-06-23 | fix/audit-fixes-june-2026 (last run touching this path) | success |
| Database Migrations | 2026-06-23 | fix/audit-fixes-june-2026 | success |
| Ranking Engine | 2026-06-18 | main | success |
| Worker | 2026-06-18 | main | success |

(Edge Functions/Database Migrations/Ranking Engine/Worker didn't re-run on PR #14 because that PR only touched iOS + docs files and those workflows are path-filtered — not a failure, just not applicable.) PR #14's own status checks (`gh pr view 14 --json statusCheckRollup`): Gitleaks ×2 SUCCESS, "Build & Test (iPhone Simulator)" SUCCESS, "Supabase Preview" SKIPPED.

### Test suites
- **Deno (`backend/supabase/functions/`)**: installed Deno 2.9.4 and ran the exact CI steps locally — `deno fmt --check .` (28 files clean), `deno lint .` (27 files clean), `deno check` on all 15 `index.ts` entry points (all pass), `deno test --allow-env _shared/` — **57/57 tests pass**, covering pair-selection, phash, photo-registration validation, ranking-logic, and elo update math.
- **ranking-engine**: `npm test` (Jest) — **9/9 pass**. `npm audit` shows 3 vulnerabilities (1 low, 2 high: `brace-expansion`, `js-yaml`, `@babel/core`) but these are all transitive dev/test-tooling dependencies, not runtime code shipped anywhere — low priority, and moot if `ranking-engine/` is deleted per point #5.
- **worker**: could not run `uv sync`/`pytest` locally (no working Python 3.11/`uv` in this environment), but the only test present is `tests/test_placeholder.py::test_worker_package_importable`, which trivially imports an empty package. CI's Worker workflow is green. There is no real code to have a security opinion on — see point #1.

---

## Recommendation summary

**Before a real App Store launch**, in priority order:
1. Decide and document whether Stage-1 duplicate/blur suppression is in scope for launch. If yes, it needs to actually be implemented and wired up (nothing currently sets `cluster_id`/`quality_flags`). If no, update CLAUDE.md/PRD to stop claiming it exists, since a future engineer will otherwise trust `docs/review/MASTER-REVIEW.md`-style audits that don't check this.
2. Add basic abuse protection: per-session photo count enforcement in `batch-pre-register`/`register-photo`, and some form of per-user/IP rate limiting on the business endpoints (not just Supabase Auth's built-in limits).
3. Confirm (outside this repo, with whoever has Supabase dashboard access) that the deployed project is a genuine production-tier Supabase project, that `SENTRY_DSN` is actually set as a function secret there, and that Sentry alerting is configured — none of this is verifiable from the repo. Stand up at least a documented manual deploy runbook, ideally an authenticated CI deploy step, so `main` and what's actually running aren't only connected by someone remembering to run `supabase db push`.
4. Clean up dead weight: delete the stray top-level `supabase/config.toml`+`.gitignore`, and either delete or genuinely integrate `worker/` and `ranking-engine/` — both are currently orphaned scaffolds that could mislead someone into editing the wrong copy of the ranking logic.

Everything else checked (RLS enforcement, secret hygiene, the fixed hardcoded-key issue, retention-vs-privacy-policy match, edge function error monitoring, CI health, and the actual production ranking/edge-function test suites) is in solid shape and not a blocker.
