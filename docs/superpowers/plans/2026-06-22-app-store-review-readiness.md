# App Store Review Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Pictalis from a feature-complete codebase to a state that passes Apple App Store review.

**Architecture:** No new features — this plan is purely pre-submission polish: privacy manifest, metadata/ASO copy, privacy policy, App Store screenshots, signing config, accessibility labels, and review notes. Tasks are independent and can be parallelized across agents.

**Tech Stack:** SwiftUI iOS 17+, XcodeGen (`project.yml`), Supabase (anonymous auth), Sentry, Fraunces custom fonts.

## Global Constraints

- Bundle ID: `com.matthewcross.Pictalis`
- Minimum deployment target: iOS 17.0
- Interface style: Light only (`UIUserInterfaceStyle: Light` in Info.plist — intentional, do NOT add dark mode)
- Custom font: Fraunces (Regular, Medium, SemiBold) — already bundled at `ios/Sources/App/Fonts/`
- XcodeGen: all project changes go in `ios/project.yml`, then run `xcodegen generate` from `ios/`
- App uses **anonymous Supabase auth** — there is no login page; reviewers must be told this explicitly
- Original photos never leave the device — only compressed copies upload (key privacy talking point)
- Never commit real credentials; the Supabase anon key in `SupabaseConfig.swift` is intentionally public (Row Level Security enforces access)
- Screenshots must be taken on a real iOS 17+ simulator, **not** designed in Figma or mocked

---

## File Map

| File | Status | Responsible Task |
|------|--------|-----------------|
| `ios/Sources/PrivacyInfo.xcprivacy` | Create | Task 1 |
| `ios/project.yml` | Modify (add signing, version) | Task 5 |
| `docs/app-store/metadata-en-US.md` | Create | Task 2 |
| `docs/app-store/privacy-policy.md` | Create | Task 3 |
| `docs/app-store/support.md` | Create | Task 3 |
| `docs/app-store/screenshots/` | Create (PNG files) | Task 4 |
| `docs/app-store/review-notes.md` | Create | Task 7 |
| `ios/Sources/App/Views/*.swift` (accessibility) | Modify | Task 6 |

---

## Task 1: Privacy Manifest (PrivacyInfo.xcprivacy)

Apple requires a `PrivacyInfo.xcprivacy` file in every app submitted since May 2024. Pictalis accesses the file system with timestamp-dependent APIs (via `FileManager`) and the photo library, which triggers Required Reasons API reporting. No app-level manifest currently exists — only dependencies (Sentry, swift-crypto) have their own.

**Files:**
- Create: `ios/Sources/PrivacyInfo.xcprivacy`

**Interfaces:**
- Produces: Privacy manifest that Xcode bundles into the `.ipa`; satisfies App Store validation

- [ ] **Step 1: Create the privacy manifest**

Create `ios/Sources/PrivacyInfo.xcprivacy`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypePhotosorVideos</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeCrashData</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <false/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
    </array>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>C617.1</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryDiskSpace</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>E174.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

Reason codes:
- `C617.1` = file timestamp access for the app's own files (temp JPEG materialization)
- `E174.1` = disk space check to ensure upload will not fail

- [ ] **Step 2: Verify the file is valid XML**

```bash
cd ios
plutil -lint Sources/PrivacyInfo.xcprivacy
```

Expected: `Sources/PrivacyInfo.xcprivacy: OK`

- [ ] **Step 3: Regenerate the Xcode project**

XcodeGen auto-includes all files under `Sources/`, so no change to `project.yml` is needed.

```bash
cd ios
xcodegen generate
```

Expected: no errors. Open `Pictalis.xcodeproj` and confirm `PrivacyInfo.xcprivacy` appears in the file navigator.

- [ ] **Step 4: Commit**

```bash
git add ios/Sources/PrivacyInfo.xcprivacy
git commit -m "feat(privacy): add PrivacyInfo.xcprivacy for App Store submission"
```

---

## Task 2: App Store Metadata (ASO)

Prepare all copy for App Store Connect. This task produces a reference document; an agent or human then pastes the values into App Store Connect.

**Files:**
- Create: `docs/app-store/metadata-en-US.md`

**Interfaces:**
- Produces: Finalized title/subtitle/description/keywords/promo/release-notes for en-US

- [ ] **Step 1: Create the metadata directory**

