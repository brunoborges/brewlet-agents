# wikipedia-frontend

A basic Node.js front-end for the [`wikipedia-summarizer`](../wikipedia-summarizer/README.md) agent: one page with
a field for the address of a Wikipedia article and a button, which shows the summary the agent returns. It
is a small proxy and a page, and it has no dependencies: not one package is installed to build or run it.

It runs on the plain `node-24` Brewlet runtime, in a Pod of its own, and it never talks to Copilot. The agent
does that, so this Pod has no sidecar and no GitHub credentials.

## What it does

```text
browser ──► wikipedia-frontend (Node.js) ──POST /api/summaries──► wikipedia-summarizer ──► Copilot CLI sidecar
```

| Request | Response |
| --- | --- |
| `GET /`, `/app.js`, `/styles.css` | The page, its script and its stylesheet, read once at start-up |
| `POST /api/summaries` | Checks that the body is `{"url": "<text>"}` and sends the same request to the summarizer. Whatever it answers, status and body, goes back unchanged. |
| `GET /healthz` | `200 {"status":"UP"}` |

The front-end does not judge the address: the summarizer does, and its `400 bad_request` or `404 article_not_found`
reaches the page as it is. What the front-end answers itself:

| Status | `error` | When |
| --- | --- | --- |
| 400 | `bad_request` | The body is not JSON, or has no `url` that is text |
| 405 | `method_not_allowed` | Anything but `POST` on `/api/summaries` (`Allow: POST`) |
| 413 | `payload_too_large` | The body is over 4096 bytes |
| 502 | `agent_unavailable` | The summarizer's Service is not reachable |
| 502 | `agent_error` | The summarizer answered with something that is not JSON |
| 504 | `timeout` | No answer within 150 s (the summarizer's model timeout is two minutes) |

The page is built to show text it does not trust: the summary is added with `textContent`, never as HTML (the
model's `**bold**` and `- bullets` are turned into elements by the script). The response headers allow the page
to load only its own script and stylesheet and to talk only to its own server
(`Content-Security-Policy: default-src 'none'; script-src 'self'; ...`), forbid framing, and set `nosniff` and
`Referrer-Policy: no-referrer`. A request can only name one of the files in `public/` (the routes are the files
read at start-up), never a path.

## What is in the artifact

```text
/app/package.json   layer "code"    only for "type": "module": Node loads /app/src/*.js as ES modules
/app/src/*.js       layer "code"    the server (main.js reads the settings, app.js is the server)
/app/public/*       layer "code"    index.html, app.js, styles.css
launch.json         launch layer    /nodejs/bin/node /app/src/main.js, NODE_ENV=production
```

| layer | compressed |
| --- | --- |
| code | 5.5 KiB |
| launch | 261 B |
| whole artifact | 5.7 KiB |

There is no `node_modules` and no `deps` layer: the server uses `node:http`, `node:fs`, `node:path` and the `fetch`
of Node 24. Node itself is the `node-24` runtime (`/nodejs`).

Measured on the kind cluster; the Deployment asks for 25m CPU, 48Mi, limit 128Mi: the working set is 71 MiB,
`make footprint` prints it for what is deployed.

## Configuration

| Environment variable | In the Pod | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | Where the server listens (`3000` when unset) |
| `AGENT_URL` | `http://wikipedia-summarizer` | The summarizer's Service, in the same namespace (`http://localhost:8080` when unset). An invalid URL stops the start-up. |

The Service listens on port 80 and forwards to the container's port 8080.

## Build notes

* Host tool: Node.js 24+, for the tests only. [`build.sh`](build.sh) runs `node --test` (eight tests, with a stand-in
  for the summarizer on a local port: no network, no cluster) and then copies `package.json`, `src/` and `public/`
  into the one `code` layer ([`layers`](layers)).
* The tests check what the front-end promises: the page and its policy, that only the `url` is sent on and the
  answer relayed with its status, the 502 cases, the body rules and the routes.

## Run it

```bash
make up && make observability        # the platform, and the telemetry stack the summarizer reports to
make auth                            # once: the summaries need your GitHub token in the cluster
make wikipedia                       # build, publish, deploy and smoke-test the summarizer and this app
make dashboards DASHBOARDS=frontend  # then open http://localhost:8080
make summarize URL='https://en.wikipedia.org/wiki/Kubernetes' VIA=frontend   # the same request, without a browser
make smoke APP=wikipedia-frontend    # the checks again
```

[`smoke.sh`](smoke.sh) checks that the three files are served, that a body that is not JSON is a `400`, that the
summarizer's own `400` for an address that is not Wikipedia comes through, and that a real summary goes through
both apps. Without credentials in the cluster it expects the documented `503 copilot_not_authenticated`;
`REQUIRE_AUTH=1` makes the summary mandatory.

## Gotchas

* **Anyone who can reach it can use your Copilot quota.** There is no login and no rate limit, and every summary
  is a model request made with the token `make auth` stored in the cluster. The Service is `ClusterIP`: `make
  dashboards` or `kubectl port-forward` is the way in, and only for whoever has access to the cluster.
* **Service links are off** (`enableServiceLinks: false`): otherwise Kubernetes would inject variables such as
  `WIKIPEDIA_SUMMARIZER_PORT=tcp://...` into the app's environment.
* The container's root filesystem is read-only; `/tmp` is an `emptyDir` in the Pod.
