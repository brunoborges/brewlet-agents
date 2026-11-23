import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { after, before, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

import { createApp } from '../src/app.js';

const publicDir = fileURLToPath(new URL('../public', import.meta.url));

function listen(server) {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(`http://127.0.0.1:${server.address().port}`)));
}

function close(server) {
  return new Promise((resolve) => {
    server.close(resolve);
    server.closeAllConnections();
  });
}

describe('wikipedia-frontend', () => {
  const received = [];
  let reply = { status: 200, type: 'application/json', body: '{}' };
  let agent;
  let frontend;
  let base;

  before(async () => {
    agent = createServer(async (req, res) => {
      const chunks = [];
      for await (const chunk of req) {
        chunks.push(chunk);
      }
      received.push({ method: req.method, path: req.url, body: Buffer.concat(chunks).toString() });
      res.writeHead(reply.status, { 'Content-Type': reply.type });
      res.end(reply.body);
    });
    const agentUrl = await listen(agent);
    frontend = createApp({ agentUrl, publicDir });
    base = await listen(frontend);
  });

  after(async () => {
    await close(frontend);
    await close(agent);
  });

  const post = (body) =>
    fetch(`${base}/api/summaries`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body });

  it('serves the page with a policy that allows only its own script and style', async () => {
    const response = await fetch(`${base}/`);
    assert.equal(response.status, 200);
    assert.match(await response.text(), /Wikipedia summarizer/);
    assert.match(response.headers.get('content-security-policy'), /script-src 'self'/);
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  });

  it('sends only the url to the agent and relays its answer', async () => {
    received.length = 0;
    const summary = { url: 'https://en.wikipedia.org/wiki/Java', title: 'Java', summary: 'text', truncated: false };
    reply = { status: 200, type: 'application/json', body: JSON.stringify(summary) };

    const response = await post(JSON.stringify({ url: ' https://en.wikipedia.org/wiki/Java ', extra: 'dropped' }));

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), summary);
    assert.deepEqual(received.map((r) => [r.method, r.path, JSON.parse(r.body)]), [
      ['POST', '/api/summaries', { url: ' https://en.wikipedia.org/wiki/Java ' }],
    ]);
  });

  it('relays the status and error body of the agent unchanged', async () => {
    reply = { status: 503, type: 'application/json', body: '{"error":"copilot_not_authenticated","message":"run make auth"}' };

    const response = await post('{"url":"https://en.wikipedia.org/wiki/Java"}');

    assert.equal(response.status, 503);
    assert.equal((await response.json()).error, 'copilot_not_authenticated');
  });

  it('answers 502 when the agent does not speak JSON', async () => {
    reply = { status: 200, type: 'text/html', body: '<html></html>' };

    const response = await post('{"url":"https://en.wikipedia.org/wiki/Java"}');

    assert.equal(response.status, 502);
    assert.equal((await response.json()).error, 'agent_error');
  });

  it('rejects a body that is not {"url": "<text>"} without calling the agent', async () => {
    received.length = 0;
    for (const body of ['', 'not json', 'null', '{}', '{"url": 7}', '{"url": "  "}']) {
      const response = await post(body);
      assert.equal(response.status, 400, `body: ${body}`);
      assert.equal((await response.json()).error, 'bad_request');
    }
    assert.equal(received.length, 0);
  });

  it('rejects a body that is too large', async () => {
    const response = await post(JSON.stringify({ url: 'x'.repeat(5000) }));
    assert.equal(response.status, 413);
  });

  it('allows only POST on the API and knows only its own pages', async () => {
    const get = await fetch(`${base}/api/summaries`);
    assert.equal(get.status, 405);
    assert.equal(get.headers.get('allow'), 'POST');
    assert.equal((await fetch(`${base}/..%2fpackage.json`)).status, 404);
  });

  it('answers 502 when the agent is not reachable', async () => {
    const dead = createServer();
    const agentUrl = await listen(dead);
    await close(dead);
    const lonely = createApp({ agentUrl, publicDir });
    const lonelyBase = await listen(lonely);
    try {
      const response = await fetch(`${lonelyBase}/api/summaries`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{"url":"https://en.wikipedia.org/wiki/Java"}',
      });
      assert.equal(response.status, 502);
      assert.equal((await response.json()).error, 'agent_unavailable');
    } finally {
      await close(lonely);
    }
  });
});
