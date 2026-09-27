const test = require('node:test');
const assert = require('node:assert');
const { parseOutline, Matcher } = require('../matcher.js');

const OUTLINE = `Welcome and introductions
Why sleep matters
  Memory consolidation [cues: remember, learning]
  Immune health
Tips for better sleep
  Keep a consistent schedule
  Avoid screens before bed
Questions`;

test('parses nesting and cues', () => {
  const items = parseOutline(OUTLINE);
  assert.strictEqual(items.length, 8);
  assert.strictEqual(items[2].level, 1);
  assert.deepStrictEqual(items[2].cues, ['remember', 'learning']);
});

test('advances through the talk in order', () => {
  const m = new Matcher(parseOutline(OUTLINE));
  const say = t => t.split('. ').forEach(s => m.feed(s));
  say('Hi everyone welcome. Thanks for coming, quick introductions');
  assert.strictEqual(m.current, 0);
  say('So why does sleep matter so much. Sleep matters for everything');
  assert.strictEqual(m.current, 1);
  say('When you sleep your brain consolidates memory. You remember learning better');
  assert.strictEqual(m.current, 2);
  say('Your immune system and health also depend on it. Immune health improves');
  assert.strictEqual(m.current, 3);
  say('Now some tips for better sleep. Here are my tips');
  assert.strictEqual(m.current, 4);
  say('Keep a consistent schedule every day. Same schedule on weekends');
  assert.strictEqual(m.current, 5);
  say('Avoid screens before bed. Put phone screens away before bed');
  assert.strictEqual(m.current, 6);
  say('Any questions. Happy to take questions');
  assert.strictEqual(m.current, 7);
});

test('a single stray word does not cause a jump', () => {
  const m = new Matcher(parseOutline(OUTLINE));
  m.feed('welcome everyone introductions');
  m.feed('screens');
  assert.strictEqual(m.current, 0);
});
