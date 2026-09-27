// Works out which outline point the speaker is on, and which words they used for it.
const { askJSON, readBody, checkRequest, cleanItems, send, sendError } = require('./_claude');

const SCHEMA = {
  type: 'object',
  properties: {
    index: { type: 'integer', description: '1-based number of the outline point being covered' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
    learned: { type: 'array', items: { type: 'string' } },
  },
  required: ['index', 'confidence', 'learned'],
  additionalProperties: false,
};

const SYSTEM = `You follow a speaker through their talk outline using a live speech transcript (speech-to-text, so expect errors).
Decide which outline point the most recent speech is about. Speakers usually move forward in order, but may jump or go back.
Use "high" confidence only when the speech clearly belongs to that point.
Also list up to 8 distinctive words or two-word phrases FROM THE TRANSCRIPT that show it belongs to that point,
so the app can recognise this point by itself next time. Only include words the speaker actually said, and skip filler words.`;

module.exports = async (req, res) => {
  const body = readBody(req);
  const problem = checkRequest(req, body);
  if (problem) return send(res, problem === 'Wrong access code.' ? 401 : 400, { error: problem });
  const items = cleanItems(body.items);
  const transcript = String(body.transcript || '').slice(-2000).trim();
  if (!items || !transcript) return send(res, 400, { error: 'Send "items" and "transcript".' });
  const current = Number.isInteger(body.current) ? body.current : 0;
  const known = Number.isInteger(body.known) && body.known >= 0 && body.known < items.length ? body.known : null;

  try {
    const outline = items.map((t, i) => `${i + 1}. ${t}`).join('\n');
    const prompt = known !== null
      ? `Outline:\n${outline}\n\nThe speaker confirmed they are on point ${known + 1}. Set index to ${known + 1} and confidence to "high", and list the words from this transcript that belong to it.\n\nTranscript:\n${transcript}`
      : `Outline:\n${outline}\n\nThe app currently shows point ${current + 1}.\n\nMost recent speech:\n${transcript}`;
    const out = await askJSON({ model: 'claude-haiku-4-5', system: SYSTEM, prompt, schema: SCHEMA, maxTokens: 400 });
    const index = Math.min(Math.max(Math.round(out.index) - 1, 0), items.length - 1);
    const learned = (out.learned || []).map(w => String(w).toLowerCase().slice(0, 40))
      .filter(w => w && transcript.toLowerCase().includes(w)).slice(0, 8);
    return send(res, 200, { index, confidence: out.confidence, learned });
  } catch (err) {
    return sendError(res, err);
  }
};
