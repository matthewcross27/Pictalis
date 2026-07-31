# docs/review/

This directory holds code review and audit records for Pictalis.

`implementation-plan.md` (the checklist tracking action items from
`MASTER-REVIEW.md`) has been removed: it turned out to be unreliable - it
never flagged App Store screenshots or code signing as incomplete, even
though both still are as of 2026-07-30. It is superseded by the audit
reports in [`2026-07-30-audit/`](./2026-07-30-audit/), which verified
findings directly against the repository rather than trusting an
unmaintained checklist:

- [`backend-readiness.md`](./2026-07-30-audit/backend-readiness.md) - backend/infra launch readiness (edge functions, migrations, CI, security)
- [`appstore-compliance.md`](./2026-07-30-audit/appstore-compliance.md) - App Store submission compliance (signing, screenshots, privacy manifest, accessibility)
- [`ios-code-review.md`](./2026-07-30-audit/ios-code-review.md) - iOS code quality/correctness re-audit against `MASTER-REVIEW.md`'s 31 findings

`MASTER-REVIEW.md`, `core-review.md`, `services-review.md`, `views-review.md`,
and `needs-review.md` are untouched and remain the original review records
these audits verified against.