```bash
mkdir -p docs/app-store
```

- [ ] **Step 2: Write the metadata document**

Create `docs/app-store/metadata-en-US.md`:

```markdown
# Pictalis — App Store Metadata (en-US)

## Title (30 chars max)
Pictalis: Photo Curation

Char count: 25 ✓

## Subtitle (30 chars max)
Pick your favorites, fast

Char count: 24 ✓

## Promotional Text (170 chars max)
Stop scrolling through hundreds of photos. Pictalis uses head-to-head matchups to find the shots you'll actually keep — in minutes, not hours.

Char count: 141 ✓

## Keywords (100 chars max, comma-separated, NO spaces after commas)
cull,curate,favorite,compare,select,organize,gallery,batch,review,keeper,trip,event,party

Char count: 89 ✓
Notes:
- "Pictalis" and "photo" excluded — already in title (Apple indexes automatically)
- No plurals: "cull" covers "culling", "favorite" covers "favorites"

## Description (4000 chars max)
You came home with 300 photos from the trip. Now what?

Pictalis makes photo curation effortless by turning an overwhelming gallery into a series of simple head-to-head matchups. Tap the photo you like better. Repeat. In minutes you'll know exactly which shots are worth keeping.

**How it works:**
1. Select a batch of photos from your library
2. Quickly swipe through your shots with an optional cull pass — keep the good, ditch the obvious dupes
3. Compare photo pairs head-to-head — your only job is to pick a favorite
4. See your ranked results and save your top picks back to your library

**Why it works:**
Humans are wired for comparison, not scoring. Asking "which of these two do I prefer?" is far faster than rating photos on a scale — so Pictalis never asks you to do that. Each comparison takes under a second. A set of 100 photos typically yields a ranked list in 5–10 minutes.

**What Pictalis doesn't do:**
- No AI aesthetic scoring — your taste, your results
- No cloud storage of your originals — photos stay on your device
- No subscription required
- No accounts or sign-in required to get started

Perfect for:
• Trips and travel photos
• Graduation and party shoots
• Event and portrait sessions
• Any time you need to go from "too many" to "just right"

## Release Notes (4000 chars max)
Welcome to Pictalis! This is our first App Store release.

Pictalis helps you quickly find the photos you'll actually keep — using simple head-to-head comparisons powered by an Elo-style ranking system.

If you run into any issues, tap the support link below to reach us.

## Privacy Policy URL
https://pictalis.app/privacy
(Must be live before submission — see Task 3)

## Support URL
https://pictalis.app/support
(Must be live before submission — see Task 3)

## App Category
Primary: Photography
Secondary: Utilities

## Age Rating
4+ (no objectionable content, no user-generated content visible to others)
```

- [ ] **Step 3: Verify keyword character count**

```bash
echo -n "cull,curate,favorite,compare,select,organize,gallery,batch,review,keeper,trip,event,party" | wc -c
```

Expected: `89` (under 100 ✓)

- [ ] **Step 4: Commit**

```bash
git add docs/app-store/metadata-en-US.md
git commit -m "docs: add App Store metadata (en-US) for Pictalis submission"
```

---

## Task 3: Privacy Policy & Support Pages

Apple requires a publicly accessible Privacy Policy URL for any app that accesses personal data. Pictalis accesses the photo library and collects anonymous session identifiers, so a policy is required. A Support URL is also required.

**Files:**
- Create: `docs/app-store/privacy-policy.md`
- Create: `docs/app-store/support.md`

**Interfaces:**
- Produces: Privacy policy and support page content ready to publish at `pictalis.app/privacy` and `pictalis.app/support`

- [ ] **Step 1: Write the privacy policy**

Create `docs/app-store/privacy-policy.md`:

