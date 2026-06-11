# CI Workflows Design

**Date:** 2026-06-10
**Status:** Approved

## Goal

Automated testing for every component of the repo on push/PR to `main`, staying
within the GitHub Actions free tier for a private repo (2,000 min/month, macOS
billed at 10x).

## Structure

One workflow per component, each path-filtered so a change to one component
never spends minutes on the others. Every workflow has `permissions: contents:
read` and a concurrency group that cancels stale runs on force-push.

| Workflow | Runner | Paths | Checks |
|---|---|---|---|
| `ranking-engine.yml` | ubuntu | `ranking-engine/**` | `tsc --noEmit`, jest |
| `worker.yml` | ubuntu | `worker/**` | ruff, black `--check`, mypy (strict), pytest — via uv |
| `edge-functions.yml` | ubuntu | `backend/supabase/functions/**` | `deno fmt --check`, `deno lint`, `deno check` per entry point, `deno test` |
| `migrations.yml` | ubuntu | `backend/supabase/migrations/**` | `supabase db start` applies all migrations to a fresh Postgres |
| `ios.yml` | macos-15 | `ios/**` | xcodegen + `xcodebuild test` on iPhone simulator, SPM cached |
| `secret-scan.yml` | ubuntu | all pushes/PRs | gitleaks full-history scan |

These replace the previous single `ci.yml`.

## Decisions

- **iOS runs full build + tests** (user choice: best free option). Path
  filtering plus SPM caching keeps macOS minutes bounded; the job only runs
  when `ios/**` changes. The gitignored `SupabaseConfig.swift` is stubbed from
  the committed `.example` file — placeholders compile and unit tests are
  offline.
- **Simulator picked dynamically** by UDID from `simctl list`, so runner image
  updates that rename iPhone models don't break the job.
- **Deno fmt/lint config** lives in `backend/supabase/functions/deno.json`:
  `singleQuote: true`, `lineWidth: 100` (matches codebase style), and lint
  excludes `no-import-prefix` because Supabase edge functions use inline
  `npm:`/`jsr:` specifiers by design.
- **Each workflow includes its own file in `paths`** so editing a workflow
  exercises it.
- **Branch protection caveat:** path-filtered workflows skip entirely when
  their paths don't change, and skipped workflows report no check. If these
  are ever made *required* checks, add no-op fallback workflows with the same
  names.

## Verification performed before landing

All CI commands were run locally and pass: ranking-engine (9 jest tests +
typecheck), worker (pytest, ruff, black, mypy after recreating the stale
venv), edge functions (fmt, lint, 14 entry-point type-checks, 48 deno tests),
iOS (11 XCTest cases on simulator), gitleaks (130 commits, no leaks),
actionlint on all six workflows.

Landing this required two code fixes, both test-verified:

1. `deno fmt` applied once across the edge functions (mechanical reformat)
   plus removal of two unused test imports, so fmt/lint checks start green.
2. `ImageCompressor.scale` rendered with the device screen scale (2x/3x),
   so "1920px" output was actually up to 5760px. Fixed by forcing
   `UIGraphicsImageRendererFormat` scale to 1. Both previously-failing
   compressor tests now pass.
