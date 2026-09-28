#!/usr/bin/env node
// Developer benchmark: replays the eval talks through each contender and scores how well the highlight follows.
//
//   node eval/run.js [--split dev|test|all] [--only a,b] [--contenders list] [--isolated] [--variant id] [--concurrency N]
//
// Contenders: keywords, oracle, haiku, sonnet, statusquo,
//             tiny:<potion|minilm|bge-small>:<bare|prep>, hybrid:<model>:<prep|bare>:<haiku|sonnet>
// Claude contenders need ANTHROPIC_API_KEY (calls are cached in eval/.cache). Tiny models need EVAL_PYTHON
// pointing at a Python with onnxruntime + tokenizers + numpy (see eval/python/embed.py).
// Latencies here are from this machine straight to the Claude API, not from a Mac through Vercel.
// EVAL_JUDGE=cache: never call the API. Unanswered questions go to .cache/misses.jsonl (and outline preps to
// .cache/prep-misses.jsonl) for Claude subagents to answer via tools/misses.js; repeat until nothing is missing.
// --reference (with --split all) writes results/claude-reference.json for the Mac app's Compare Judges window.
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { build, speechLines, words } = require('./tools/lib');
const { POLICY, CADENCE, Follower, shouldJudge, shouldLocateOld } = require('./tools/follower');
const { MeaningScorer, MeaningTracker, windowText, DEFAULT_PROFILE } = require('./tools/meaning');
const { Matcher } = require('../matcher.js');

const EVAL = __dirname;
const CACHE = path.join(EVAL, '.cache');
const args = process.argv.slice(2);
const flag = (name, dflt) => { const i = args.indexOf('--' + name); return i < 0 ? dflt : (args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : true); };

// ---------- talks ----------
function loadTalks(split, only) {
  const splits = JSON.parse(fs.readFileSync(path.join(EVAL, 'splits.json'), 'utf8'));
  let ids = split === 'all' ? [...splits.dev, ...splits.test] : splits[split];
  if (only) ids = ids.filter(id => only.includes(id));
  return ids.map(id => build(JSON.parse(fs.readFileSync(path.join(EVAL, 'talks', id + '.json'), 'utf8'))));
}

// ---------- Claude (cached) ----------
let judgeLib = null;
const vcacheFile = path.join(CACHE, 'verdicts.jsonl');
const vcache = new Map();
const usedKeys = new Set();   // cached answers this run actually used
const missSeen = new Set();
// Median API latency measured for each model (used for answers produced without the API).
const SIM_MS = { haiku: 800, sonnet: 1590 };
function loadVerdictCache() {
  if (!fs.existsSync(vcacheFile)) return;
  for (const l of fs.readFileSync(vcacheFile, 'utf8').split('\n')) if (l) { const o = JSON.parse(l); vcache.set(o.k, o.v); }
}
async function claudeJudge(model, input, variant, guess) {
  if (!judgeLib) judgeLib = require('../api/_judge');
  const { render } = require('../api/_judge-render');
  const r = render(input, variant);
  const k = crypto.createHash('sha1').update([model, r.promptVersion, r.rules, r.prompt].join('\u0000')).digest('hex');
  if (vcache.has(k)) { usedKeys.add(k); return vcache.get(k); }
  // Subscription mode (EVAL_JUDGE=cache): no API calls. Unanswered questions are written to
  // .cache/misses.jsonl for Claude subagents to answer (eval/tools/misses.js), then the run is repeated.
  if (process.env.EVAL_JUDGE === 'cache') {
    if (!missSeen.has(k)) {
      missSeen.add(k);
      fs.appendFileSync(path.join(CACHE, 'misses.jsonl'), JSON.stringify({ k, model, rules: r.rules, prompt: r.prompt, visible: r.visible, current: input.current }) + '\n');
    }
    // Carry on as if the answer were the guess (from the ground truth), so the next questions asked are the
    // ones the real answers will most likely lead to; the run is repeated until nothing is missing.
    return { ...(guess || { state: 'unclear', point: input.current, confidence: 'low' }), ms: SIM_MS[model], miss: true };
  }
  let last;
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      const t = Date.now();
      const out = await judgeLib.judge(input, { model, variant });
      const v = { state: out.state, point: out.point, confidence: out.confidence, ms: Date.now() - t, usage: out.usage, served: out.model };
      vcache.set(k, v);
      fs.appendFileSync(vcacheFile, JSON.stringify({ k, v }) + '\n');
      return v;
    } catch (e) { last = e; await new Promise(r => setTimeout(r, 1000 * (attempt + 1) + Math.random() * 500)); }
  }
  return { state: 'unclear', point: input.current, confidence: 'low', ms: 0, error: String(last && last.message) };
}

