# Live Outline benchmark

Does the highlight follow the speaker when they **don't say the outline's words**? These 10 practice talks
were written to be hard in the ways real speakers are: paraphrase, rambling, side stories, "like I said
earlier", "we'll get to that later", filler, going back, and skipping ahead. Each spoken segment is labelled
with the point the highlight *should* show, and those labels were audited adversarially.

- `talks/<id>.json`: the source talks (outline and labelled segments). `node eval/tools/lint.js` checks the
  quotas: at least 2 tangents, callbacks and previews, a go-back, a skip, and little word overlap with the outline.
- `built/<id>.json`: timed speech-to-text-style chunks (`node eval/tools/build.js`, seeded). The Mac app ships these.
- `splits.json`: 6 dev talks, used to tune the tiny model, and 4 test talks.
- `run.js`: closed-loop replay. Speech arrives chunk by chunk, each judge is asked on its real cadence,
  answers land after their latency, and the app's commit policy (`tools/follower.js`) moves the highlight.
  The same logic runs in Swift (`mac/Sources/EvalCore`), and shared fixtures keep the two identical.

## Metrics
- **On the right point**: share of the talk (sampled every 0.25 s) where the highlight shows an acceptable point.
- **Catch-up**: seconds from the start of a new point until the highlight gets there (typical p50, slow p90).
- **Missed switches**: new points the highlight never reached before the speaker moved on.
- **Wrong jumps / 10 min**: moves to a point the speaker wasn't on.
- **Answer time**: judge latency.

## Contenders
- `keywords`: the original word matcher.
- `tiny:<model>:<bare|prep>`: a small sentence-embedding model. It compares recent speech with anchors made
  from the outline (`bare`), plus a gist and 6 example sentences per point written from the outline only (`prep`).
- `haiku`, `sonnet`: Claude as the judge (`api/_judge-prompt.json`), asked every ~2 s.
- `statusquo`: the app before this change (Haiku, high confidence only, every 6–10 s).
- `oracle`: always right, instantly (the ceiling; not quite 100% because of point boundaries).
- Apple's on-device model can only run on a Mac: use **Help → Compare Judges** in the app.

## Claude answers without API credits
With `EVAL_JUDGE=cache`, no API calls are made. Unanswered questions are written to `.cache/misses.jsonl`,
and `tools/misses.js batch-files` splits them into shuffled batches for Claude subagents (Haiku or Sonnet)
to answer. `ingest-files` adds the answers to the cache. Repeat until the run reports nothing missing.
Until then, unanswered questions are stood in for by the ground truth, so the next round asks the questions
the real answers will most likely lead to.

Caveats: a subagent answers ~30 unrelated questions in one context, not one API call each. Its answer
time is the median measured earlier on the API (Haiku 0.8 s, Sonnet 1.6 s), not measured live.
