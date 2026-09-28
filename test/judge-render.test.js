const test = require('node:test');
const assert = require('node:assert');
const r = require('../api/_judge-render');

const items = n => Array.from({ length: n }, (_, i) => ({ text: `Point ${i + 1}`, level: i % 3 === 2 ? 1 : 0, cues: [] }));

test('renders outline, shown point and speech with the newest line marked', () => {
  const out = r.render({ items: [{ text: 'Welcome', level: 0, cues: [] }, { text: 'Why  sleep\tmatters', level: 0, cues: ['rest'] }, { text: 'Memory', level: 1, cues: [] }],
    current: 1, lines: [{ ago: 9, text: 'rest is  the foundation' }, { ago: 0, text: 'nothing works' }] });
  assert.strictEqual(out.prompt, 'Outline:\n1. Welcome\n2. Why sleep matters [also: rest]\n   3. Memory\n\nShown now: point 2.\nSpeech, oldest first:\n[9s ago] rest is the foundation\n[newest] nothing works');
  assert.deepStrictEqual(out.visible, { start: 0, end: 3 });
  assert.strictEqual(out.promptVersion, r.PROMPTS.current);
  assert.ok(out.rules.includes('judge by meaning'));
});

test('long outlines show a 24-point window around the shown point', () => {
  const out = r.render({ items: items(40), current: 30, lines: [] });
  assert.deepStrictEqual(out.visible, { start: 16, end: 40 });
  assert.ok(out.outlineBlock.startsWith('Outline:\n(Only points 17-40 of 40 are shown.)\n'));
  assert.ok(out.prompt.endsWith('(no speech yet)'));
  assert.deepStrictEqual(r.render({ items: items(40), current: 2, lines: [] }).visible, { start: 0, end: 24 });
});

test('clips by code points and adds gists', () => {
  const long = '😀'.repeat(130);
  const out = r.render({ items: [{ text: long, level: 0, cues: [] }], current: 0, lines: [], gists: ['about  things'] });
  assert.ok(out.outlineBlock.includes('1. ' + '😀'.repeat(120) + ' — about things'));
});

test('cleanInput validates and normalises', () => {
  assert.ok(r.cleanInput({ items: [] }).error);
  assert.ok(r.cleanInput({ items: ['a'], current: 3 }).error);
  assert.ok(r.cleanInput({ items: ['a'], lines: Array(13).fill({ ago: 1, text: 'x' }) }).error);
  assert.ok(r.cleanInput({ items: ['a', 'b'], gists: ['x'] }).error);
  const ok = r.cleanInput({ items: ['a', { text: ' b ', level: 1, cues: ['c'] }], current: 1, lines: [{ ago: 3, text: ' hi\n there ' }] });
  assert.deepStrictEqual(ok.input, { items: [{ text: 'a', level: 0, cues: [] }, { text: 'b', level: 1, cues: ['c'] }], current: 1, lines: [{ ago: 3, text: 'hi there' }], gists: undefined });
});
