import { readdirSync, readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join } from 'node:path';

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
};

// The request is {"url": "..."}; anything near this size is not one.
const MAX_BODY_BYTES = 4096;

// The page loads only its own script and stylesheet, talks only to this server and cannot be framed.
const SECURITY_HEADERS = {
  'Content-Security-Policy':
    "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; " +
    "base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
};

const problem = (error, message) => ({ error, message });

/** Reads every file of publicDir once. A request can only name one of these routes, never a path. */
function loadAssets(publicDir) {
  const assets = new Map();
  for (const name of readdirSync(publicDir)) {
    const type = CONTENT_TYPES[extname(name)];
    if (type) {
      assets.set(name === 'index.html' ? '/' : `/${name}`, { type, body: readFileSync(join(publicDir, name)) });
    }
  }
  return assets;
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, { ...SECURITY_HEADERS, ...headers });
  res.end(body);
}

function sendJson(res, status, value, headers = {}) {
  send(res, status, JSON.stringify(value), {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
    ...headers,
  });
}

/** The request body as text, or null once it exceeds the limit. */
async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      return null;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

/**
 * The front-end is a thin proxy: it checks the shape of the request, hands the URL to the agent and relays
 * the agent's answer, status included. Judging the URL and writing the summary are the agent's work.
 */
async function summarize(req, res, { agentUrl, agentTimeoutMs }) {
  const raw = await readBody(req);
  if (raw === null) {
    return sendJson(res, 413, problem('payload_too_large', 'the request body is too large'), { Connection: 'close' });
  }
  let url;
  try {
    ({ url } = JSON.parse(raw));
  } catch {
    // Reported below, together with a body of the wrong shape.
  }
  if (typeof url !== 'string' || url.trim() === '') {
    return sendJson(
      res,
      400,
      problem('bad_request', 'the request body must be JSON like {"url": "https://en.wikipedia.org/wiki/Java_(programming_language)"}'),
    );
  }

  let status;
  let text;
  let isJson;
  try {
    const upstream = await fetch(new URL('/api/summaries', agentUrl), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url }),
      signal: AbortSignal.timeout(agentTimeoutMs),
    });
    status = upstream.status;
    isJson = (upstream.headers.get('content-type') ?? '').includes('application/json');
    text = await upstream.text();
  } catch (error) {
    console.error(`request to the agent failed: ${error.name}: ${error.message}`);
    return error.name === 'TimeoutError'
      ? sendJson(res, 504, problem('timeout', 'the summarizer took too long to answer'))
      : sendJson(res, 502, problem('agent_unavailable', 'the wikipedia-summarizer service is not reachable'));
  }
  if (!isJson) {
    return sendJson(res, 502, problem('agent_error', `unexpected answer from the summarizer (HTTP ${status})`));
  }
  send(res, status, text, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
}

/**
 * @param {object} options
 * @param {string} options.agentUrl base URL of the wikipedia-summarizer
 * @param {string} options.publicDir directory with the page, its script and its stylesheet
 * @param {number} [options.agentTimeoutMs] how long to wait for the agent; its own model timeout is two minutes
 */
export function createApp({ agentUrl, publicDir, agentTimeoutMs = 150_000 }) {
  const assets = loadAssets(publicDir);
  const settings = { agentUrl, agentTimeoutMs };

  async function handle(req, res) {
    const { pathname } = new URL(req.url, 'http://localhost');
    if (pathname === '/healthz') {
      return sendJson(res, 200, { status: 'UP' });
    }
    if (pathname === '/api/summaries') {
      return req.method === 'POST'
        ? summarize(req, res, settings)
        : sendJson(res, 405, problem('method_not_allowed', 'use POST'), { Allow: 'POST' });
    }
    const asset = assets.get(pathname);
    if (asset && (req.method === 'GET' || req.method === 'HEAD')) {
      return send(res, 200, asset.body, { 'Content-Type': asset.type, 'Cache-Control': 'no-cache' });
    }
    return sendJson(res, 404, problem('not_found', 'no such page'));
  }

  return createServer((req, res) => {
    handle(req, res).catch((error) => {
      console.error(error);
      if (res.headersSent) {
        res.end();
      } else {
        sendJson(res, 500, problem('internal_error', 'unexpected error'));
      }
    });
  });
}
