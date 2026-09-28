#!/usr/bin/env node
// Builds eval/built/<id>.json from eval/talks/<id>.json. `--check` verifies committed files are current.
'use strict';
const fs = require('fs');
const path = require('path');
const { build } = require('./lib');

const ROOT = path.join(__dirname, '..');
const check = process.argv.includes('--check');
fs.mkdirSync(path.join(ROOT, 'built'), { recursive: true });
let stale = 0;
for (const f of fs.readdirSync(path.join(ROOT, 'talks')).filter(f => f.endsWith('.json')).sort()) {
  const talk = JSON.parse(fs.readFileSync(path.join(ROOT, 'talks', f), 'utf8'));
  const out = JSON.stringify(build(talk)) + '\n';
  const dest = path.join(ROOT, 'built', f);
  if (check) {
    const cur = fs.existsSync(dest) ? fs.readFileSync(dest, 'utf8') : '';
    if (cur !== out) { stale++; console.log(`stale: built/${f}`); }
  } else {
    fs.writeFileSync(dest, out);
    const b = JSON.parse(out);
    console.log(`built ${f}: ${b.items.length} points, ${b.chunks.length} chunks, ${b.ticks.length} ticks, ${(b.duration / 60).toFixed(1)} min`);
  }
}
if (check && stale) { console.log('Run: node eval/tools/build.js'); process.exit(1); }
