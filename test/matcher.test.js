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

const { WordFeeder } = require('../matcher.js');

test('feeder hands out settled words in small groups', () => {
  const f = new WordFeeder(3);
  assert.strictEqual(f.update(0, 'why does', false), '');
  assert.strictEqual(f.update(0, 'why does sleep', false), '');
  assert.strictEqual(f.update(0, 'why does sleep matter', false), 'why does sleep');
  assert.strictEqual(f.update(0, 'why does sleep matter so', false), '');
  assert.strictEqual(f.update(0, 'why does sleep matter so much', true), 'matter so much');
  assert.strictEqual(f.update(1, 'next', true), 'next');
});

test('feeder recovers when a result is rewritten shorter', () => {
  const f = new WordFeeder(2);
  assert.strictEqual(f.update(0, 'a b c d', false), 'a b c');
  assert.strictEqual(f.update(0, 'x y', true), 'x y');
});

const { LearnedLibrary, shouldLocate } = require('../matcher.js');

const memStore = () => { const m = {}; return { getItem: k => (k in m ? m[k] : null), setItem: (k, v) => { m[k] = v; } }; };

test('learned words let a paraphrase match locally', () => {
  const m = new Matcher(parseOutline(OUTLINE));
  m.feed('welcome everyone introductions');
  // Paraphrase of "Why sleep matters" with none of its words.
  const paraphrase = ['rest is honestly the foundation', 'nothing works without proper rest overnight'];
  paraphrase.forEach(p => m.feed(p));
  assert.strictEqual(m.current, 0);
  m.addKeywords(1, ['rest', 'foundation', 'overnight'], 'learned');
  paraphrase.forEach(p => m.feed(p));
  assert.strictEqual(m.current, 1);
});

test('addKeywords skips duplicates and bumps word counts', () => {
  const m = new Matcher(parseOutline(OUTLINE));
  assert.strictEqual(m.addKeywords(1, ['sleep', 'slumber']), 1);
  assert.strictEqual(m.df.get('slumber'), 1);
  assert.strictEqual(m.addKeywords(99, ['x']), 0);
});

test('library saves hints and learned words, caps and survives reload', () => {
  const store = memStore();
  const lib = new LearnedLibrary(store, 'k', 3);
  lib.setHints('Why sleep matters', ['rest', 'rest', 'bedtime']);
  assert.strictEqual(lib.addLearned('Why sleep matters', ['a', 'b'], 1), 2);
  assert.strictEqual(lib.addLearned('why SLEEP matters!', ['b', 'c', 'd'], 2), 2); // same line key
  lib.save();
  const again = new LearnedLibrary(store, 'k', 3);
  const w = again.words('Why sleep matters');
  assert.deepStrictEqual(w.hints, ['rest', 'bedtime']);
  assert.deepStrictEqual(w.learned.sort(), ['b', 'c', 'd']); // oldest ("a") dropped by the cap
  assert.strictEqual(again.learnedCount(), 3);
  assert.ok(again.has('Why sleep matters'));
  again.reset();
  assert.strictEqual(new LearnedLibrary(store, 'k').learnedCount(), 0);
});

test('shouldLocate only asks when unsure or on the periodic check', () => {
  const base = { now: 20000, lastCallAt: 15000, lastConfidentAt: 19000, newWords: 10, inFlight: false };
  assert.strictEqual(shouldLocate(base), false);                        // confident and recent call
  assert.strictEqual(shouldLocate({ ...base, lastConfidentAt: 13000 }), true); // unsure for 7s
  assert.strictEqual(shouldLocate({ ...base, lastCallAt: 9000 }), true);        // periodic
  assert.strictEqual(shouldLocate({ ...base, lastCallAt: 9000, inFlight: true }), false);
  assert.strictEqual(shouldLocate({ ...base, lastCallAt: 9000, newWords: 3 }), false);
  assert.strictEqual(shouldLocate({ ...base, lastConfidentAt: 0, lastCallAt: 18500 }), false); // too soon
});

test('hits counts words of the newest speech that fit an item', () => {
  const m = new Matcher(parseOutline(OUTLINE));
  assert.strictEqual(m.hits(0, 'welcome to the introductions'), 2);
  assert.strictEqual(m.hits(0, 'getting enough rest'), 0);
});
