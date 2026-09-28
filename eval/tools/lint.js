#!/usr/bin/env node
// Checks authored talks against the dataset rules. Usage: node eval/tools/lint.js [talk.json ...]
'use strict';
const fs = require('fs');
const path = require('path');
const { KINDS, parseOutline, tokenize, asrText, words } = require('./lib');

const TALKS = path.join(__dirname, '..', 'talks');
const QUOTA = { tangent: 2, callback: 2, preview: 2, filler: 2, goback: 1, skip: 1, transition: 1 };

function lint(file) {
  const errors = [], warnings = [];
  let talk;
  try { talk = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return { errors: [`bad JSON: ${e.message}`], warnings }; }
  const need = ['schema', 'id', 'title', 'tier', 'speaker', 'outlineText', 'confusable', 'segments'];
  for (const k of need) if (!(k in talk)) errors.push(`missing field ${k}`);
  if (errors.length) return { errors, warnings };
  if (talk.schema !== 'live-outline-talk/1') errors.push('schema must be live-outline-talk/1');
  if (path.basename(file, '.json') !== talk.id) errors.push('file name must equal id');
  if (!['paraphrased', 'natural'].includes(talk.tier)) errors.push('tier must be paraphrased|natural');

  const items = parseOutline(talk.outlineText);
  if (items.length < 8 || items.length > 14) errors.push(`outline has ${items.length} points; need 8-14`);
  if (!items.some(i => i.level > 0)) errors.push('outline needs indented sub-points');
  const n = items.length;
  if (!Array.isArray(talk.confusable) || talk.confusable.length < 2) errors.push('need >= 2 confusable pairs');
  for (const p of talk.confusable || []) if (!Array.isArray(p) || p.length !== 2 || p.some(x => !(x >= 0 && x < n))) errors.push(`bad confusable pair ${JSON.stringify(p)}`);

  const counts = Object.fromEntries(KINDS.map(k => [k, 0]));
  const covered = new Set();
  let wordsTotal = 0, onSegs = 0, leaky = [];
  let prev = null;
  talk.segments.forEach((s, i) => {
    const where = `segment ${i}`;
    if (typeof s.say !== 'string' || words(asrText(s.say)).length < 3) errors.push(`${where}: say must have >= 3 words`);
    if (!Number.isInteger(s.truth) || s.truth < 0 || s.truth >= n) errors.push(`${where}: truth out of range`);
    if (!KINDS.includes(s.kind)) errors.push(`${where}: kind must be one of ${KINDS.join('|')}`);
    for (const a of s.accept || []) if (!(Number.isInteger(a) && a >= 0 && a < n)) errors.push(`${where}: bad accept`);
    counts[s.kind] = (counts[s.kind] || 0) + 1;
    wordsTotal += words(asrText(s.say || '')).length;
    if (['tangent', 'callback', 'preview', 'filler'].includes(s.kind) && prev !== null && s.truth !== prev)
      errors.push(`${where}: ${s.kind} must keep truth on the current point (${prev})`);
    if (s.kind === 'transition' && !(s.accept || []).length) errors.push(`${where}: transition needs accept [old, new]`);
    if (s.kind === 'goback' && !(prev !== null && s.truth < prev)) errors.push(`${where}: goback must move to an earlier point`);
    if (s.kind === 'skip' && !(prev !== null && s.truth >= prev + 2)) errors.push(`${where}: skip must jump ahead by >= 2`);
    if (s.kind === 'on') {
      onSegs++;
      covered.add(s.truth);
      if (prev !== null && s.truth !== prev && s.truth !== prev + 1 && s.truth !== prev)
        errors.push(`${where}: 'on' may only continue or advance by one (use goback/skip for jumps)`);
      const seg = new Set(tokenize(s.say));
      const line = tokenize(items[s.truth].text + ' ' + items[s.truth].cues.join(' '));
      const hits = line.filter(w => seg.has(w));
      if (hits.length) leaky.push({ i, hits });
    }
    if (s.kind === 'resume' && !(prev !== null && s.truth > prev)) errors.push(`${where}: resume must move forward (after a goback)`);
    if (s.kind === 'goback' || s.kind === 'skip' || s.kind === 'resume') covered.add(s.truth);
    if (!['tangent', 'callback', 'preview', 'filler'].includes(s.kind) && s.kind !== 'transition') prev = s.truth;
    if (prev === null) prev = s.truth;
  });
  if (talk.segments[0] && talk.segments[0].truth !== 0) errors.push('first segment must be on point 0');
  for (let i = 0; i < n; i++) if (!covered.has(i)) errors.push(`point ${i} ("${items[i].text}") is never covered`);
  for (const [k, q] of Object.entries(QUOTA)) if ((counts[k] || 0) < q) errors.push(`need >= ${q} ${k} segment(s), have ${counts[k] || 0}`);
  const wpm = talk.speaker.wpm || 150;
  const minutes = wordsTotal / wpm;
  if (minutes < 4 || minutes > 7.5) errors.push(`talk is ${minutes.toFixed(1)} min at ${wpm} wpm; need 4-7`);
  const leakRate = onSegs ? leaky.length / onSegs : 0;
  const maxLeak = talk.tier === 'paraphrased' ? 0.10 : 0.5;
  if (leakRate > maxLeak) errors.push(`${(leakRate * 100).toFixed(0)}% of 'on' segments reuse their point's words (max ${maxLeak * 100}%): ` +
    leaky.slice(0, 6).map(l => `#${l.i}[${l.hits.join(',')}]`).join(' '));
  return { errors, warnings, stats: { points: n, segments: talk.segments.length, minutes: +minutes.toFixed(1), leakRate: +leakRate.toFixed(2), counts } };
}

if (require.main === module) {
  const files = process.argv.slice(2).length ? process.argv.slice(2)
    : fs.readdirSync(TALKS).filter(f => f.endsWith('.json')).map(f => path.join(TALKS, f));
  let bad = 0;
  for (const f of files) {
    const r = lint(f);
    const name = path.basename(f);
    if (r.errors.length) { bad++; console.log(`✗ ${name}`); r.errors.forEach(e => console.log(`   - ${e}`)); }
    else console.log(`✓ ${name} ${JSON.stringify(r.stats)}`);
  }
  process.exit(bad ? 1 : 0);
}
module.exports = { lint };