// Subscription mode's stand-in for an unanswered question: what a perfect judge would say at time t.
function speculate(talk, t, input) {
  const ok = acceptableAt(talk, t);
  return ok.includes(input.current) ? { state: 'same', point: input.current, confidence: 'high' } : { state: 'moved', point: ok[0], confidence: 'high' };
}

async function prepFor(talk) {
  // Keyed by the outline and prep rules, so edited talks never reuse a stale prep.
  const { renderPrep } = require('../api/_judge-render');
  const r = renderPrep(talk.items);
  const key = crypto.createHash('sha1').update(r.rules + '\n' + r.prompt).digest('hex').slice(0, 12);
  const f = path.join(CACHE, `prep-${talk.id}-${key}.json`);
  if (fs.existsSync(f)) return JSON.parse(fs.readFileSync(f, 'utf8'));
  if (process.env.EVAL_JUDGE === 'cache') {
    // Subscription mode: record the request; eval/tools/misses.js prep-batches hands it to Claude.
    fs.mkdirSync(CACHE, { recursive: true });
    const missFile = path.join(CACHE, 'prep-misses.jsonl');
    const seen = fs.existsSync(missFile) ? fs.readFileSync(missFile, 'utf8') : '';
    if (!seen.includes(`"${talk.id}-${key}"`)) {
      fs.appendFileSync(missFile, JSON.stringify({ k: `${talk.id}-${key}`, file: path.basename(f), count: talk.items.length, rules: r.rules, prompt: r.prompt }) + '\n');
    }
    return null;
  }
  if (!judgeLib) judgeLib = require('../api/_judge');
  const out = await judgeLib.prep(talk.items, { model: 'sonnet' });
  fs.writeFileSync(f, JSON.stringify(out.points));
  return out.points;
}

// ---------- scoring ----------
function acceptableAt(talk, t) {
  for (const s of talk.truth) if (t < s.end) return [s.index, ...s.accept];
  const s = talk.truth[talk.truth.length - 1];
  return [s.index, ...s.accept];
}

// moves: [{t, to}] with the highlight starting at 0.
function scoreTimeline(talk, moves) {
  const dt = 0.25;
  let on = 0, total = 0, mi = 0, cur = 0;
  for (let t = 0; t < talk.duration; t += dt) {
    while (mi < moves.length && moves[mi].t <= t) cur = moves[mi++].to;
    total++;
    if (acceptableAt(talk, t).includes(cur)) on++;
  }
  const hl = x => { let c = 0; for (const m of moves) { if (m.t <= x) c = m.to; else break; } return c; };
  // Switch lag: for each segment that starts a new point, time until the highlight reaches it.
  const lags = [], missed = [];
  talk.truth.forEach((s, i) => {
    if (i === 0) return;
    const prev = talk.truth[i - 1];
    if (!['on', 'goback', 'skip', 'resume'].includes(s.kind)) return;
    if ([prev.index, ...prev.accept].includes(s.index)) return;
    let end = talk.duration;
    for (let j = i + 1; j < talk.truth.length; j++) if (talk.truth[j].index !== s.index && !talk.truth[j].accept.includes(s.index)) { end = talk.truth[j].start; break; }
    if (hl(s.start) === s.index) { lags.push(0); return; }
    const hit = moves.find(m => m.t >= s.start && m.t < end && m.to === s.index);
    if (hit) lags.push(hit.t - s.start); else missed.push(s.index);
  });
  let wrong = 0, flicker = 0;
  moves.forEach((m, i) => {
    if (!acceptableAt(talk, m.t + 0.01).includes(m.to)) wrong++;
    const prevTo = i > 0 ? moves[i - 1].to : 0;
    const nxt = moves[i + 1];
    if (nxt && nxt.t - m.t <= 5 && nxt.to === prevTo) flicker++;
  });
  return { onCorrect: on / total, lags, missed: missed.length, switches: lags.length + missed.length, wrongMoves: wrong, flicker, moves: moves.length, minutes: talk.duration / 60 };
}

