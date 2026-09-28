// Claude judge for the Mac app: which outline point is the speaker covering now?
// Ops: ping, prompts, judge, prep. Speech text is never logged.
'use strict';
const claude = require('./_claude');
const judgeLib = require('./_judge');
const { PROMPTS, cleanInput } = require('./_judge-render');

module.exports = async (req, res) => {
  const body = claude.readBody(req);
  if (req.method !== 'POST') return claude.send(res, 400, { error: 'Use POST.' });
  const code = process.env.ACCESS_CODE;
  if (code && body.code !== code) return claude.send(res, 401, { error: 'Wrong access code.' });
  const op = body.op || 'judge';
  const model = body.model || 'haiku';
  const variant = body.variant || undefined;

  if (op === 'ping') return claude.send(res, 200, { ok: true, promptVersion: PROMPTS.current });
  if (op === 'prompts') return claude.send(res, 200, { current: PROMPTS.current, variants: PROMPTS.variants });
  if (!['judge', 'prep'].includes(op)) return claude.send(res, 400, { error: 'Unknown op.' });
  if (!Object.prototype.hasOwnProperty.call(judgeLib.MODELS, model)) return claude.send(res, 400, { error: 'Unknown model.' });
  if (variant && !PROMPTS.variants[variant]) return claude.send(res, 400, { error: 'Unknown prompt variant.' });
  if (!process.env.ANTHROPIC_API_KEY) return claude.send(res, 500, { error: 'The server has no ANTHROPIC_API_KEY yet.' });
  const cleaned = cleanInput(body);
  if (cleaned.error) return claude.send(res, 400, { error: cleaned.error });

  const started = Date.now();
  try {
    const out = op === 'judge'
      ? await judgeLib.judge(cleaned.input, { model, variant })
      : await judgeLib.prep(cleaned.input.items, { model: body.model || 'sonnet', variant });
    console.log(JSON.stringify({ route: 'follow', v: String(body.v || '').slice(0, 20), op, model: out.model, variant: variant || PROMPTS.current, serverMs: Date.now() - started, usage: out.usage }));
    return claude.send(res, 200, out);
  } catch (err) {
    return claude.sendError(res, err);
  }
};