```markdown
# Pictalis Privacy Policy

**Last updated:** June 22, 2026

## Overview

Pictalis is committed to protecting your privacy. This policy describes what
data we collect, how we use it, and what we don't do.

## What We Collect

### Photos
- Pictalis reads photos from your device's photo library that **you explicitly select**.
- Your **original photos never leave your device**.
- Pictalis creates compressed working copies (max 1920px on the longest edge)
  solely to display photos during your curation session.
- These compressed copies are uploaded to our servers temporarily and
  **automatically deleted within 72 hours**.

### Anonymous Session Data
- When you start a session, Pictalis creates an anonymous identifier to
  associate your comparisons with your results.
- This identifier is not linked to your name, email address, Apple ID, or
  any other personal information.
- Session data (your comparison choices and photo rankings) is stored on our
  servers for up to 72 hours, then deleted.

### Crash Reports
- If the app crashes, Sentry (a third-party crash reporting service) collects
  diagnostic information including device model, iOS version, and a stack trace.
- No photos or personal identifiers are included in crash reports.
- Sentry's privacy policy: https://sentry.io/privacy/

## What We Don't Collect
- Your name, email, or Apple ID
- Location data
- Contacts
- Browsing or usage history across other apps
- Any permanent record of your photos

## Data Retention
- Compressed photo copies: deleted within 72 hours of session creation
- Anonymous session data (rankings, comparisons): deleted within 72 hours
- Crash reports: retained for 90 days by Sentry

## Third-Party Services
- **Supabase** (database and file storage): supabase.com/privacy
- **Sentry** (crash reporting): sentry.io/privacy

## Children
Pictalis is rated 4+ and does not knowingly collect any information from users.

## Contact
Questions? Email us: support@pictalis.app

## Changes to This Policy
We will post any changes here with an updated "Last updated" date.
```

- [ ] **Step 2: Write the support page**

Create `docs/app-store/support.md`:

```markdown
# Pictalis Support

## Frequently Asked Questions

**Do I need an account?**
No. Pictalis uses anonymous sessions — no sign-up, no email, no password.

**Where are my photos stored?**
Your original photos never leave your device. Pictalis only uploads compressed
preview copies (automatically deleted within 72 hours).

**The app isn't loading my photos. What should I do?**
Go to Settings → Privacy & Security → Photos → Pictalis and make sure access
is set to "All Photos" or "Selected Photos."

**My session disappeared. Can I get it back?**
Sessions are stored for up to 72 hours. If your session expired, start a new one.

**The app crashed. How do I report it?**
Email us at support@pictalis.app with your iOS version and iPhone model.

## Contact

Email: support@pictalis.app
Response time: within 48 hours on business days.
```

- [ ] **Step 3: Commit the content**

```bash
git add docs/app-store/privacy-policy.md docs/app-store/support.md
git commit -m "docs: add privacy policy and support page content for App Store submission"
```

- [ ] **Step 4: Publish the pages (manual — requires web host)**

This step must be completed by the developer. Simplest options:

**Option A — GitHub Pages (recommended):**
1. Create a new public GitHub repo `pictalis-website`
2. Add `privacy-policy.md` at `privacy/index.md` and `support.md` at `support/index.md`
3. Enable GitHub Pages on `main` branch
4. Point `pictalis.app` DNS CNAME to `<username>.github.io`

**Option B — Notion (fastest for MVP):**
1. Create a Notion page, make it public
2. Use the public URL as the privacy policy URL in App Store Connect

After publishing, update `docs/app-store/metadata-en-US.md` with the actual live URLs.

---

## Task 4: App Store Screenshots

Apple requires at least one set of screenshots for iPhone 6.9" (the slot used by iPhone 16 Pro Max). Screenshots must come from a running simulator.

**Files:**
- Create: `docs/app-store/screenshots/*.png` (5 files)

**Interfaces:**
- Produces: 5 PNG screenshots at 1320×2868 showing the main user flows; ready to upload to App Store Connect

- [ ] **Step 1: Launch the correct simulator**

```bash
# Boot iPhone 16 Pro Max (iOS 18)
xcrun simctl boot "iPhone 16 Pro Max" 2>/dev/null || true
open -a Simulator
```

If "iPhone 16 Pro Max" doesn't exist, create it first:

```bash
xcrun simctl create "Screenshot Device" "iPhone 16 Pro Max" "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
xcrun simctl boot "Screenshot Device"
```

- [ ] **Step 2: Build and run on the simulator**

In Xcode: set scheme to `Pictalis`, destination to the booted simulator, then `Cmd+R`.

- [ ] **Step 3: Create the screenshots directory**

```bash
mkdir -p docs/app-store/screenshots
```

- [ ] **Step 4: Capture 5 screenshots**

Navigate to each screen, then capture with:

```bash
xcrun simctl io booted screenshot docs/app-store/screenshots/01-session-setup.png
```

Do this for each of the 5 screens:

