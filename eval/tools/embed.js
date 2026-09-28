// Embeds texts with a tiny model via eval/python/embed.py, caching vectors on disk.
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const EVAL = path.join(__dirname, '..');
const CACHE = path.join(EVAL, '.cache');
const PY = process.env.EVAL_PYTHON || 'python3';
const loaded = {};

function key(t) { return crypto.createHash('sha1').update(t).digest('hex').slice(0, 20); }

function cacheFor(model) {
  if (loaded[model]) return loaded[model];
  const file = path.join(CACHE, `emb-${model}.jsonl`);
  const map = new Map();
  if (fs.existsSync(file)) for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line) continue;
    const { k, v } = JSON.parse(line);
    const b = Buffer.from(v, 'base64'); // small Buffers share a pool: copy exactly this vector's bytes
    map.set(k, new Float32Array(b.buffer.slice(b.byteOffset, b.byteOffset + b.length)));
  }
  return (loaded[model] = { file, map });
}

// Returns Float32Array vectors (L2-normalised) for each text, in order.
function embedAll(model, texts) {
  fs.mkdirSync(CACHE, { recursive: true });
  const c = cacheFor(model);
  const missing = [...new Set(texts.filter(t => !c.map.has(key(t))))];
  if (missing.length) {
    const inFile = path.join(CACHE, `in-${model}.json`), outFile = path.join(CACHE, `out-${model}.f32`);
    fs.writeFileSync(inFile, JSON.stringify(missing));
    const dim = +execFileSync(PY, [path.join(EVAL, 'python', 'embed.py'), model, inFile, outFile], { encoding: 'utf8', maxBuffer: 1 << 26 }).trim();
    const buf = fs.readFileSync(outFile);
    const all = new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
    const lines = [];
    missing.forEach((t, i) => {
      const v = Float32Array.from(all.subarray(i * dim, (i + 1) * dim));
      c.map.set(key(t), v);
      lines.push(JSON.stringify({ k: key(t), v: Buffer.from(v.buffer).toString('base64') }));
    });
    fs.appendFileSync(c.file, lines.join('\n') + '\n');
  }
  return texts.map(t => c.map.get(key(t)));
}

function cosine(a, b) { let s = 0; for (let i = 0; i < a.length; i++) s += a[i] * b[i]; return s; }

module.exports = { embedAll, cosine };