// ---------- contenders ----------
const nextChunkIndexAt = (talk, t) => { let i = 0; while (i < talk.chunks.length && talk.chunks[i].t <= t) i++; return i; };

function runKeywords(talk) {
  const m = new Matcher(talk.items.map((it, i) => ({ ...it, id: i })));
  const moves = [];
  for (const c of talk.chunks) { const before = m.current; m.feed(c.text); if (m.current !== before) moves.push({ t: c.t, to: m.current }); }
  return { moves, calls: 0 };
}

// A judge contender in closed loop: asked on a cadence, answers arrive after their latency.
async function runJudge(talk, { ask, cadence, policy = POLICY.live, statusQuo = false, tiny = null }) {
  const f = new Follower(talk.items.length, policy);
  const moves = [];
  let seq = 0, tinySeq = 0, lastAskAt = -1e9, lastWordAt = 0, newWords = 0, inFlight = null, calls = 0, lastConfidentAt = 0;
  const latencies = [], errors = [];
  const kw = statusQuo ? new Matcher(talk.items.map((it, i) => ({ ...it, id: i }))) : null;
  const apply = (res, t) => { if (res.moved) { moves.push({ t, to: f.current }); if (tiny) tiny.tracker.reset(f.current); } };

  const flush = t => {  // deliver an answer that has arrived by time t
    if (inFlight && inFlight.arrive <= t) {
      const a = inFlight; inFlight = null;
      const res = f.verdict(a.v, { seq: a.seq, askedAt: a.askedAt, askedCurrent: a.askedCurrent, at: a.arrive, localSupport: a.localSupport });
      if (res.moved || a.v.state === 'same') lastConfidentAt = a.arrive;
      apply(res, a.arrive);
    }
  };

  for (let ci = 0; ci < talk.chunks.length; ci++) {
    const c = talk.chunks[ci];
    flush(c.t);
    newWords += words(c.text).length; lastWordAt = c.t;
    let tinyVerdict = null;
    if (kw) {
      const before = kw.current; kw.feed(c.text);
      if (kw.current !== before && f.keyword(kw.current, c.t)) { moves.push({ t: c.t, to: f.current }); lastConfidentAt = c.t; }
      else if (kw.current !== f.current) kw.setCurrent(f.current);
    }
    if (tiny) {
      const st = tiny.stateAt(ci);
      tinyVerdict = tiny.tracker.verdict(f.current, st);
      apply(f.verdict(tinyVerdict, { seq: ++tinySeq, askedAt: c.t, askedCurrent: f.current, at: c.t, source: 'tiny' }), c.t);
    }
    if (!ask) continue;
    // Ask on the cadence; in hybrid mode only when the tiny model is unsure.
    const wantsHelp = !tiny || (tinyVerdict && (tinyVerdict.state === 'unclear' || (tinyVerdict.state === 'moved' && tinyVerdict.confidence !== 'high')));
    const due = statusQuo
      ? shouldLocateOld({ now: c.t, lastCallAt: lastAskAt, lastConfidentAt, newWords, inFlight: !!inFlight })
      : wantsHelp && shouldJudge({ now: c.t, lastAskAt, lastWordAt, newWords, inFlight: !!inFlight }, cadence);
    if (!due) continue;
    const input = { items: talk.items, current: f.current, lines: speechLines(talk.chunks, c.t) };
    const v = await ask(input, c.t);
    calls++;
    if (v.error) errors.push(v.error);
    const latency = Math.min(v.ms / 1000, cadence.timeout);
    latencies.push(v.ms / 1000);
    lastAskAt = c.t; newWords = 0;
    const timedOut = v.ms / 1000 > cadence.timeout;
    const localSupport = !!(tiny && tiny.top2At(ci).includes(v.point));
    inFlight = { v: timedOut ? { state: 'unclear', point: f.current, confidence: 'low' } : v, seq: ++seq, askedAt: c.t, askedCurrent: f.current, arrive: c.t + latency, localSupport };
  }
  flush(Infinity);
  return { moves, calls, latencies, errors };
}

