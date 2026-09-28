// LEGACY: used by Mac app builds before on-device following. Keeps its response shape
// ({index, confidence, learned}) so those builds keep working, but never returns learned words.
// Retire once the "legacy locate" log lines stop.
const { askJSON, readBody, checkRequest, cleanItems, send, sendError } = require('./_claude');

const SCHEMA = {
  type: 'object',
  properties: {
    index: { type: 'integer', description: '1-based number of the outline point being covered' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
  },
  required: ['index', 'confidence'],
  additionalProperties: false,
};

const SYSTEM = `You follow a speaker through their talk outline using a live speech transcript (speech-to-text, so expect errors).
Decide which outline point the most recent speech is about. Speakers usually move forward in order, but may jump or go back.
Use "high" confidence only when the speech clearly belongs to that point.`;

module.exports = async (req, res) => {
  console.log('legacy locate');
  const body = readBody(req);
  const problem = checkRequest(req, body);
  if (problem) return send(res, problem === 'Wrong access code.' ? 401 : 400, { error: problem });
  const items = cleanItems(body.items);
  const transcript = String(body.transcript || '').slice(-2000).trim();
  if (!items || !transcript) return send(res, 400, { error: 'Send "items" and "transcript".' });
  const current = Number.isInteger(body.current) ? body.current : 0;
  const known = Number.isInteger(body.known) && body.known >= 0 && body.known < items.length ? body.known : null;

  // The old "teach" call: nothing to learn any more, so answer without calling Claude.
  if (known !== null) return send(res, 200, { index: known, confidence: 'high', learned: [] });

  try {
    const outline = items.map((t, i) => `${i + 1}. ${t}`).join('\n');
    const prompt = `Outline:\n${outline}\n\nThe app currently shows point ${current + 1}.\n\nMost recent speech:\n${transcript}`;
    const out = await askJSON({ model: 'claude-haiku-4-5', system: SYSTEM, prompt, schema: SCHEMA, maxTokens: 100 });
    const index = Math.min(Math.max(Math.round(out.index) - 1, 0), items.length - 1);
    return send(res, 200, { index, confidence: out.confidence, learned: [] });
  } catch (err) {
    return sendError(res, err);
  }
};
