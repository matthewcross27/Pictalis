---
name: Pictalis
description: Find the photos you'll actually come back to.
colors:
  film-white: "oklch(97% 0.008 65)"
  grain-paper: "oklch(93% 0.010 65)"
  ink: "oklch(17% 0.010 65)"
  secondary-text: "oklch(52% 0.008 65)"
  divider: "oklch(85% 0.008 65)"
  amber: "oklch(57% 0.125 62)"
  amber-dim: "oklch(57% 0.060 62)"
  photo-overlay: "oklch(10% 0 0 / 55%)"
typography:
  display:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "clamp(2rem, 8vw, 3.5rem)"
    fontWeight: 600
    lineHeight: 1.0
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "22px"
    fontWeight: 600
    lineHeight: 1.15
  title:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "17px"
    fontWeight: 500
    lineHeight: 1.25
  body:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.55
  label:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "14px"
    fontWeight: 500
    lineHeight: 1.3
    letterSpacing: "0.01em"
  caption:
    fontFamily: "Fraunces, Georgia, serif"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.3
    letterSpacing: "0.02em"
rounded:
  photo: "4px"
  interactive: "8px"
  pill: "100px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "16px"
  lg: "24px"
  xl: "32px"
components:
  button-primary:
    backgroundColor: "{colors.amber}"
    textColor: "{colors.film-white}"
    rounded: "{rounded.interactive}"
    padding: "14px 20px"
    typography: "{typography.label}"
  button-primary-disabled:
    backgroundColor: "{colors.divider}"
    textColor: "{colors.secondary-text}"
    rounded: "{rounded.interactive}"
    padding: "14px 20px"
  button-primary-hover:
    backgroundColor: "oklch(52% 0.125 62)"
    textColor: "{colors.film-white}"
    rounded: "{rounded.interactive}"
    padding: "14px 20px"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.secondary-text}"
    rounded: "{rounded.interactive}"
    padding: "10px 16px"
  photo-cell-comparison:
    backgroundColor: "{colors.grain-paper}"
    rounded: "{rounded.photo}"
  photo-overlay-button:
    backgroundColor: "{colors.photo-overlay}"
    rounded: "{rounded.pill}"
    padding: "8px"
  status-badge-complete:
    backgroundColor: "oklch(55% 0.12 145 / 15%)"
    textColor: "oklch(35% 0.09 145)"
    rounded: "{rounded.pill}"
    padding: "4px 10px"
  status-badge-active:
    backgroundColor: "oklch(60% 0.11 65 / 15%)"
    textColor: "oklch(45% 0.09 65)"
    rounded: "{rounded.pill}"
    padding: "4px 10px"
---

# Design System: Pictalis

## 1. Overview

**Creative North Star: "The Moth and the Light"**

Pictalis is the quiet room where a batch of 200 photos gets edited down to the twelve you'll actually keep. The interface should feel like sitting under a single lamp with a stack of prints and a marker — warm, private, unhurried in spirit but quick in motion. Everything that isn't a photo exists to move you toward the next choice. Decoration is forbidden; the grain is in the palette.

The brand draws from *Pyralis pictalis*, a moth known for its warm ochre and amber coloration. Just as a moth navigates toward light, the app helps users navigate through digital noise toward the glowing moments worth preserving. The palette echoes this: dusty ambers, soft ochres, aged cream, and velvety grays — organic, warm, and emphatically not technological.

The type is Fraunces throughout — a variable-weight optical serif with organic warmth that resists the cold precision of the default iOS san-serif. At display sizes it feels editorial, like a photo zine. At label sizes it has just enough character to remind you this isn't a file manager. Motion is fast but not mechanical: pairs arrive at 120ms ease-out, giving a sense of momentum rather than instant teleportation. A session should feel like forward motion, not checklist processing.

This system explicitly rejects: the cream-and-purple gradient of generic SaaS apps; the file-manager neutrality of Google Photos and Apple Photos; the cheap gamification of swipe-and-decide UI; heavy chrome that competes with the photos being judged.

**Key Characteristics:**
- Warm off-white base — aged paper, not clinical white
- Single accent color (amber) used sparingly; photos supply all other color
- Fraunces at every text size — weight contrast replaces typeface switching
- Photos presented as near-frameless prints (4px radius, maximum surface area)
- Motion snappy at 120ms, never mechanical; screen transitions at 220ms

## 2. Colors: The Film Grain Palette

