# Live Outline

A speaker pastes their talk outline, clicks **Present**, and then **Start listening**. As they talk, the app listens through the microphone and **bolds and highlights the outline line they're currently on**. The audience can always see where the speaker is, and nobody has to click through each line by hand.

## Mac app (recommended)
A native SwiftUI app lives in `mac/`. It uses Apple's built-in speech recognition, which runs on your Mac when your Mac supports it.

**Download:** open the latest *Mac app* run under the repo's **Actions** tab and download `LiveOutline-mac`. Unzip it and drag **Live Outline** to Applications. The app isn't notarized, so the first time you open it, right-click it and choose **Open**.

**Build it yourself** (macOS 14+ with the Xcode command line tools):
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
node --test            # web matcher
cd mac && swift test   # Swift matcher
```
