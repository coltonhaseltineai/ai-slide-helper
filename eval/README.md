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

## Results (all 10 talks, 68 min, 92 point switches)

| Judge | On the right point | Catch-up p50 / p90 | Missed switches | Wrong jumps / 10 min | Answer time |
|---|---|---|---|---|---|
| Perfect follower (ceiling) | 98.8% | 0 / 0 s | 0 | 0 | – |
| Claude Haiku 4.5 | **74.7%** | 8.5 / 16.0 s | 1 | 0.1 | 0.8 s |
| Claude Sonnet 5 | 72.7% | 8.8 / 12.3 s | 0 | 0.7 | 1.6 s |
| Tiny: bge-small + examples | 60.4% | 9.8 / 18.3 s | 10 | 6.2 | ~10 ms |
| Old app (Haiku, high only, every 6–10 s) | 56.9% | 10.5 / 17.8 s | 5 | 12.2 | 0.8 s |
| Tiny: potion + examples | 44.0% | 11.7 / 21.6 s | 31 | 3.1 | <1 ms |
| Tiny: potion, outline only | 23.2% | 10.4 / 19.4 s | 69 | 3.2 | <1 ms |
| Keywords | 16.7% | 10.3 / 26.7 s | 75 | 8.7 | – |

Dev and test splits agree (Haiku 74.5% / 75.0%). Tiny-model settings were tuned on dev only
(bge-small + examples: 63.7% dev, 55.4% test).

What this says:
- **Claude's interpretation is nearly perfect.** When it says "moved" it is almost always right (0.1 wrong
  jumps per 10 min, 1 missed switch in 92). What it loses is **time**. Its first answer after a switch
  (about 2 s in) is usually still "same" or "unclear", and it commits at the next question. The ~8 s
  median catch-up accounts for nearly all of the gap to the ceiling.
- **Tiny models alone are not good enough.** Even the best one (bge-small, with example sentences) is 14
  points behind Claude and makes 60× more wrong jumps. Without example sentences they are barely better than
  keywords. They are only a fallback for Macs without Apple Intelligence.
- **Apple's on-device model** is asked twice as often (every 1 s, no network), so it can win on speed if
  its interpretation holds up. Measure it on a Mac with Help → Compare Judges.
