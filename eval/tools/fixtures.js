#!/usr/bin/env node
// Writes cross-language fixtures for the Swift tests (mac/Tests/MatcherCoreTests/Fixtures).
// The JavaScript implementations are the reference; Swift must reproduce these outputs exactly.
// Usage: node eval/tools/fixtures.js [--check]
'use strict';
const fs = require('fs');
const path = require('path');
const { render } = require('../../api/_judge-render');
const PROMPTS = require('../../api/_judge-prompt.json');
const { build, speechLines, mulberry32 } = require('./lib');
const { Follower, POLICY, shouldJudge, CADENCE } = require('./follower');
const { MeaningTracker, windowText, DEFAULT_PROFILE, anchorTexts } = require('./meaning');

const OUT = path.join(__dirname, '..', '..', 'mac', 'Tests', 'MatcherCoreTests', 'Fixtures');
const talk = build(JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'talks', 'sleep.json'), 'utf8')));
const files = {};

// 1. Prompt rendering.
const bigItems = Array.from({ length: 30 }, (_, i) => ({ text: `Point number ${i + 1}  with\ttabs`, level: i % 4 === 3 ? 2 : i % 2, cues: i === 5 ? ['alpha', ' beta '] : [] }));
const promptCases = [
  { items: talk.items, current: 0, lines: [] },
  { items: talk.items, current: 3, lines: talk.ticks[40].lines },
  { items: talk.items, current: 5, lines: talk.ticks[120].lines, gists: talk.items.map((it, i) => (i % 3 ? `Gist for ${it.text}` : '')) },
  { items: bigItems, current: 20, lines: [{ ago: 7, text: '  spaced   out\ttext ' }, { ago: 0, text: 'newest 😀 line' }] },
  { items: bigItems, current: 1, lines: [{ ago: 0, text: 'x' }] },
  { items: [{ text: '😀'.repeat(130) + ' café', level: 5, cues: [] }], current: 0, lines: [] },
].map(input => ({ input, ...render(input) }));
files['prompts.json'] = { promptSet: PROMPTS, cases: promptCases.map(c => ({ input: c.input, outlineBlock: c.outlineBlock, dynamicBlock: c.dynamicBlock, prompt: c.prompt, visibleStart: c.visible.start, visibleEnd: c.visible.end })) };

// 2. Speech windows and window text.
const nows = [talk.chunks[5].t, talk.chunks[30].t, talk.chunks[31].t + 0.4, talk.chunks[100].t, talk.duration + 2];
files['speech-windows.json'] = {
  chunks: talk.chunks.map(c => ({ t: c.t, text: c.text })),
  cases: nows.map(now => ({ now, lines: speechLines(talk.chunks, now), short: windowText(talk.chunks, now, 5, 8, 20), long: windowText(talk.chunks, now, 12, 15, 45) })),
};

// 3. Follower decisions for a scripted event stream.
const rand = mulberry32(7);
const f = new Follower(8, POLICY.live);
const events = [];
let t = 0, seq = 0;
for (let i = 0; i < 400; i++) {
  t += 0.2 + rand() * 1.5;
  const r = rand();
  if (r < 0.05) { const p = Math.floor(rand() * 8); f.manual(p, t); events.push({ kind: 'manual', point: p, at: t, current: f.current }); continue; }
  if (r < 0.2) { const p = Math.floor(rand() * 8); const moved = f.keyword(p, t); events.push({ kind: 'keyword', point: p, at: t, moved, current: f.current }); continue; }
  const states = ['same', 'moved', 'moved', 'moved', 'tangent', 'unclear'];
  const confs = ['low', 'medium', 'medium', 'high'];
  const v = { state: states[Math.floor(rand() * states.length)], point: Math.max(0, Math.min(8, f.current + Math.floor(rand() * 5) - 1)), confidence: confs[Math.floor(rand() * confs.length)] };
  const staleSeq = rand() < 0.05;
  const s = staleSeq ? seq : ++seq;
  const askedAt = t - rand() * 2;
  const askedCurrent = rand() < 0.1 ? (f.current + 1) % 8 : f.current;
  const source = rand() < 0.3 ? 'tiny' : 'judge';
  const localSupport = rand() < 0.2;
  const res = f.verdict(v, { seq: s, askedAt, askedCurrent, at: t, localSupport, source });
  events.push({ kind: 'verdict', verdict: v, seq: s, askedAt, askedCurrent, at: t, localSupport, source, moved: !!res.moved, reason: res.reason || null, current: f.current });
}
const schedule = [];
for (let i = 0; i < 200; i++) {
  const a = { now: rand() * 20, lastAskAt: rand() * 20, lastWordAt: rand() * 20, newWords: Math.floor(rand() * 9), inFlight: rand() < 0.2 };
  schedule.push({ ...a, onDevice: shouldJudge(a, CADENCE.onDevice), claude: shouldJudge(a, CADENCE.claude) });
}
files['follower-script.json'] = { count: 8, events, schedule };

