// Claude as a judge: which outline point is the speaker covering now?
'use strict';
const claude = require('./_claude');
const { SCHEMA, PREP_SCHEMA, render, renderPrep } = require('./_judge-render');

const MODELS = { haiku: 'claude-haiku-4-5', sonnet: 'claude-sonnet-5' };

// Per-model request tweaks. Haiku: deterministic. Sonnet 5: no thinking (fast), and it rejects temperature.
function modelExtra(key) {
  return key === 'sonnet' ? { thinking: { type: 'disabled' } } : { temperature: 0 };
}

// input: cleaned judge input (see _judge-render.cleanInput). Returns 0-based point.
async function judge(input, { model = 'haiku', variant } = {}) {
  const r = render(input, variant);
  const res = await claude.askJSONMeta({
    model: MODELS[model], system: r.rules, prompt: r.prompt, schema: SCHEMA, maxTokens: 100,
    extra: modelExtra(model), requestOptions: { timeout: 8000, maxRetries: 0 },
  });
  let { state, point, confidence } = res.data;
  let p = Math.round(point) - 1;
  if (!(p >= r.visible.start && p < r.visible.end)) { state = 'unclear'; p = input.current; }
  if (state !== 'moved') p = input.current;
  return { state, point: p, confidence, model: res.model, serverMs: res.ms, usage: res.usage, promptVersion: r.promptVersion };
}

// Gist + example sentences per point, generated from the outline only (not from speech).
async function prep(items, { model = 'sonnet', variant } = {}) {
  const r = renderPrep(items, variant);
  const res = await claude.askJSONMeta({
    model: MODELS[model], system: r.rules, prompt: r.prompt, schema: PREP_SCHEMA, maxTokens: 12000,
    extra: modelExtra(model), requestOptions: { timeout: 60000, maxRetries: 1 },
  });
  const pts = Array.isArray(res.data.points) ? res.data.points : [];
  const points = items.map((_, i) => {
    const p = pts[i] || {};
    return {
      gist: String(p.gist || '').slice(0, 200),
      examples: (Array.isArray(p.examples) ? p.examples : []).map(e => String(e).slice(0, 200)).slice(0, 8),
    };
  });
  return { points, model: res.model, serverMs: res.ms, usage: res.usage };
}

module.exports = { MODELS, modelExtra, judge, prep };
