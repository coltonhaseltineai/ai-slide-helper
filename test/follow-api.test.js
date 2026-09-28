const test = require('node:test');
const assert = require('node:assert');
const { call, stubClaude } = require('./helpers');

process.env.ANTHROPIC_API_KEY = 'test';
process.env.ACCESS_CODE = 'c';
const follow = require('../api/follow');
const body = extra => ({ code: 'c', items: ['Welcome', 'Why sleep matters', 'Tips'], current: 0, lines: [{ ago: 0, text: 'rest is the foundation' }], ...extra });

test('rejects a wrong code and bad input', async () => {
  assert.strictEqual((await call(follow, body({ code: 'x' }))).status, 401);
  assert.strictEqual((await call(follow, body({ items: [] }))).status, 400);
  assert.strictEqual((await call(follow, body({ model: 'gpt' }))).status, 400);
  assert.strictEqual((await call(follow, body({ op: 'nope' }))).status, 400);
  assert.strictEqual((await call(follow, body(), 'GET')).status, 400);
});

test('ping and prompts never call Claude', async () => {
  const calls = stubClaude({});
  const ping = await call(follow, { code: 'c', op: 'ping' });
  assert.strictEqual(ping.status, 200);
  assert.ok(ping.body.promptVersion);
  const prompts = await call(follow, { code: 'c', op: 'prompts' });
  assert.ok(prompts.body.variants[prompts.body.current].rules);
  assert.strictEqual(calls.length, 0);
});

test('judge returns a 0-based point; Haiku is deterministic, Sonnet has no temperature', async () => {
  const calls = stubClaude({ state: 'moved', point: 2, confidence: 'high' });
  const r = await call(follow, body());
  assert.strictEqual(r.status, 200);
  assert.deepStrictEqual([r.body.state, r.body.point, r.body.confidence], ['moved', 1, 'high']);
  assert.strictEqual(calls[0].model, 'claude-haiku-4-5');
  assert.strictEqual(calls[0].extra.temperature, 0);
  assert.deepStrictEqual(calls[0].requestOptions, { timeout: 8000, maxRetries: 0 });
  await call(follow, body({ model: 'sonnet' }));
  assert.strictEqual(calls[1].model, 'claude-sonnet-5');
  assert.strictEqual(calls[1].extra.temperature, undefined);
  assert.deepStrictEqual(calls[1].extra.thinking, { type: 'disabled' });
});

test('an out-of-range or non-move answer keeps the shown point', async () => {
  stubClaude({ state: 'moved', point: 99, confidence: 'high' });
  const r = await call(follow, body({ current: 1 }));
  assert.deepStrictEqual([r.body.state, r.body.point], ['unclear', 1]);
  stubClaude({ state: 'same', point: 3, confidence: 'high' });
  assert.strictEqual((await call(follow, body({ current: 1 }))).body.point, 1);
});

test('prep returns one gist and examples per point', async () => {
  stubClaude({ points: [{ gist: 'g1', examples: ['a', 'b'] }] });
  const r = await call(follow, body({ op: 'prep' }));
  assert.strictEqual(r.status, 200);
  assert.strictEqual(r.body.points.length, 3);
  assert.deepStrictEqual(r.body.points[0], { gist: 'g1', examples: ['a', 'b'] });
  assert.deepStrictEqual(r.body.points[2], { gist: '', examples: [] });
});