| Filename | Screen to show |
|----------|---------------|
| `01-session-setup.png` | SessionSetupView — photo selection prompt |
| `02-cull-pass.png` | CullView — a photo with Keep/Skip buttons |
| `03-comparison.png` | ComparisonView — two photos side by side |
| `04-completion.png` | CompletionView — "your favorites are ready" |
| `05-results.png` | ResultsView — ranked photo grid |

- [ ] **Step 5: Verify dimensions**

```bash
for f in docs/app-store/screenshots/*.png; do
  echo "$f: $(sips -g pixelWidth -g pixelHeight "$f" | grep -E 'Width|Height' | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')"
done
```

Expected: `1320x2868` (iPhone 16 Pro Max) or `1290x2796` (iPhone 15 Pro Max). Both accepted by Apple for the 6.9" slot.

- [ ] **Step 6: Commit**

```bash
git add docs/app-store/screenshots/
git commit -m "docs: add App Store screenshots (6.9-inch iPhone)"
```

---

## Task 5: Signing & Distribution Configuration

`DEVELOPMENT_TEAM` in `ios/project.yml` is currently an empty string. An archive build for App Store distribution requires a valid team ID and version/build numbers.

**Files:**
- Modify: `ios/project.yml`

**Interfaces:**
- Produces: A project that can be archived with `Product → Archive` and uploaded to App Store Connect

- [ ] **Step 1: Find your Apple Developer Team ID**

```bash
# From Xcode: Xcode → Settings → Accounts → select your Apple ID → Team ID column
# Or from the Apple Developer portal:
open "https://developer.apple.com/account#MembershipDetailsCard"
# The Team ID is a 10-character string like: ABC1234DEF
```

- [ ] **Step 2: Add Team ID, signing style, and version numbers to project.yml**

In `ios/project.yml`, find the `Pictalis` target's `settings.base` block:

```yaml
    settings:
      base:
        SWIFT_VERSION: "5.9"
        DEVELOPMENT_TEAM: ""
        SWIFT_STRICT_CONCURRENCY: complete
        ENABLE_USER_SCRIPT_SANDBOXING: YES
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

Replace it with (substitute your real Team ID for `XXXXXXXXXX`):

```yaml
    settings:
      base:
        SWIFT_VERSION: "5.9"
        DEVELOPMENT_TEAM: "XXXXXXXXXX"
        CODE_SIGN_STYLE: Automatic
        SWIFT_STRICT_CONCURRENCY: complete
        ENABLE_USER_SCRIPT_SANDBOXING: YES
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

Also add version info to the `info.properties` block:

```yaml
        CFBundleShortVersionString: "1.0"
        CFBundleVersion: "1"
```

- [ ] **Step 3: Regenerate the Xcode project**

```bash
cd ios
xcodegen generate
```

Expected: no errors.

- [ ] **Step 4: Verify signing in Xcode**

Open `ios/Pictalis.xcodeproj` → select the `Pictalis` target → `Signing & Capabilities` tab.

Verify:
- Team: shows your team name (not "None")
- Bundle Identifier: `com.matthewcross.Pictalis`
- Signing Certificate: "Apple Distribution" (in Release) or "Apple Development" (in Debug)

- [ ] **Step 5: Register the App ID if needed**

If this is the first distribution build, register the bundle ID at:

```
https://developer.apple.com/account/resources/identifiers/list
```

Add a new App ID: `com.matthewcross.Pictalis`. No special capabilities are needed beyond default.

- [ ] **Step 6: Test an archive build**

In Xcode: `Product → Archive` (scheme must be set to Release / Any iOS Device).

Expected: Archive succeeds and Organizer window opens automatically.

- [ ] **Step 7: Commit**

```bash
git add ios/project.yml
git commit -m "chore(signing): set DEVELOPMENT_TEAM and version 1.0 (build 1) for App Store"
```

**Security note:** Team IDs are not secret (they appear in App Store URLs), so committing this is safe.

---

## Task 6: Accessibility Labels Audit

Apple reviewers check VoiceOver support. The core interaction — tapping one of two photos to choose it — must have a meaningful VoiceOver label or visually impaired users cannot use the app.

**Files:**
- Modify: `ios/Sources/App/Views/ComparisonView.swift`
- Modify: `ios/Sources/App/Views/CullView.swift`
- Modify: `ios/Sources/App/Views/ResultsView.swift`
- Modify: `ios/Sources/App/Views/CompletionView.swift`
- Modify: `ios/Sources/App/Views/SessionSetupView.swift`

