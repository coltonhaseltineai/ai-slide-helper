// Tiny request/response doubles for testing the api/ route handlers.
'use strict';
function call(handler, body, method = 'POST') {
  return new Promise(resolve => {
    const res = {
      statusCode: 200, headers: {},
      setHeader(k, v) { this.headers[k] = v; },
      end(d) { resolve({ status: this.statusCode, body: JSON.parse(d) }); },
    };
    handler({ method, body }, res);
  });
}

// Replaces claude.askJSONMeta with a recorder that returns `reply` (or calls it with the request).
function stubClaude(reply) {
  const claude = require('../api/_claude');
  const calls = [];
  claude.askJSONMeta = async args => {
    calls.push(args);
    const data = typeof reply === 'function' ? reply(args) : reply;
    return { data, model: args.model, usage: { input: 10, output: 5 }, ms: 1, stopReason: 'end_turn' };
  };
  return calls;
}
module.exports = { call, stubClaude };