function tinyRunner(talk, model, anchors, prep, profile, scorerCache) {
  const key = `${talk.id}|${model}|${anchors}`;
  let pre = scorerCache.get(key);
  if (!pre) {
    const scorer = new MeaningScorer(model, talk.items, anchors === 'prep' ? prep : null);
    const shorts = talk.chunks.map(c => windowText(talk.chunks, c.t, 5, 8, 20));
    const longs = talk.chunks.map(c => windowText(talk.chunks, c.t, 12, 15, 45));
    const { embedAll } = require('./tools/embed');
    const vs = embedAll(model, shorts), vl = embedAll(model, longs);
    pre = talk.chunks.map((_, i) => scorer.score(vs[i], vl[i]));
    scorerCache.set(key, pre);
  }
  const tracker = new MeaningTracker(talk.items.length, profile);
  const states = [];
  return {
    ms: model === 'potion' ? 0.1 : 8,
    tracker,
    stateAt(ci) { const s = tracker.update(pre[ci]); states[ci] = s; return s; },
    top2At(ci) { const b = states[ci] ? states[ci].belief : []; return [...b.keys()].sort((x, y) => b[y] - b[x]).slice(0, 2); },
  };
}

// ---------- isolated per-tick accuracy (judges only; the shown point is always the ideal one) ----------
async function isolated(talks, model, variant, concurrency) {
  const jobs = [];
  for (const t of talks) t.ticks.forEach((tk, i) => { if (i % 2 === 0 || tk.transition) jobs.push({ t, tk }); });
  const out = [];
  let k = 0;
  await Promise.all(Array.from({ length: concurrency }, async () => {
    while (k < jobs.length) {
      const { t, tk } = jobs[k++];
      const v = await claudeJudge(model, { items: t.items, current: tk.current, lines: tk.lines }, variant);
      const eff = v.state === 'moved' ? v.point : tk.current;
      out.push({ talk: t.id, kind: tk.kind, transition: tk.transition, ok: tk.accept.includes(eff), moved: v.state === 'moved', v, ms: v.ms });
    }
  }));
  const pct = (a, b) => (b ? (100 * a / b).toFixed(1) : '-');
  const trans = out.filter(o => o.transition), stay = out.filter(o => !o.transition);
  const byKind = {};
  for (const o of out) { const b = byKind[o.kind] || (byKind[o.kind] = [0, 0]); b[0] += o.ok; b[1]++; }
  return {
    ticks: out.length, accuracy: pct(out.filter(o => o.ok).length, out.length),
    moveRecall: pct(trans.filter(o => o.ok).length, trans.length),
    stayAccuracy: pct(stay.filter(o => o.ok).length, stay.length),
    byKind: Object.fromEntries(Object.entries(byKind).map(([k, [a, b]]) => [k, `${pct(a, b)}% of ${b}`])),
    errors: out.filter(o => o.v.error).length,
  };
}

