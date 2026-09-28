// LEGACY: older Mac app builds asked for hint words here. Hint words are no longer used,
// so this returns an empty list per line (same response shape) without calling Claude.
// Retire once the "legacy expand" log lines stop.
const { readBody, checkRequest, cleanItems, send } = require('./_claude');

module.exports = async (req, res) => {
  console.log('legacy expand');
  const body = readBody(req);
  const problem = checkRequest(req, body);
  if (problem) return send(res, problem === 'Wrong access code.' ? 401 : 400, { error: problem });
  const items = cleanItems(body.items);
  if (!items) return send(res, 400, { error: 'Send 1-80 outline lines as "items".' });
  return send(res, 200, { hints: items.map(() => []) });
};