A warm neutral field with one earthy accent. Photos supply all the color that matters — the chrome steps aside.

### Primary
- **Amber** (`oklch(57% 0.125 62)`): The single interaction color. Warm golden ochre, derived from the coloration of *Pyralis pictalis*. Used on the primary CTA button, active taps, and links. Appears on ≤10% of any given screen. Its rarity signals that something can be done.

### Neutral
- **Film White** (`oklch(97% 0.008 65)`): App background. Not pure white — tinted faintly warm toward amber so photos don't appear to float on clinical white. All screens use this as the base.
- **Grain Paper** (`oklch(93% 0.010 65)`): Surface color for photo cell backgrounds, loading placeholders, and input fields. The step between background and photo.
- **Ink** (`oklch(17% 0.010 65)`): Primary text. Near-black with a warm undertone that matches the background's hue.
- **Secondary Text** (`oklch(52% 0.008 65)`): Captions, stage labels, supporting copy, disabled text. Should feel like a whisper, not a shout.
- **Divider** (`oklch(85% 0.008 65)`): Borders, separators, disabled button backgrounds.
- **Photo Overlay** (`oklch(10% 0 0 / 55%)`): Dark translucent background for icon buttons that sit over photos (fullscreen expand, download). The only near-black in the UI.

### Named Rules

**The One Voice Rule.** Amber appears on ≤10% of any given screen. Its rarity is the point. Never use it for decoration — only for the single most important action in the current context.

**The No-White Rule.** Never use pure `#ffffff` or `#000000`. Film White and Ink have been calibrated with warm undertones; straying to pure values breaks the photographic feel.

## 3. Typography: Fraunces

**Font:** Fraunces (variable weight, with `opsz` optical size axis) — a single family used at every text size.
**Fallback:** Georgia, serif

**Character:** Fraunces is an optical serif with a slightly worm-soft quality at lighter weights and editorial authority at heavier ones. Using it throughout replaces the default SF Pro and gives the app a distinctive identity without resorting to a loud or trendy display face. It is not decorative — it is precise in a different way than a geometric sans.

### Hierarchy

- **Display** (weight 600, clamp 2–3.5rem, line-height 1.0, tracking −0.02em): App name on setup screen, completion headline. Big and settled.
- **Headline** (weight 600, 22px, line-height 1.15): Section headings, navigation titles, "Your Favorites."
- **Title** (weight 500, 17px, line-height 1.25): Screen subtitles, list section headers.
- **Body** (weight 400, 16px, line-height 1.55): Multi-line descriptions. Max line length 65ch.
- **Label** (weight 500, 14px, line-height 1.3, tracking +0.01em): Button text, interactive labels. Weight 500 keeps it readable at action sizes.
- **Caption** (weight 400, 11px, line-height 1.3, tracking +0.02em): Comparison count, stage label, metadata. Very quiet.

### Named Rules

**The Weight-Over-Size Rule.** Hierarchy is expressed through weight contrast first, size second. Two type sizes with two weight levels are enough for the entire UI. Resist adding a third typeface.

## 4. Elevation

Pictalis is flat by default. No shadows anywhere in the interface. Depth is conveyed through background color steps (Film White → Grain Paper) and the photos themselves, which naturally advance from any surface around them.

The single exception is the photo overlay button (fullscreen expand, download icon): a 55% dark translucent background on a `pill` shape that sits over the image. This is not elevation — it is legibility. It has no shadow.

**The Flat-By-Default Rule.** If you're reaching for a shadow, ask whether tonal layering (a background step from Film White to Grain Paper, or Grain Paper to Divider) solves the problem instead. Usually it does.

## 5. Components

### Photo Comparison Cells

The heart of the app. Two cells stacked vertically, each filling the full width minus a small horizontal inset. Photos are presented at 4px corner radius — almost frameless, like a print — and clipped to fill the frame regardless of aspect ratio.

- **Shape:** 4px radius (`{rounded.photo}`). Never clip to a circle or pillar shape.
- **Background:** Grain Paper (`{colors.grain-paper}`) while loading. Disappears once the photo fills the frame.
- **Aspect ratio:** 4:3 (matches most phone camera output). Constrain the frame; let the image fill it.
- **Overlay buttons:** Expand and any per-photo actions use `{components.photo-overlay-button}` — pill-shaped, 55% dark translucent, white icon, 8px internal padding. Top-trailing position.
- **Selection state:** On tap, the cell scales down to 96% over 60ms ease-out, then back to 100% over 60ms — a tactile confirmation that the choice landed. The next pair then enters over 120ms ease-out.
- **Disabled while submitting:** Cells lose interaction at 70% opacity. No skeleton, no spinner overlay.