// 4. Meaning tracker on synthetic scores.
const n = 7;
const tracker = new MeaningTracker(n, { ...DEFAULT_PROFILE, tangentFloor: 0.3 });
const steps = [];
let cur = 0;
for (let i = 0; i < 120; i++) {
  const target = Math.min(n - 1, Math.floor(i / 18));
  const zs = Array.from({ length: n }, (_, j) => (j === target ? 0.08 : 0) + (rand() - 0.5) * 0.06);
  const zl = Array.from({ length: n }, (_, j) => (j === target ? 0.06 : 0) + (rand() - 0.5) * 0.04);
  const maxLong = 0.2 + rand() * 0.5;
  const st = tracker.update({ zs, zl, maxLong });
  const v = tracker.verdict(cur, st);
  if (v.state === 'moved') cur = v.point;
  steps.push({ zs, zl, maxLong, belief: [...tracker.belief], best: st.best, tangent: st.tangent, verdict: v, current: cur });
}
const anchorItems = [{ text: 'Why sleep matters', level: 0, cues: [] }, { text: 'Memory consolidation', level: 1, cues: ['remember'] }, { text: 'Café & naïve—“quotes”', level: 0, cues: [] }];
files['meaning-script.json'] = {
  profile: { ...DEFAULT_PROFILE, tangentFloor: 0.3 }, count: n, steps,
  anchors: { items: anchorItems, prep: [{ gist: 'Why It’s Important!', examples: ["Don't skip it, OK?"] }, { gist: '', examples: [] }, null], expected: anchorTexts(anchorItems, [{ gist: 'Why It’s Important!', examples: ["Don't skip it, OK?"] }, { gist: '', examples: [] }, null]) },
};

// 5. Closed-loop replay with a scripted judge (identical in Swift: EvalCore ScriptedJudge + runClosedLoop).
// The judge answers from a hash of the newest speech line so both languages can compute it.
function scripted(input) {
  const newest = input.lines.length ? input.lines[input.lines.length - 1].text : '';
  let h = 0; for (const ch of newest) h = (h * 31 + ch.codePointAt(0)) % 1000003;
  const states = ['same', 'moved', 'moved', 'tangent', 'unclear', 'moved', 'same'];
  const state = states[h % states.length];
  const confs = ['low', 'medium', 'high', 'high'];
  const step = [1, 1, 1, 2, -1][h % 5];
  const point = state === 'moved' ? Math.max(0, Math.min(input.items.length - 1, input.current + step)) : input.current;
  return { state, point, confidence: confs[(h >> 3) % confs.length], ms: 1200 };
}
async function closedLoop() {
  const { runJudge, runKeywords } = require('../run');
  const out = [];
  for (const id of ['sleep', 'money']) {
    const t = build(JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'talks', id + '.json'), 'utf8')));
    const r = await runJudge(t, { cadence: CADENCE.claude, ask: async input => scripted(input) });
    const { scoreTimeline } = require('../run');
    const kw = runKeywords(t);
    out.push({ talk: id, moves: r.moves, calls: r.calls, score: scoreTimeline(t, r.moves), keywordMoves: kw.moves, keywordScore: scoreTimeline(t, kw.moves) });
  }
  return out;
}

const check = process.argv.includes('--check');
(async () => {
files['closed-loop.json'] = { latencyMs: 1200, runs: await closedLoop() };
fs.mkdirSync(OUT, { recursive: true });
let stale = 0;
for (const [name, data] of Object.entries(files)) {
  const text = JSON.stringify(data) + '\n';
  const dest = path.join(OUT, name);
  if (check) { if (!fs.existsSync(dest) || fs.readFileSync(dest, 'utf8') !== text) { stale++; console.log(`stale fixture: ${name}`); } }
  else { fs.writeFileSync(dest, text); console.log(`wrote ${name} (${(text.length / 1024).toFixed(0)} KB)`); }
}
if (stale) process.exit(1);
})();
