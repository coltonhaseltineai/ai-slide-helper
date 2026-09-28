// Shared helpers for the Live Outline evaluation set.
// Talks are authored as segments with ground-truth labels; build() turns them into
// timed speech-recognition-style chunks and decision ticks that every judge is scored on.
'use strict';

const { parseOutline, tokenize } = require('../../matcher.js');

const BUILDER_VERSION = 1;
const KINDS = ['on', 'transition', 'tangent', 'callback', 'preview', 'filler', 'goback', 'skip', 'resume'];

// Deterministic PRNG so builds are reproducible.
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function seedFor(id) {
  let h = 2166136261;
  for (const ch of id) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

// What speech-to-text gives us: lowercase words, no punctuation (addsPunctuation = false).
function asrText(s) {
  return s.toLowerCase()
    .replace(/[’']/g, "'")
    .replace(/[^a-z0-9' ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function words(s) { return s.split(/\s+/).filter(Boolean); }

// Groups recent chunks into lines of at least `minLineWords` words, newest last.
// Must stay byte-for-byte identical to MatcherCore/SpeechWindow.swift.
function speechLines(chunks, now, { seconds = 20, minLineWords = 8, maxLines = 12, newestMaxWords = 60 } = {}) {
  const recent = chunks.filter(c => c.t <= now + 1e-9 && c.t > now - seconds);
  const lines = [];
  let buf = [], lastT = 0;
  for (const c of recent) {
    buf.push(...words(c.text));
    lastT = c.t;
    if (buf.length >= minLineWords) {
      lines.push({ ago: Math.max(0, Math.round(now - lastT)), text: buf.join(' ') });
      buf = [];
    }
  }
  if (buf.length) lines.push({ ago: Math.max(0, Math.round(now - lastT)), text: buf.join(' ') });
  const kept = lines.slice(-maxLines);
  if (kept.length) {
    const last = kept[kept.length - 1];
    const w = words(last.text);
    if (w.length > newestMaxWords) last.text = w.slice(-newestMaxWords).join(' ');
  }
  return kept;
}

function build(talk) {
  const rand = mulberry32(seedFor(talk.id));
  const items = parseOutline(talk.outlineText).map(it => ({ text: it.text, level: it.level, cues: it.cues }));
  const wpm = (talk.speaker && talk.speaker.wpm) || 150;
  const chunks = [];
  const truth = [];   // [{start, end, index, accept, kind}]
  let t = 0;
  talk.segments.forEach((seg, si) => {
    const segWpm = wpm * (0.85 + rand() * 0.3);
    const secPerWord = 60 / segWpm;
    const ws = words(asrText(seg.say));
    const start = t;
    let i = 0;
    while (i < ws.length) {
      const n = Math.min(ws.length - i, 3 + Math.floor(rand() * 6)); // 3-8 words per settled chunk
      const group = [];
      for (let k = 0; k < n; k++) {
        const w = ws[i + k];
        if (rand() < 0.02 && ws.length > 4) continue;               // occasional dropped word (ASR noise)
        group.push(w);
      }
      i += n;
      t += n * secPerWord;
      if (group.length) chunks.push({ t: +t.toFixed(3), text: group.join(' '), seg: si });
    }
    truth.push({ start: +start.toFixed(3), end: +t.toFixed(3), index: seg.truth, accept: seg.accept || [], kind: seg.kind });
    t += (seg.pauseAfter != null ? seg.pauseAfter : 0.25 + rand() * 0.35);
  });

  // A decision tick after every chunk. `current` is what an ideal follower shows just before
  // this chunk: the truth of the previous tick. `transition` marks the first tick of a new point.
  const ticks = [];
  let prevTruth = talk.segments[0].truth;
  chunks.forEach((c, ci) => {
    const seg = talk.segments[c.seg];
    const segTruth = seg.truth;
    const accept = [...new Set([segTruth, ...(seg.accept || [])])];
    const current = prevTruth;
    ticks.push({
      i: ci, t: c.t, seg: c.seg, kind: seg.kind,
      current, truth: segTruth, accept,
      transition: !accept.includes(current),
      lines: speechLines(chunks, c.t),
    });
    if (!(seg.accept || []).length || accept.includes(prevTruth) === false) prevTruth = segTruth;
  });

  return {
    schema: 'live-outline-built/1', builderVersion: BUILDER_VERSION,
    id: talk.id, title: talk.title, tier: talk.tier,
    items, confusable: talk.confusable || [],
    duration: +t.toFixed(3), chunks, truth, ticks,
  };
}

// Truth at time `x` (seconds) for closed-loop scoring.
function truthAt(built, x) {
  for (const s of built.truth) if (x < s.end) return s;
  return built.truth[built.truth.length - 1];
}

module.exports = { BUILDER_VERSION, KINDS, mulberry32, seedFor, asrText, words, speechLines, build, truthAt, parseOutline, tokenize };
