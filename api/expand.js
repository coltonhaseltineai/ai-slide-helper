// Writes related hint words for each outline line, so paraphrases still match.
const { askJSON, readBody, checkRequest, cleanItems, send, sendError } = require('./_claude');

const SCHEMA = {
  type: 'object',
  properties: {
    hints: {
      type: 'array',
      items: { type: 'array', items: { type: 'string' } },
    },
  },
  required: ['hints'],
  additionalProperties: false,
};

const SYSTEM = `You help a live-captioning app follow a speaker through their talk outline.
For each outline line, list 20-30 words or short phrases the speaker is likely to SAY while covering that point:
synonyms, everyday paraphrases, concrete examples, and related terms. Prefer distinctive words over generic ones,
and avoid words that fit every line of the outline. Use the rest of the outline as context for what each line means.
Return one list per line, in the same order as the input.`;

module.exports = async (req, res) => {
  const body = readBody(req);
  const problem = checkRequest(req, body);
  if (problem) return send(res, problem === 'Wrong access code.' ? 401 : 400, { error: problem });
  const items = cleanItems(body.items);
  if (!items) return send(res, 400, { error: 'Send 1-80 outline lines as "items".' });

  try {
    const prompt = 'Outline (one line per point, numbered):\n' + items.map((t, i) => `${i + 1}. ${t}`).join('\n');
    const out = await askJSON({
      model: 'claude-sonnet-5', system: SYSTEM, prompt, schema: SCHEMA, maxTokens: 16000, effort: 'low',
    });
    const hints = items.map((_, i) => (Array.isArray(out.hints[i]) ? out.hints[i] : [])
      .map(w => String(w).slice(0, 40)).filter(Boolean).slice(0, 30));
    return send(res, 200, { hints });
  } catch (err) {
    return sendError(res, err);
  }
};
