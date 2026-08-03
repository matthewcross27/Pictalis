# App Store Screenshots

Apple requires at least one set of screenshots for iPhone 6.9" (used by iPhone 16 Pro Max).
Screenshots must come from a running simulator — not Figma or mocked images.

The 5 required screenshots below are already captured and committed to this
directory. Re-run the capture steps only when the UI changes enough to make
them stale.

## Required Screenshots (5 total)

| Filename | Screen to capture |
|----------|------------------|
| `01-session-setup.png` | SessionSetupView — photo selection prompt |
| `02-cull-pass.png` | CullView — a photo with Keep/Skip buttons visible |
| `03-comparison.png` | ComparisonView — two photos side by side |
| `04-completion.png` | CompletionView — "your favorites are ready" |
| `05-results.png` | ResultsView — ranked photo grid |

## How to Capture

```bash
# 1. Boot iPhone 16 Pro Max simulator
xcrun simctl boot "iPhone 16 Pro Max" 2>/dev/null || true
open -a Simulator

# 2. Build and run in Xcode: scheme Pictalis → simulator → Cmd+R

# 3. Capture each screen (navigate to the screen first, then run):
xcrun simctl io booted screenshot docs/app-store/screenshots/01-session-setup.png
xcrun simctl io booted screenshot docs/app-store/screenshots/02-cull-pass.png
xcrun simctl io booted screenshot docs/app-store/screenshots/03-comparison.png
xcrun simctl io booted screenshot docs/app-store/screenshots/04-completion.png
xcrun simctl io booted screenshot docs/app-store/screenshots/05-results.png

# 4. Verify dimensions (expected: 1320x2868 or 1290x2796):
for f in docs/app-store/screenshots/*.png; do
  echo "$f: $(sips -g pixelWidth -g pixelHeight "$f" | grep -E 'Width|Height' | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')"
done
```

## After Capturing

Upload all 5 PNGs to App Store Connect under the 6.9" screenshot slot.
