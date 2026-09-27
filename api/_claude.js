// Shared helpers for the Live Outline API functions.
const sdk = require('@anthropic-ai/sdk');
const Anthropic = sdk.default || sdk;

let client = null;
function getClient() {
  if (!client) client = new Anthropic(); // reads ANTHROPIC_API_KEY
  return client;
}

function readBody(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  try { return JSON.parse(req.body || '{}'); } catch (e) { return {}; }
}

// Returns an error message, or null when the request may go ahead.
function checkRequest(req, body) {
  if (req.method !== 'POST') return 'Use POST.';
  if (!process.env.ANTHROPIC_API_KEY) return 'The server has no ANTHROPIC_API_KEY yet.';
  const code = process.env.ACCESS_CODE;
  if (code && body.code !== code) return 'Wrong access code.';
  return null;
}

function cleanItems(items) {
  if (!Array.isArray(items) || !items.length || items.length > 80) return null;
  return items.map(t => String(t || '').slice(0, 200));
}

// Asks Claude for JSON matching `schema` and returns the parsed object.
async function askJSON({ model, system, prompt, schema, maxTokens, effort }) {
  const outputConfig = { format: { type: 'json_schema', schema } };
  if (effort) outputConfig.effort = effort;
  const response = await getClient().messages.create({
    model,
    max_tokens: maxTokens,
    system,
    messages: [{ role: 'user', content: prompt }],
    output_config: outputConfig,
  });
  if (response.stop_reason === 'refusal') throw new Error('Claude declined this request.');
  if (response.stop_reason === 'max_tokens') throw new Error('Claude ran out of room to answer.');
  const text = response.content.filter(b => b.type === 'text').map(b => b.text).join('');
  return JSON.parse(text);
}

function send(res, status, data) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(data));
}

function sendError(res, err) {
  const status = err && err.status;
  if (status === 429 || status === 529) return send(res, 503, { error: 'Claude is busy right now. Try again shortly.' });
  if (status === 401) return send(res, 500, { error: 'The server\'s Anthropic API key was rejected.' });
  console.error(err);
  return send(res, 502, { error: (err && err.message) || 'Claude request failed.' });
}

module.exports = { askJSON, readBody, checkRequest, cleanItems, send, sendError };