// ---------- main ----------
function summarize(name, per) {
  const lags = per.flatMap(p => p.score.lags).sort((a, b) => a - b);
  const q = x => (lags.length ? lags[Math.min(lags.length - 1, Math.floor(x * lags.length))] : NaN);
  const minutes = per.reduce((a, p) => a + p.score.minutes, 0);
  const sw = per.reduce((a, p) => a + p.score.switches, 0), missed = per.reduce((a, p) => a + p.score.missed, 0);
  const lat = per.flatMap(p => p.latencies || []).sort((a, b) => a - b);
  const lq = x => (lat.length ? lat[Math.min(lat.length - 1, Math.floor(x * lat.length))] : NaN);
  const calls = per.reduce((a, p) => a + (p.calls || 0), 0);
  return {
    contender: name,
    onCorrect: +(100 * per.reduce((a, p) => a + p.score.onCorrect * p.score.minutes, 0) / minutes).toFixed(1),
    lagP50: +q(0.5).toFixed(1), lagP90: +q(0.9).toFixed(1), missedSwitches: `${missed}/${sw}`,
    wrongPer10: +(10 * per.reduce((a, p) => a + p.score.wrongMoves, 0) / minutes).toFixed(1),
    flickerPer10: +(10 * per.reduce((a, p) => a + p.score.flicker, 0) / minutes).toFixed(1),
    callsPerMin: +(calls / minutes).toFixed(1),
    latP50: +lq(0.5).toFixed(2), latP90: +lq(0.9).toFixed(2),
    errors: per.reduce((a, p) => a + (p.errors ? p.errors.length : 0), 0),
  };
}

