# Notes for App Review

## How Pictalis Works (No Login Required)

Pictalis uses anonymous authentication — there is no sign-in screen. When the
app opens for the first time, a session is automatically created. No email,
password, or Apple ID is needed.

## Step-by-Step Demo for Reviewers

1. Open the app
2. Tap "Choose photos" and grant photo library access when prompted
3. Select 5–20 photos from your library (at least 5 for a meaningful session)
4. Tap "Start Curating"
5. On the next screen, tap "Filter then rank" to do a quick cull pass (optional),
   or tap to proceed directly to comparisons
6. Tap through a few head-to-head comparisons — tap the photo you prefer
7. Tap "See Full Rankings" at any time to view the results

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

## SUBMISSION CHECKLIST

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
[ ] "See Full Rankings" shows a ranked list of photos
