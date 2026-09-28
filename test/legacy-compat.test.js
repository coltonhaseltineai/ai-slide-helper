// Older Mac builds still call these routes; their response shapes must not change.
const test = require('node:test');
const assert = require('node:assert');
const { call, stubClaude } = require('./helpers');

process.env.ANTHROPIC_API_KEY = 'test';
process.env.ACCESS_CODE = 'c';
const locate = require('../api/locate');
const expand = require('../api/expand');

test('locate keeps {index, confidence, learned} but never returns learned words', async () => {
  const calls = stubClaude({ index: 2, confidence: 'medium' });
  const r = await call(locate, { code: 'c', items: ['a', 'b', 'c'], current: 0, transcript: 'hello there' });
  assert.deepStrictEqual(r.body, { index: 1, confidence: 'medium', learned: [] });
  assert.strictEqual(calls.length, 1);
});

test('the old teach call answers without calling Claude', async () => {
  const calls = stubClaude({});
  const r = await call(locate, { code: 'c', items: ['a', 'b'], current: 0, known: 1, transcript: 'words here' });
  assert.deepStrictEqual(r.body, { index: 1, confidence: 'high', learned: [] });
  assert.strictEqual(calls.length, 0);
});

test('expand returns an empty hint list per line without calling Claude', async () => {
  const calls = stubClaude({});
  const r = await call(expand, { code: 'c', items: ['a', 'b', 'c'] });
  assert.deepStrictEqual(r.body, { hints: [[], [], []] });
  assert.strictEqual(calls.length, 0);
  assert.strictEqual((await call(expand, { code: 'x', items: ['a'] })).status, 401);
});