async function main() {
  const split = flag('split', 'dev');
  const only = flag('only', null);
  const talks = loadTalks(split, only ? only.split(',') : null);
  const variant = flag('variant', undefined);
  const concurrency = +flag('concurrency', 6);
  const contenders = String(flag('contenders', 'keywords,oracle,tiny:minilm:prep,haiku')).split(',');
  const profiles = fs.existsSync(path.join(EVAL, 'profiles.json')) ? JSON.parse(fs.readFileSync(path.join(EVAL, 'profiles.json'), 'utf8')) : {};
  loadVerdictCache();
  fs.mkdirSync(CACHE, { recursive: true });
  console.log(`talks (${split}): ${talks.map(t => t.id).join(', ')} — ${(talks.reduce((a, t) => a + t.duration, 0) / 60).toFixed(1)} min`);

  if (flag('isolated', false)) {
    for (const m of contenders.filter(c => c === 'haiku' || c === 'sonnet')) {
      console.log(`isolated ${m}:`, JSON.stringify(await isolated(talks, m, variant, concurrency), null, 1));
    }
    return;
  }

  const needsPrep = contenders.some(c => c.includes(':prep'));
  const preps = {};
  if (needsPrep) for (const t of talks) preps[t.id] = await prepFor(t);
  const missingPrep = talks.filter(t => needsPrep && !preps[t.id]).map(t => t.id);
  if (missingPrep.length) {
    console.log(`prep missing for ${missingPrep.join(', ')} (see .cache/prep-misses.jsonl) — skipping :prep contenders this run.`);
    contenders.splice(0, contenders.length, ...contenders.filter(c => !c.includes(':prep')));
  }
  const scorerCache = new Map();
  const rows = [];
  const reference = {};
  for (const name of contenders) {
    const [kind, model, anchors, judgeModel] = name.split(':');
    const per = await Promise.all(talks.map(async talk => {
      let r;
      if (kind === 'keywords') r = runKeywords(talk);
      else if (kind === 'oracle') {
        // The highlight is always on the truth, instantly: the ceiling for every metric.
        const moves = []; let cur = 0;
        for (const s of talk.truth) if (![s.index, ...s.accept].includes(cur)) { cur = s.index; moves.push({ t: s.start, to: cur }); }
        r = { moves, calls: 0 };
      } else if (kind === 'haiku' || kind === 'sonnet') {
        // Optional experiment knobs: --min-gap S, --medium-now (medium next-point moves need no second vote).
        const cadence = { ...CADENCE.claude, minGap: +flag('min-gap', CADENCE.claude.minGap), minNewWords: +flag('min-words', CADENCE.claude.minNewWords) };
        const policy = flag('medium-now', false) ? { ...POLICY.live, mediumAgreeWithin: 1e9, mediumNow: true } : POLICY.live;
        r = await runJudge(talk, { cadence, policy, ask: (input, t) => claudeJudge(kind, input, variant, speculate(talk, t, input)) });
      } else if (kind === 'statusquo') {
        r = await runJudge(talk, { cadence: { ...CADENCE.claude, timeout: 30 }, policy: POLICY.statusQuo, statusQuo: true, ask: (input, t) => claudeJudge('haiku', input, variant, speculate(talk, t, input)) });
      } else if (kind === 'tiny') {
        const tiny = tinyRunner(talk, model, anchors || 'bare', preps[talk.id], profiles[`${model}:${anchors || 'bare'}`] || DEFAULT_PROFILE, scorerCache);
        r = await runJudge(talk, { cadence: CADENCE.onDevice, tiny });
      } else if (kind === 'hybrid') {
        const tiny = tinyRunner(talk, model, anchors || 'prep', preps[talk.id], profiles[`${model}:${anchors || 'prep'}`] || DEFAULT_PROFILE, scorerCache);
        const jm = judgeModel || 'haiku';
        r = await runJudge(talk, { cadence: { ...CADENCE.onDevice, minGap: 3, timeout: 4 }, tiny, ask: (input, t) => claudeJudge(jm, input, variant, speculate(talk, t, input)) });
      } else throw new Error(`unknown contender ${name}`);
      return { talk: talk.id, ...r, score: scoreTimeline(talk, r.moves) };
    }));
    if (['haiku', 'sonnet'].includes(name)) reference[name] = Object.fromEntries(per.map(p => [p.talk, {
      moves: p.moves.map(m => ({ t: +m.t.toFixed(2), to: m.to })), calls: p.calls,
      latencies: (p.latencies || []).map(x => +x.toFixed(2)), errors: (p.errors || []).length,
    }]));
    const row = summarize(name, per);
    row.perTalk = Object.fromEntries(per.map(p => [p.talk, +(100 * p.score.onCorrect).toFixed(0)]));
    rows.push(row);
    console.log(JSON.stringify(row));
  }
  if (missSeen.size) console.log(`\n${missSeen.size} judge questions still need answers (see .cache/misses.jsonl) — results above are incomplete.`);
  // --reference: record Claude's moves per talk for the Mac app's Compare Judges window (re-scored there).
  if (flag('reference', false)) {
    if (missSeen.size || split !== 'all') throw new Error('--reference needs --split all and no missing answers');
    const sources = [...usedKeys].map(k => vcache.get(k)).filter(Boolean).reduce((a, v) => { a[v.source || 'api'] = (a[v.source || 'api'] || 0) + 1; return a; }, {});
    const out = {
      note: 'Claude judge answers on the benchmark talks, replayed in closed loop. Answers came from the Claude API and, ' +
        'after its credits ran out, from Claude subagents on a subscription; answer times are the API medians measured earlier ' +
        '(Haiku 0.8 s, Sonnet 1.59 s). Moves are re-scored by the app.',
      promptVersion: require('../api/_judge-prompt.json').current, answers: sources, contenders: reference,
    };
    fs.writeFileSync(path.join(EVAL, 'results', 'claude-reference.json'), JSON.stringify(out));
    console.log('wrote results/claude-reference.json');
  }
  fs.mkdirSync(path.join(EVAL, 'results'), { recursive: true });
  if (missSeen.size) return printTable(rows);   // incomplete: don't save
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  fs.writeFileSync(path.join(EVAL, 'results', `${split}-${stamp}.json`), JSON.stringify({ split, variant: variant || 'current', talks: talks.map(t => t.id), rows }, null, 1));
  printTable(rows);
}

function printTable(rows) {
  console.log('\ncontender'.padEnd(26) + 'onCorrect  lagP50  lagP90  missed  wrong/10m  flicker/10m  calls/min  lat p50/p90');
  for (const r of rows) console.log(r.contender.padEnd(26) + String(r.onCorrect + '%').padEnd(11) + String(r.lagP50 + 's').padEnd(8) + String(r.lagP90 + 's').padEnd(8) + r.missedSwitches.padEnd(8) + String(r.wrongPer10).padEnd(11) + String(r.flickerPer10).padEnd(13) + String(r.callsPerMin).padEnd(11) + `${r.latP50}/${r.latP90}s`);
}

if (require.main === module) main().catch(e => { console.error(e); process.exit(1); });
module.exports = { loadVerdictCache, loadTalks, scoreTimeline, runKeywords, runJudge, tinyRunner, summarize, claudeJudge, prepFor };
