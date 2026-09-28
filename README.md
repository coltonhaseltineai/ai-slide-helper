# Live Outline

A speaker pastes their talk outline, clicks **Present**, and then **Start listening**. As they talk, the app listens through the microphone and **bolds and highlights the outline line they're currently on**. The audience can always see where the speaker is, and nobody has to click through each line by hand.

## iPhone
Open **https://live-outline.vercel.app** in Safari, then tap Share → **Add to Home Screen**. Tap **Listen** to follow your voice, and swipe or use ‹ › to move by hand. If listening isn't allowed from the home-screen icon, open the same link in Safari.

## Following by meaning (Mac app)
Speakers rarely read their outline word for word, so the Mac app follows **what you mean**, not just which words you say. Choose how in Settings (⌘,) → **Follow by meaning**:
- **Automatic** (default): Apple's on-device model when your Mac has Apple Intelligence (macOS 26+, Apple silicon), otherwise a tiny meaning model. Both are free, private and work offline.
- **Apple on-device model**, **Tiny meaning model**, **Claude** (needs the access code) or **Keywords only**.

A few times a second, the judge sees the outline, the point shown now and the last ~20 seconds of speech. It answers *same*, *moved to point N*, *tangent* or *unclear*, each with a confidence. The highlight moves at once for a confident move to the next point. It needs a second vote to skip ahead or go back, and it holds still for asides and callbacks. Your arrow keys always win. **Nothing is learned or saved from your speech.**

**Help → Compare Judges** replays 10 practice talks through each judge on your Mac and shows who stays on the right point and how fast. Claude's rows are recorded results from `eval/`. `eval/README.md` explains how the benchmark works.

Server setup for the Claude option (Vercel project settings → Environment Variables): `ANTHROPIC_API_KEY` and `ACCESS_CODE` (the code you type into the app). `api/follow` is the judge; the older `api/locate` and `api/expand` still answer old app versions but no longer learn anything.

## Mac app (recommended)
A native SwiftUI app lives in `mac/`. It uses Apple's built-in speech recognition, which runs on your Mac when your Mac supports it.

**Download:** open the latest *Mac app* run under the repo's **Actions** tab and download `LiveOutline-mac`. Unzip it and drag **Live Outline** to Applications. The app isn't notarized, so the first time you open it, right-click it and choose **Open**.

**Automatic updates:** the app checks for new versions daily (or use **Live Outline → Check for Updates…**) and installs them in one click, via [Sparkle](https://sparkle-project.org). Every push to this branch publishes a signed release that installed apps pick up. This needs two repository secrets, set once under Settings → Secrets and variables → Actions:
- `SPARKLE_PRIVATE_KEY`, which signs updates so the app only installs genuine ones.
- `MAC_SIGNING_P12`, a signing certificate (base64 .p12, password `liveoutline`) so every version has the same identity and keeps its microphone permission.

**Build it yourself** (Xcode 26.4 or later, for Apple's on-device model; the app itself runs on macOS 14+):
```
cd mac
./scripts/build-app.sh      # creates mac/build/Live Outline.app
open "build/Live Outline.app"
```

- **Edit**: type the outline on the left and see a live preview on the right. Press ⌘↩ to present.
- **Present**: a large outline with a sliding highlight. Press Space or ⌘L to start or stop listening. Use ← → or click a line to correct it, and ⌃⌘F for full screen.
- A live transcript and a mic level meter sit at the bottom.

## Web version
Open `index.html` in Chrome or Edge, which provide in-browser speech recognition. Serving it over `localhost` or https is best:

```
python3 -m http.server 8000   # then visit http://localhost:8000
```

- Indent lines to nest them.
- Add hidden hints to a line: `Memory consolidation [cues: remember, learning]`.
- ← / → or clicking a line corrects the highlight, and listening continues from there.
- ⛶ goes fullscreen, for a projector or a shared screen.

## How the matching works (`matcher.js`)
Recent speech is turned into keywords, and each outline line is scored by how many of its keywords were said recently. Rarer words and newer words count more. The current and next lines get a bonus, and the highlight moves only when another line clearly wins twice in a row, so it doesn't flicker.

## Tests
```
node --test            # web matcher, judge server, benchmark data and fixtures
cd mac && swift test   # Swift matcher, judge prompt/follower parity with the JavaScript reference, closed-loop replay
```
