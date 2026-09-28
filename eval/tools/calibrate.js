#!/usr/bin/env node
// Tunes a tiny model's follower profile on the dev split (random search), writes eval/profiles.json.
// Usage: node eval/tools/calibrate.js <model> <bare|prep> [--trials 400]
'use strict';
const fs = require('fs');
const path = require('path');
const { loadTalks, tinyRunner, runJudge, scoreTimeline, summarize, prepFor } = require('../run');
const { CADENCE } = require('./follower');
const { DEFAULT_PROFILE, windowText } = require('./meaning');
const { mulberry32 } = require('./lib');

const [model, anchors = 'prep'] = process.argv.slice(2);
const trialsArg = process.argv.indexOf('--trials');
const TRIALS = trialsArg > 0 ? +process.argv[trialsArg + 1] : 400;
const PROFILES = path.join(__dirname, '..', 'profiles.json');

function objective(row) { return row.onCorrect - 1.0 * row.wrongPer10 - 0.3 * (isNaN(row.lagP50) ? 30 : row.lagP50); }

(async () => {
  const talks = loadTalks('dev');
  const preps = {};
  if (anchors === 'prep') for (const t of talks) preps[t.id] = await prepFor(t);
  const cache = new Map();
  // Distribution of the best long-window similarity, for tangent-floor candidates.
  const maxes = [];
  for (const t of talks) { const r = tinyRunner(t, model, anchors, preps[t.id], DEFAULT_PROFILE, cache); }
  for (const v of cache.values()) for (const s of v) maxes.push(s.maxLong);
  maxes.sort((a, b) => a - b);
  const pctl = q => maxes[Math.floor(q * (maxes.length - 1))];
  const floors = [-1, pctl(0.03), pctl(0.07), pctl(0.12)];

  const rand = mulberry32(12345);
  const pick = a => a[Math.floor(rand() * a.length)];
  const evalProfile = async prof => {
    const per = [];
    for (const t of talks) {
      const tiny = tinyRunner(t, model, anchors, preps[t.id], prof, cache);
      const r = await runJudge(t, { cadence: CADENCE.onDevice, tiny });
      per.push({ ...r, score: scoreTimeline(t, r.moves) });
    }
    return summarize(`${model}:${anchors}`, per);
  };
  let best = { prof: DEFAULT_PROFILE, row: await evalProfile(DEFAULT_PROFILE) };
  best.obj = objective(best.row);
  console.log('default', JSON.stringify(best.row));
  for (let i = 0; i < TRIALS; i++) {
    const [stay, next] = pick([[0.9, 0.07], [0.85, 0.11], [0.8, 0.15], [0.7, 0.22], [0.6, 0.3]]);
    const prof = {
      temperature: pick([0.005, 0.01, 0.02, 0.03, 0.05, 0.08]),
      alpha: pick([0.3, 0.5, 0.7, 1.0, 1.5]),
      stay, next, skip2: 0.015, back1: 0.01, other: 0.005,
      shortWeight: pick([0, 0.2, 0.35, 0.5]),
      tangentFloor: pick(floors),
      highBelief: pick([0.5, 0.6, 0.7, 0.8]), highMargin: pick([0.1, 0.2, 0.3]),
      midBelief: pick([0.35, 0.45, 0.55]), midMargin: pick([0.05, 0.1, 0.15]),
    };
    const row = await evalProfile(prof);
    const obj = objective(row);
    if (obj > best.obj) { best = { prof, row, obj }; console.log(`trial ${i}: ${JSON.stringify(row)}`); }
  }
  const all = fs.existsSync(PROFILES) ? JSON.parse(fs.readFileSync(PROFILES, 'utf8')) : {};
  all[`${model}:${anchors}`] = best.prof;
  fs.writeFileSync(PROFILES, JSON.stringify(all, null, 2) + '\n');
  console.log('BEST', JSON.stringify(best.prof), '\n', JSON.stringify(best.row));
})();
