# Live Outline — notes for future changes

## Mac app tutorial must track features
Whenever you add or change a user-facing feature in the Mac app (`mac/`), add or update a page in
`mac/Sources/LiveOutline/Tutorial.swift` (`Tutorial.pages`):
- Give a new page an `addedIn` number **higher than every existing page**. People who update then see
  just that page as "What's new"; new users see every page, in array order (place it where it fits the story).
- Pick a demo: reuse `MiniOutlineDemo` with a short script of `DemoFrame`s (transcript, highlighted line,
  badge, key cap, tags), or add a small new demo view.
- Keep the text short, friendly and in second person ("you").

## Other conventions
- Mac releases publish automatically on every push (see `.github/workflows/mac.yml`); installed apps
  update themselves via Sparkle. Never commit signing secrets.
- The iPhone/web app (root `index.html`, `app.js`) does not use smart following yet; the Claude
  endpoints in `api/` serve the Mac app.
- Tests: `node --test` (web matcher) and `cd mac && swift test` (Swift matcher, runs in CI on macOS).
