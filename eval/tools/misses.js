#!/usr/bin/env node
// Subscription-mode helpers for the judge cache.
//   node eval/tools/misses.js batches <size> <out.json>   group unanswered questions into batches for subagents
//   node eval/tools/misses.js ingest <answers.json>        add subagent answers to the verdict cache
//   node eval/tools/misses.js batch-files <size> <dir>     same, one file per batch (shuffled across talks so a batch
//                                                          never holds a run of neighbouring moments from one talk)
//   node eval/tools/misses.js ingest-files <dir> <results.json>   results: [{file, answers: [{i, state, point, confidence}]}]
//   node eval/tools/misses.js prep-list <out.json>         outline preps (gist + examples) still to write
//   node eval/tools/misses.js prep-ingest <answers.json>   [{k, points: [{gist, examples}]}] → .cache/prep-<k>.json
// Answers: [{k, state, point (1-based), confidence}]. Latency is the model's median API latency (SIM_MS).
'use strict';
const fs = require('fs');
const path = require('path');
const CACHE = path.join(__dirname, '..', '.cache');
const SIM_MS = { haiku: 800, sonnet: 1590 };
const [cmd, a, b] = process.argv.slice(2);

function readJsonl(f) { return fs.existsSync(f) ? fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)) : []; }

if (cmd === 'batches') {
  const cached = new Set(readJsonl(path.join(CACHE, 'verdicts.jsonl')).map(o => o.k));
  const seen = new Set();
  const misses = readJsonl(path.join(CACHE, 'misses.jsonl')).filter(m => !cached.has(m.k) && !seen.has(m.k) && seen.add(m.k));
  const size = +a || 25;
  const byModel = {};
  for (const m of misses) (byModel[m.model] = byModel[m.model] || []).push(m);
  const batches = [];
  for (const [model, list] of Object.entries(byModel))
    for (let i = 0; i < list.length; i += size) batches.push({ model, rules: list[0].rules, cases: list.slice(i, i + size).map(m => ({ k: m.k, prompt: m.prompt, visible: m.visible, current: m.current })) });
  fs.writeFileSync(b, JSON.stringify(batches));
  console.log(`${misses.length} questions in ${batches.length} batches: ` + Object.entries(byModel).map(([m, l]) => `${m} ${l.length}`).join(', '));
} else if (cmd === 'ingest') {
  const answers = JSON.parse(fs.readFileSync(a, 'utf8'));
  const misses = new Map(readJsonl(path.join(CACHE, 'misses.jsonl')).map(m => [m.k, m]));
  const cached = new Set(readJsonl(path.join(CACHE, 'verdicts.jsonl')).map(o => o.k));
  const lines = [];
  let bad = 0;
  for (const ans of answers) {
    const m = misses.get(ans.k);
    if (!m || cached.has(ans.k)) continue;
    let state = ['same', 'moved', 'tangent', 'unclear'].includes(ans.state) ? ans.state : 'unclear';
    const conf = ['low', 'medium', 'high'].includes(ans.confidence) ? ans.confidence : 'low';
    let point = Math.round(Number(ans.point)) - 1;
    if (!(point >= m.visible.start && point < m.visible.end)) { if (state === 'moved') bad++; state = state === 'moved' ? 'unclear' : state; point = m.current; }
    if (state !== 'moved') point = m.current;
    lines.push(JSON.stringify({ k: ans.k, v: { state, point, confidence: conf, ms: SIM_MS[m.model], source: 'subscription' } }));
    cached.add(ans.k);
  }
  if (lines.length) fs.appendFileSync(path.join(CACHE, 'verdicts.jsonl'), lines.join('\n') + '\n');
  console.log(`ingested ${lines.length} answers (${bad} out-of-range moves treated as unclear)`);
} else if (cmd === 'batch-files') {
  const cached = new Set(readJsonl(path.join(CACHE, 'verdicts.jsonl')).map(o => o.k));
  const seen = new Set();
  const misses = readJsonl(path.join(CACHE, 'misses.jsonl')).filter(m => !cached.has(m.k) && !seen.has(m.k) && seen.add(m.k));
  const size = +a || 30;
  fs.mkdirSync(b, { recursive: true });
  for (const f of fs.readdirSync(b)) if (/^b\d+\.json$/.test(f)) fs.unlinkSync(path.join(b, f));
  // Deterministic shuffle by key hash.
  const byModel = {};
  for (const m of misses) (byModel[m.model] = byModel[m.model] || []).push(m);
  const manifest = [];
  let n = 0;
  for (const [model, list] of Object.entries(byModel)) {
    list.sort((x, y) => (x.k < y.k ? -1 : 1));
    for (let i = 0; i < list.length; i += size) {
      const file = `b${String(n++).padStart(3, '0')}.json`;
      const cases = list.slice(i, i + size).map((m, j) => ({ i: j + 1, k: m.k, visible: m.visible, current: m.current, prompt: m.prompt }));
      fs.writeFileSync(path.join(b, file), JSON.stringify({ model, rules: list[0].rules, cases }, null, 1));
      manifest.push({ file: path.join(b, file), model, n: cases.length });
    }
  }
  fs.writeFileSync(path.join(b, 'manifest.json'), JSON.stringify(manifest));
  console.log(`${misses.length} questions in ${manifest.length} files: ` + Object.entries(byModel).map(([m, l]) => `${m} ${l.length}`).join(', '));
} else if (cmd === 'ingest-files') {
  const results = JSON.parse(fs.readFileSync(b, 'utf8'));
  const answers = [];
  let lost = 0;
  for (const r of results) {
    if (!r || !r.file) continue;
    const batch = JSON.parse(fs.readFileSync(path.isAbsolute(r.file) ? r.file : path.join(a, r.file), 'utf8'));
    const byI = new Map(batch.cases.map(c => [c.i, c.k]));
    for (const x of (r.answers || [])) { const k = byI.get(Number(x.i)); if (k) answers.push({ ...x, k }); else lost++; }
  }
  const tmp = path.join(CACHE, 'answers-tmp.json');
  fs.writeFileSync(tmp, JSON.stringify(answers));
  process.argv[3] = tmp;
  console.log(`${answers.length} answers from ${results.length} batches (${lost} with unknown case numbers)`);
  require('child_process').execFileSync(process.execPath, [__filename, 'ingest', tmp], { stdio: 'inherit' });
} else if (cmd === 'prep-list') {
  const todo = readJsonl(path.join(CACHE, 'prep-misses.jsonl')).filter(m => !fs.existsSync(path.join(CACHE, m.file)));
  fs.writeFileSync(a, JSON.stringify(todo));
  console.log(`${todo.length} preps to write`);
} else if (cmd === 'prep-ingest') {
  const answers = JSON.parse(fs.readFileSync(a, 'utf8'));
  const todo = new Map(readJsonl(path.join(CACHE, 'prep-misses.jsonl')).map(m => [m.k, m]));
  let n = 0;
  for (const ans of answers) {
    const m = todo.get(ans.k);
    if (!m) continue;
    const pts = Array.isArray(ans.points) ? ans.points : [];
    if (pts.length !== m.count) { console.log(`${ans.k}: ${pts.length} entries for ${m.count} points — skipped`); continue; }
    // Same clean-up as api/_judge.js prep().
    const points = pts.map(p => ({
      gist: String((p && p.gist) || '').slice(0, 200),
      examples: (Array.isArray(p && p.examples) ? p.examples : []).map(e => String(e).slice(0, 200)).slice(0, 8),
    }));
    fs.writeFileSync(path.join(CACHE, m.file), JSON.stringify(points));
    n++;
  }
  console.log(`wrote ${n} preps`);
} else {
  console.log('usage: misses.js batches <size> <out.json> | ingest <answers.json> | prep-list <out.json> | prep-ingest <answers.json>');
  process.exit(1);
}
