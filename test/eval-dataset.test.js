// The benchmark talks, their built timelines and the Swift test fixtures must stay in step:
// edit a talk or the judge prompt, then run `node eval/tools/build.js && node eval/tools/fixtures.js`.
const test = require('node:test');
const assert = require('node:assert');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');

const root = path.join(__dirname, '..');
const run = (...args) => execFileSync(process.execPath, args, { cwd: root, encoding: 'utf8', stdio: 'pipe' });

test('every talk passes the dataset lint', () => {
  const out = run('eval/tools/lint.js');
  assert.strictEqual((out.match(/✓/g) || []).length, 10, out);
});

test('built talks match their sources', () => {
  run('eval/tools/build.js', '--check');
});

test('Swift fixtures match the JavaScript reference', () => {
  run('eval/tools/fixtures.js', '--check');
});

test('splits cover every talk exactly once', () => {
  const splits = JSON.parse(fs.readFileSync(path.join(root, 'eval/splits.json'), 'utf8'));
  const ids = fs.readdirSync(path.join(root, 'eval/talks')).map(f => f.replace(/\.json$/, '')).sort();
  assert.deepStrictEqual([...splits.dev, ...splits.test].sort(), ids);
});
