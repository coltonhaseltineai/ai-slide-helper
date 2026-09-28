# Live Outline — notes for future changes

## Mac app tutorial must track features
Whenever you add or change a user-facing feature in the Mac app (`mac/`), add or update a page in
`mac/Sources/LiveOutline/Tutorial.swift` (`Tutorial.pages`):
- Give a new page an `addedIn` number **higher than every existing page**. People who update then see
  just that page as "What's new"; new users see every page, in array order (place it where it fits the story).
- Pick a demo: reuse `MiniOutlineDemo` with a short script of `DemoFrame`s (transcript, highlighted line,
  badge, key cap), or add a small new demo view. The next new page needs `addedIn` 15 or higher.
- Keep the text short, friendly and in second person ("you").

## Following by meaning
- Nothing is learned or saved from speech. Don't add learned words or phrases back. Per-point examples
  for the tiny model are written from the outline only and kept in memory.
- The judge prompt lives in `api/_judge-prompt.json` and is rendered by `api/_judge-render.js`. Its Swift twin,
  `mac/Sources/MatcherCore/JudgePrompt.swift`, must stay byte-identical, and so must `Follower`, `SpeechWindow`
  and `Meaning`. After changing either side, run `node eval/tools/fixtures.js` and both test suites.
- Benchmark: `eval/` (talks, `run.js`, `tools/`). After editing a talk, run `node eval/tools/build.js`.
  Claude answers are cached in `eval/.cache`. Set `EVAL_JUDGE=cache` to collect unanswered questions for
  subagents instead of calling the API (`eval/tools/misses.js`).
- Ship server changes (`api/`) before the app release that needs them.

## Other conventions
- Mac releases publish automatically on every push (see `.github/workflows/mac.yml`); installed apps
  update themselves via Sparkle. Put `[no release]` in a commit message to build and test without publishing.
  Never commit signing secrets.
- CI builds with Xcode 26.4+ on macos-26. FoundationModels must stay weak-linked (`scripts/check-weak-link.sh`),
  and the release job runs `LiveOutline --self-test` on macOS 15 to prove the app still opens there.
- The iPhone/web app (root `index.html`, `app.js`) does not follow by meaning yet; the endpoints in `api/`
  serve the Mac app.
- Tests: `node --test` and `cd mac && swift test` (runs in CI on macOS).