**Interfaces:**
- Produces: All interactive elements have `.accessibilityLabel()`; action buttons have `.accessibilityHint()` where the action is non-obvious

- [ ] **Step 1: Read each view file before editing**

Read all five files to understand their current SwiftUI structure:
- `ios/Sources/App/Views/ComparisonView.swift`
- `ios/Sources/App/Views/CullView.swift`
- `ios/Sources/App/Views/ResultsView.swift`
- `ios/Sources/App/Views/CompletionView.swift`
- `ios/Sources/App/Views/SessionSetupView.swift`

- [ ] **Step 2: Add accessibility to ComparisonView**

In `ComparisonView.swift`, find each tappable photo card (the two photos shown for pairwise comparison). Add to the tappable container for the left/top photo:

```swift
.accessibilityLabel("Left photo")
.accessibilityHint("Double-tap to choose this photo as your favorite")
```

And to the right/bottom photo:

```swift
.accessibilityLabel("Right photo")
.accessibilityHint("Double-tap to choose this photo as your favorite")
```

If photos have an order index available, use `"Photo \(index + 1)"` instead.

- [ ] **Step 3: Add accessibility to CullView**

In `CullView.swift`, find the Keep and Skip/Drop action buttons and add:

```swift
// Keep button:
.accessibilityLabel("Keep")
.accessibilityHint("Add this photo to the ranking round")

// Skip button:
.accessibilityLabel("Skip")
.accessibilityHint("Remove this photo from ranking")
```

- [ ] **Step 4: Add accessibility to ResultsView**

In `ResultsView.swift`, find the photo grid cells. Add rank-aware labels:

```swift
// Each photo cell — if rank is available as `rank`:
.accessibilityLabel("Photo ranked number \(rank)")

// Save/export button:
.accessibilityLabel("Save to Photos library")
```

- [ ] **Step 5: Verify with Accessibility Inspector**

Open `Xcode → Open Developer Tool → Accessibility Inspector`.

Set the target to your running simulator. Navigate through the comparison screen using the point-and-click inspector. Verify each interactive element shows a non-empty accessibility label and hint.

Expected: The two photo cards each announce their label and hint when focused.

- [ ] **Step 6: Commit**

```bash
git add ios/Sources/App/Views/
git commit -m "feat(a11y): add VoiceOver accessibility labels to comparison, cull, and results views"
```

---

## Task 7: App Review Notes & Final Submission Checklist

Apple reviewers need context for the anonymous auth flow — without a login screen they may flag the app as incomplete. This task prepares review notes and a go/no-go checklist.

**Files:**
- Create: `docs/app-store/review-notes.md`

**Interfaces:**
- Produces: Review notes text to paste into App Store Connect "Notes for App Review" field; final submission checklist

- [ ] **Step 1: Write the review notes**

Create `docs/app-store/review-notes.md`:

```markdown
# Notes for App Review

## How Pictalis Works (No Login Required)

Pictalis uses anonymous authentication — there is no sign-in screen. When the
app opens for the first time, a session is automatically created. No email,
password, or Apple ID is needed.

## Step-by-Step Demo for Reviewers

1. Open the app
2. Tap "Choose Photos" and grant photo library access when prompted
3. Select 5–20 photos from your library (at least 5 for a meaningful session)
4. Tap "Start Session"
5. On the next screen, tap "Filter First" to do a quick cull pass (optional),
   or tap to proceed directly to comparisons
6. Tap through a few head-to-head comparisons — tap the photo you prefer
7. Tap "See My Rankings" at any time to view the results

The full flow takes about 2 minutes with 10 photos.

## Privacy Notes for Reviewers

- Photos are only read from the device during active use
- Compressed copies (max 1920px) are uploaded temporarily and auto-deleted
  within 72 hours — original full-resolution photos never leave the device
- No user account or personal data is collected

## Known Limitations (MVP)

- Requires network connectivity for the ranking engine
- Session data expires after 72 hours by design (this is a curation tool,
  not a photo manager)

## Test Credentials

None required. The app is fully functional without any account.
```

- [ ] **Step 2: Verify app icon has no alpha channel**

```bash
sips -g hasAlpha ios/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```

