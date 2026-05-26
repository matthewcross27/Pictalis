# Cull Pass Design

**Date:** 2026-05-25
**Status:** Approved

## Problem

Stage 1 ranking gives every non-suppressed photo at least 3 comparison slots regardless of whether it has any chance of reaching the top N. Users waste comparisons on obvious rejects that backend processing (blur detection, duplicate clustering) doesn't catch — photos that are technically valid but clearly not favorites.

## Solution

An optional, cluster-aware pre-screening pass that runs after backend processing completes and before any pairwise comparisons begin. Users make fast Keep/Drop decisions on one card at a time, reducing the photo pool before Elo ranking starts.

---

## Session Stage Flow

```
[processing complete] → choice screen → cull (optional) → dedup → ranking → complete
```

If the user chooses "Rank only", the session advances directly from processing to `dedup`, identical to the current behaviour.

---

## Choice Screen (`CullChoiceView`)

Shown immediately after processing completes, replacing the current direct-to-comparison navigation.

Two full-width cards:
- **Filter then rank** — subtitle: "Quickly drop photos that won't make the cut"
- **Rank only** — subtitle: "Jump straight into comparisons"

Tapping either calls `start-cull` and navigates accordingly.

---

## Cull Interaction (`CullView`)

Full-screen photo display. Interaction:

- **Swipe right** → Keep
- **Swipe left** → Drop
- **Keep / Drop buttons** at the bottom as visible affordances for users who prefer tapping

Dragging past a threshold commits the decision with a spring animation and loads the next card.

Top bar: progress indicator ("12 of 87 remaining") and a "Done — start comparing" button that advances the session to `ranking` without recording a decision for the current card (it stays in the pool).

If `cluster_size > 1`, a small badge reads "1 of 3 similar" so the user understands their drop affects the whole cluster.

When `next-cull` returns empty, the app navigates automatically to the comparison flow.

---

## Cluster-Aware Logic

Each card represents either:
- A **cluster representative** — the photo with the lowest blur score in a duplicate cluster
- A **singleton** — a photo with no cluster (or unique cluster)

Dropping a cluster representative suppresses all photos in that cluster. The user makes one decision per cluster, not per photo.

---

## Backend

### Migration

- Add `cull` to the `sessions_stage_check` constraint
- Add `cull_decision TEXT CHECK (cull_decision IN ('keep', 'drop'))` column to `photos` (default NULL)

### `start-cull` (new Edge Function)

Called after the user makes their choice screen selection.

- "Filter then rank" → `UPDATE sessions SET stage = 'cull'`
- "Rank only" → no-op; existing `next-pair` logic handles dedup detection as before (sessions default to `ranking` stage)

### `next-cull` (new Edge Function)

Returns the next unreviewed cluster representative.

```sql
SELECT DISTINCT ON (COALESCE(cluster_id, id::text))
  id, storage_path, cluster_id,
  COUNT(*) OVER (PARTITION BY cluster_id) AS cluster_size
FROM photos
WHERE session_id = $1
  AND is_suppressed = false
  AND cull_decision IS NULL
ORDER BY COALESCE(cluster_id, id::text), blur_score ASC
```

Response shape:
```json
{
  "photo_id": "uuid",
  "photo_url": "string",
  "cluster_id": "uuid | null",
  "cluster_size": 1,
  "cards_remaining": 42
}
```

When no rows remain, returns `{ "done": true }`. Stage advancement is handled by `submit-cull`, not here.

### `submit-cull` (new Edge Function)

Accepts `photo_id` and `decision` (`keep | drop`).

- `keep`: `UPDATE photos SET cull_decision = 'keep' WHERE id = $photo_id`
- `drop` with cluster: `UPDATE photos SET is_suppressed = true WHERE cluster_id = $cluster_id AND session_id = $session_id`
- `drop` singleton: `UPDATE photos SET is_suppressed = true WHERE id = $photo_id`

After each write, checks whether all representatives have a decision. If so, advances session stage to `ranking` (existing `next-pair` logic handles dedup detection from there).

---

## iOS

### New files
- `CullChoiceView.swift` — two-card choice screen
- `CullView.swift` — swipeable full-screen cull card

### Modified files
- Session coordinator / navigation: after processing completes, route to `CullChoiceView` instead of directly to the comparison screen

### Swipe gesture
Draggable card with spring animation. Threshold: ~40% of screen width. Visual indicator (green tint right, red tint left) appears as the user drags. Committing the gesture calls `submit-cull`, then `next-cull` to load the next card.

---

## Constraints

- Swipe gestures apply to `CullView` only — the existing comparison screen remains tap-only per PRD
- Dropped photos cannot be recovered within a session
- Original photos never leave the device (unchanged from existing architecture)
- `start-cull` must be called before any `next-cull` or `submit-cull` calls
