# Live Outline

A speaker pastes their talk outline, clicks **Present**, and then **Start listening**. As they talk, the app listens through the microphone and **bolds and highlights the outline line they're currently on**. The audience can always see where the speaker is, and nobody has to click through each line by hand.

## Use it
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
node --test
```
