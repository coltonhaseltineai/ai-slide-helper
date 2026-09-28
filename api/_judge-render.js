// Builds the judge prompt from the outline, the shown point and recent speech.
// Pure and dependency-free: the Mac app has a byte-identical Swift twin
// (mac/Sources/MatcherCore/JudgePrompt.swift), checked by shared golden fixtures.
'use strict';

const PROMPTS = require('./_judge-prompt.json');
const MAX_VISIBLE = 24;

const SCHEMA = {
  type: 'object',
  properties: {
    state: { type: 'string', enum: ['same', 'moved', 'tangent', 'unclear'] },
    point: { type: 'integer', description: 'number of the point being covered now (1-based)' },
    confidence: { type: 'string', enum: ['low', 'medium', 'high'] },
  },
  required: ['state', 'point', 'confidence'],
  additionalProperties: false,
};

const PREP_SCHEMA = {
  type: 'object',
  properties: {
    points: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          gist: { type: 'string' },
          examples: { type: 'array', items: { type: 'string' } },
        },
        required: ['gist', 'examples'],
        additionalProperties: false,
      },
    },
  },
  required: ['points'],
  additionalProperties: false,
};

// ASCII whitespace only, so JavaScript and Swift agree exactly.
function squash(s) { return String(s == null ? '' : s).replace(/[ \t\r\n]+/g, ' ').trim(); }
// First n Unicode code points.
function clip(s, n) { const cps = Array.from(s); return cps.length > n ? cps.slice(0, n).join('') : s; }

function variant(id) {
  const v = PROMPTS.variants[id || PROMPTS.current];
  if (!v) throw new Error(`unknown prompt variant ${id}`);
  return { id: id || PROMPTS.current, ...v };
}

function visibleRange(n, current) {
  if (n <= MAX_VISIBLE) return { start: 0, end: n };
  const start = Math.min(Math.max(current - 6, 0), n - MAX_VISIBLE);
  return { start, end: start + MAX_VISIBLE };
}

function outlineBlock(items, current, gists) {
  const { start, end } = visibleRange(items.length, current);
  const lines = [];
  for (let i = start; i < end; i++) {
    const it = items[i];
    let line = '   '.repeat(Math.min(it.level || 0, 3)) + (i + 1) + '. ' + clip(squash(it.text), 120);
    const cues = (it.cues || []).map(squash).filter(Boolean);
    if (cues.length) line += ' [also: ' + cues.join(', ') + ']';
    if (gists && gists[i]) line += ' — ' + clip(squash(gists[i]), 120);
    lines.push(line);
  }
  const note = (start > 0 || end < items.length) ? `(Only points ${start + 1}-${end} of ${items.length} are shown.)\n` : '';
  return { text: 'Outline:\n' + note + lines.join('\n'), visible: { start, end } };
}

function dynamicBlock(current, lines) {
  let out = 'Shown now: point ' + (current + 1) + '.\nSpeech, oldest first:\n';
  if (!lines.length) return out + '(no speech yet)';
  out += lines.map((l, i) => (i === lines.length - 1 ? '[newest] ' : `[${l.ago}s ago] `) + squash(l.text)).join('\n');
  return out;
}

// input: { items: [{text, level, cues}], current (0-based), lines: [{ago, text}], gists?: [string] }
function render(input, variantId) {
  const v = variant(variantId);
  const o = outlineBlock(input.items, input.current, input.gists);
  const d = dynamicBlock(input.current, input.lines || []);
  return { rules: v.rules, outlineBlock: o.text, dynamicBlock: d, prompt: o.text + '\n\n' + d, visible: o.visible, promptVersion: v.id };
}

function renderPrep(items, variantId) {
  const v = variant(variantId);
  const lines = items.map((it, i) => '   '.repeat(Math.min(it.level || 0, 3)) + (i + 1) + '. ' + clip(squash(it.text), 120) +
    ((it.cues || []).length ? ' [also: ' + it.cues.map(squash).join(', ') + ']' : ''));
  return { rules: v.prepRules, prompt: 'Outline:\n' + lines.join('\n') + `\n\nWrite ${items.length} entries, one per point, in order.` };
}

// Validates a request body; returns { input } or { error }.
function cleanInput(body) {
  const b = body || {};
  if (!Array.isArray(b.items) || b.items.length < 1 || b.items.length > 80) return { error: 'Send 1-80 outline items.' };
  const items = [];
  for (const raw of b.items) {
    const it = typeof raw === 'string' ? { text: raw } : (raw || {});
    const text = squash(it.text);
    if (!text || Array.from(text).length > 200) return { error: 'Each item needs 1-200 characters of text.' };
    const level = Number.isInteger(it.level) ? Math.min(Math.max(it.level, 0), 10) : 0;
    const cues = Array.isArray(it.cues) ? it.cues.slice(0, 5).map(c => clip(squash(c), 40)).filter(Boolean) : [];
    items.push({ text, level, cues });
  }
  const current = Number.isInteger(b.current) ? b.current : 0;
  if (current < 0 || current >= items.length) return { error: 'current is out of range.' };
  const rawLines = Array.isArray(b.lines) ? b.lines : [];
  if (rawLines.length > 12) return { error: 'Send at most 12 speech lines.' };
  const lines = [];
  let total = 0;
  for (const l of rawLines) {
    const text = squash(l && l.text);
    const ago = Number.isInteger(l && l.ago) ? Math.min(Math.max(l.ago, 0), 600) : 0;
    if (Array.from(text).length > 400) return { error: 'A speech line is too long.' };
    total += text.length;
    if (text) lines.push({ ago, text });
  }
  if (total > 2000) return { error: 'Too much speech text.' };
  let gists;
  if (b.gists != null) {
    if (!Array.isArray(b.gists) || b.gists.length !== items.length) return { error: 'gists must match items.' };
    gists = b.gists.map(g => clip(squash(g), 200));
  }
  return { input: { items, current, lines, gists } };
}

module.exports = { PROMPTS, SCHEMA, PREP_SCHEMA, MAX_VISIBLE, squash, clip, variant, visibleRange, render, renderPrep, cleanInput };
