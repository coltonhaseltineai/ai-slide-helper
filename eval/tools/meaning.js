// Tiny-model meaning follower: compares recent speech with per-point "anchors" (the point's text,
// plus a gist and example sentences written from the outline) and keeps a belief over points.
// JavaScript twin of mac/Sources/MatcherCore/Meaning.swift.
'use strict';

const { asrText, words } = require('./lib');
const { embedAll, cosine } = require('./embed');

const DEFAULT_PROFILE = {
  temperature: 0.05,     // softmax temperature over normalised scores
  alpha: 0.5,            // how strongly one window's evidence moves the belief
  stay: 0.90, next: 0.07, skip2: 0.015, back1: 0.01, other: 0.005,
  shortWeight: 0.35,     // blend of the ~5 s and ~12 s windows
  tangentFloor: -1,      // hold when the best raw similarity is below this
  highBelief: 0.7, highMargin: 0.3, midBelief: 0.5, midMargin: 0.15,
};

// Anchor texts for each point: its path and cues, then (optionally) gist and examples.
function anchorTexts(items, prep) {
  return items.map((it, i) => {
    let parent = '';
    for (let j = i - 1; j >= 0; j--) if (items[j].level < it.level) { parent = items[j].text; break; }
    const base = [parent, it.text, ...(it.cues || [])].filter(Boolean).join(' ');
    const out = [asrText(base)];
    if (prep && prep[i]) {
      if (prep[i].gist) out.push(asrText(prep[i].gist));
      for (const e of prep[i].examples || []) out.push(asrText(e));
    }
    return out.filter(t => words(t).length);
  });
}

// Recent speech as text, by time, clamped to a word range.
function windowText(chunks, now, seconds, minWords, maxWords) {
  let ws = [];
  for (let i = chunks.length - 1; i >= 0 && chunks[i].t > now - 60; i--) {
    if (chunks[i].t > now + 1e-9) continue;
    const w = words(chunks[i].text);
    if (chunks[i].t < now - seconds && ws.length >= minWords) break;
    ws = w.concat(ws);
    if (ws.length >= maxWords) break;
  }
  return ws.slice(-maxWords).join(' ');
}

class MeaningScorer {
  constructor(model, items, prep) {
    this.model = model;
    this.anchors = anchorTexts(items, prep);
    const flat = this.anchors.flat();
    const vecs = embedAll(model, flat);
    let k = 0;
    this.vectors = this.anchors.map(a => a.map(() => vecs[k++]));
  }

  // Raw per-point score: mean of the top-2 anchor similarities.
  raw(vec) {
    return this.vectors.map(vs => {
      const s = vs.map(v => cosine(vec, v)).sort((a, b) => b - a);
      return s.length > 1 ? (s[0] + s[1]) / 2 : s[0];
    });
  }

  score(shortVec, longVec) {
    const rs = this.raw(shortVec), rl = this.raw(longVec);
    const med = a => { const s = [...a].sort((x, y) => x - y); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
    const ms = med(rs), ml = med(rl);
    return { zs: rs.map(x => x - ms), zl: rl.map(x => x - ml), maxLong: Math.max(...rl) };
  }
}

class MeaningTracker {
  constructor(count, profile = DEFAULT_PROFILE, start = 0) {
    this.n = count; this.p = { ...DEFAULT_PROFILE, ...profile };
    this.belief = Array.from({ length: count }, (_, i) => (i === start ? 1 : 0));
  }

  reset(point) { this.belief = this.belief.map((_, i) => (i === point ? 1 : 0)); }

  transition(i, j) {
    const d = j - i, p = this.p;
    return d === 0 ? p.stay : d === 1 ? p.next : d === 2 ? p.skip2 : d === -1 ? p.back1 : p.other;
  }

  // Update with one scored window; returns {tangent, best, belief}.
  update(scores) {
    const p = this.p;
    const tangent = scores.maxLong < p.tangentFloor;
    let like;
    if (tangent) like = this.belief.map(() => 1);
    else {
      const z = scores.zs.map((s, i) => p.shortWeight * s + (1 - p.shortWeight) * scores.zl[i]);
      const mx = Math.max(...z);
      const e = z.map(x => Math.exp((x - mx) / p.temperature));
      const sum = e.reduce((a, b) => a + b, 0);
      like = e.map(x => Math.pow(x / sum, p.alpha));
    }
    const prior = this.belief.map((_, j) => this.belief.reduce((acc, b, i) => acc + b * this.transition(i, j), 0));
    let post = prior.map((x, j) => x * like[j]);
    const tot = post.reduce((a, b) => a + b, 0) || 1;
    this.belief = post.map(x => x / tot);
    let best = 0;
    this.belief.forEach((b, i) => { if (b > this.belief[best]) best = i; });
    return { tangent, best, belief: this.belief };
  }

  // Turns the belief into a judge-style verdict relative to the shown point.
  verdict(current, state) {
    const p = this.p;
    if (state.tangent) return { state: 'tangent', point: current, confidence: 'medium' };
    const b = this.belief, best = state.best;
    if (best === current) return { state: 'same', point: current, confidence: b[best] >= p.highBelief ? 'high' : 'medium' };
    const margin = b[best] - b[current];
    if (b[best] >= p.highBelief && margin >= p.highMargin) return { state: 'moved', point: best, confidence: 'high' };
    if (b[best] >= p.midBelief && margin >= p.midMargin) return { state: 'moved', point: best, confidence: 'medium' };
    return { state: 'unclear', point: current, confidence: 'low' };
  }
}

module.exports = { DEFAULT_PROFILE, anchorTexts, windowText, MeaningScorer, MeaningTracker };