Expected output includes: `hasAlpha: no`

If it shows `hasAlpha: yes`, flatten the icon to a solid background (open in Preview, export as PNG with no alpha) and replace the file.

- [ ] **Step 3: Run the complete pre-submission checklist**

Work through each item before submitting to App Store Connect:

```
SUBMISSION CHECKLIST
====================

App Identity
[ ] Bundle ID registered in Apple Developer Portal: com.matthewcross.Pictalis
[ ] DEVELOPMENT_TEAM set in ios/project.yml (Task 5)
[ ] CFBundleShortVersionString: "1.0" in ios/project.yml (Task 5)
[ ] CFBundleVersion: "1" in ios/project.yml (Task 5)

Assets
[ ] App icon 1024x1024 PNG with no alpha (verified in Step 2 above)
[ ] 5+ screenshots in docs/app-store/screenshots/ uploaded to App Store Connect (Task 4)

Privacy
[ ] PrivacyInfo.xcprivacy present at ios/Sources/PrivacyInfo.xcprivacy (Task 1)
[ ] Privacy Policy URL is live and publicly accessible (Task 3)
[ ] Support URL is live and publicly accessible (Task 3)
[ ] Privacy Nutrition Labels completed in App Store Connect:
      Photos or Videos — collected: YES, linked to user: NO, tracking: NO
      Crash Data — collected: YES, linked to user: NO, tracking: NO

App Store Connect
[ ] App record created with bundle ID com.matthewcross.Pictalis
[ ] Category: Photography (primary), Utilities (secondary)
[ ] Age rating: 4+ (complete the content questionnaire; select "None" for all
      content types — no violence, no sexual content, no user-generated content)
[ ] Pricing: Free
[ ] Availability: at minimum United States
[ ] All metadata pasted from docs/app-store/metadata-en-US.md (Task 2)
[ ] Privacy Policy URL entered
[ ] Support URL entered
[ ] Review notes from docs/app-store/review-notes.md pasted into
    "Notes for App Review" field

Build
[ ] Archive build succeeds: Product → Archive in Xcode (Release / Any iOS Device)
[ ] Archive uploaded to App Store Connect via Xcode Organizer → Distribute App
    → App Store Connect → Upload
[ ] Build visible in App Store Connect under TestFlight or Builds tab
[ ] No "ITMS-90XXX" errors in the upload result email from Apple

Final Smoke Test (on device or simulator, Release build)
[ ] App launches without crash
[ ] Photo permission prompt appears with correct string:
    "Pictalis needs access to your photos to help you curate your favorites."
[ ] Session can be created and first comparison displayed within 10 seconds
[ ] Tapping a comparison photo advances to the next pair
[ ] "See My Rankings" shows a ranked list of photos
```

- [ ] **Step 4: Commit**

```bash
git add docs/app-store/review-notes.md
git commit -m "chore(release): add App Store review notes and pre-submission checklist"
```

---

## Self-Review

### Spec Coverage

| Requirement | Task |
|-------------|------|
| Privacy manifest (Apple mandatory since May 2024) | Task 1 |
| ASO copy: title, subtitle, keywords, description, promo | Task 2 |
| Privacy Policy URL (required for photo-accessing apps) | Task 3 |
| Support URL (required field in App Store Connect) | Task 3 |
| App Store screenshots — iPhone 6.9" required | Task 4 |
| DEVELOPMENT_TEAM / distribution signing | Task 5 |
| Version + build numbers | Task 5 |
| VoiceOver accessibility labels on interactive elements | Task 6 |
| App Review notes (anonymous auth explanation) | Task 7 |
| App icon alpha channel verification | Task 7 |
| Privacy Nutrition Labels guidance | Task 7 checklist |
| Age rating, pricing, availability | Task 7 checklist |

### Out of Scope (Intentional)

- **Dark mode:** `UIUserInterfaceStyle: Light` is the intentional design. Reviewers accept light-only apps; no change needed.
- **iPad screenshots:** Pictalis targets iPhone only; no iPad-specific layout exists. Apple does not require iPad screenshots for iPhone-only apps.
- **6.5" screenshots:** Optional when 6.9" set is present; can be added as a follow-up.
- **Localization:** en-US only is accepted for MVP.
- **In-app purchases / StoreKit:** No IAP in this version.
- **Push notifications:** Not used; no entitlements file needed.