### Buttons

Buttons are small in this app — they exist at the edge of the photo experience, never at the center of it.

- **Shape:** 8px radius (`{rounded.interactive}`). Medium-rounded. Not pill, not sharp.
- **Primary** (`{components.button-primary}`): Amber background, Film White text, weight 500 Fraunces. Used once per screen, for the singular primary action (Start Curating, Export All Favorites).
- **Primary Hover/Press:** Darkens to `oklch(52% 0.125 62)` over 80ms ease-out. No scale, no shadow.
- **Primary Disabled** (`{components.button-primary-disabled}`): Divider background, Secondary Text color. Clearly unavailable; not interactive-looking.
- **Ghost** (`{components.button-ghost}`): No background, Secondary Text color. Skip to Results, Start Over, See Full Rankings. These actions exist but should not compete.

### Status Badges

Used in the comparison screen toolbar to indicate session stage. Capsule shape. Color-coded but muted — never alarming.

- **Complete** (`{components.status-badge-complete}`): Sage green tint (15% opacity) with dark sage text. Shows "Complete."
- **Active / In Progress** (`{components.status-badge-active}`): Warm amber tint (15% opacity) with dark amber text. Shows current stage name.
- **Typography:** Caption weight 500 (label size), slightly bold for legibility at small pill dimensions.

### Photo Grid Cells (Results)

Used in ResultsView and the CompletionView top-10 preview.

- **Shape:** 4px radius, consistent with comparison cells. Square crop (`aspectRatio: 1`) in the 3-column completion grid; unconstrained fill in the 2-column results grid (height 180pt).
- **Background:** Grain Paper while loading.
- **Overlay:** Same pill-shaped download button as comparison cells, bottom-trailing position.

### Navigation

Standard iOS NavigationStack. Navigation title in Headline weight (600, 22px Fraunces). Back button uses system default. Toolbar items use Label weight Fraunces where custom text is needed.

The navigation bar should appear translucent over Film White — not opaque. On scroll it can pick up a slight blur, but the background color always reads as warm, not blue-grey.

### Upload Progress Banner

A thin strip above the comparison cells, visible only while upload is in progress. Quiet.

- **Background:** Grain Paper (one step warmer than Film White, creates a contained strip without a visible border)
- **Progress indicator:** Thin fill bar, Amber Dim fill on Divider track
- **Caption:** `{typography.caption}` — "{n}/{total}" — right-aligned, Secondary Text

## 6. Do's and Don'ts

### Do:
- **Do** present photos at maximum possible size. The frame should feel like looking through a window, not a thumbnail preview.
- **Do** use Amber for exactly one interactive element per screen — the primary action. Its singularity is what makes it work.
- **Do** use weight contrast (400 → 600) to create hierarchy within Fraunces before reaching for size differences.
- **Do** keep motion snappy: 120ms ease-out for pair transitions, 60ms for tap feedback, 220ms for full-screen transitions. Faster than you think is right.
- **Do** use Film White and Grain Paper — not pure `#fff` or `#f5f5f5` — to maintain the warm-paper feel throughout.
- **Do** write copy that honors that these are personal memories. "Your favorites are ready" not "Processing complete."

### Don't:
- **Don't** use gradient fills on any background, button, or text element. This is explicitly the Generic SaaS anti-reference from PRODUCT.md. One solid color per element.
- **Don't** apply `background-clip: text` with a gradient for any heading — not the app name, not the completion headline, nowhere.
- **Don't** make the comparison UI feel like Tinder. No swipe gestures, no gamified streak counters, no points or badges. Choosing a photo is a considered act, not a reflex.
- **Don't** let the chrome compete with the photos. If a UI element is drawing your eye away from the images, it's too loud. Pull it back with Secondary Text color or Caption size.
- **Don't** use `#ffffff` or `#000000`. Every color in this system has a warm undertone; pure white or pure black will read as foreign.
- **Don't** use a shadow on any surface. Elevation is tonal or photographic, never shadow-based.
- **Don't** introduce a border-left stripe as an accent on any list item, card, or callout. This is a universal ban in this system.
- **Don't** add status indicators, comparison counts, or progress metrics that quantify the process in ways that feel mechanical. If the user is thinking about "comparison 47 of 200," the framing has failed.
