# jlib-ui

The dashboard of [jlib-inspector](https://github.com/brunoborges/jlib-inspector), running as an app on the
`node-24` Brewlet runtime. It shows what the [jlib-server](../jlib-server/README.md) collected: every Java
application that reports, the jars its JVM loaded, where one library is used in which version, and the JVM
flags, garbage collector, environment variables and system properties it could read.

It is the dashboard for the `java-25-jlib` runtime: any application on it that sets `JLIB_SERVER_URL` appears
here (see [Observability](../../../docs/observability.md#the-java-25-jlib-runtime)). The upstream project is
experimental, and so is its UI: here it is a development tool on a local cluster.

## What it does

An Express server and a React page. The server asks the jlib-server for the dashboard document every ten
seconds and pushes what it got to the open pages over a WebSocket; the page's other requests are proxied to the
jlib-server.

```text
browser ──:3000 (page, API)──► jlib-ui (Node.js) ──every 10 s──► jlib-server
        └─:3001 (WebSocket)──►
```

| Request | Response |
| --- | --- |
| `GET /`, `/bundle.js` and its chunks | The page |
| `GET /api/dashboard`, `/api/apps`, `/api/apps/{id}`, `/api/apps/{id}/jars`, `/api/apps/{id}/jvm`, `/api/jars`, `/api/jars/{id}` | What the jlib-server holds |
| `PUT /api/apps/{id}/metadata` | A name, a description and tags for an application (forwarded) |
| `GET /api/server-config`, `POST /api/server-config` | The jlib-server the dashboard polls, and a way to change it |
| `GET /api/health` | `{"status":"healthy","jlibServerStatus":"connected",...}` |

```bash
make observability                   # deploy it (with the jlib-server and the Aspire dashboard)
make wikipedia                       # run an application on java-25-jlib that reports to it
make dashboards DASHBOARDS=jlib      # then open http://localhost:3000
```

`make dashboards` forwards ports 3000 and 3001 to the same numbers on your machine and prints the address.
The page lists the applications by name when they have one, and otherwise by the hash that identifies them.

## What is in the artifact

```text
/app/node_modules/   layer "deps"   axios, cors, express, node-cron and ws with what they need (80 packages), and package.json
/app/app.js          layer "code"   the server
/app/dist/           layer "code"   the React bundle, built by webpack
/app/LICENSE         layer "code"   upstream's MIT license, which asks for its notice to travel with copies
launch.json          launch layer   /nodejs/bin/node /app/app.js, NODE_ENV=production
```

| layer | compressed |
| --- | --- |
| deps | 1.5 MiB |
| code | 100.0 KiB |
| launch | 260 B |
| whole artifact | 1.6 MiB |

Webpack, Babel, React and the rest of upstream's build tools stay behind in the build tree: the artifact holds the
bundle and the five packages `app.js` requires. The dependencies sit in their own layer, so a change of the
pinned commit that leaves them alone leaves that layer alone too.

Measured on the kind cluster; the Deployment asks for 25m CPU, 64Mi, limit 192Mi: the working set is 90 MiB.

## Build notes

* Host tools: `git`, `node`, `npm` and `jq`, and network access to GitHub and the npm registry.
* The source is not kept in this repository. [`build.sh`](build.sh) fetches the commit that
  `JLIB_INSPECTOR_COMMIT` in [`versions.env`](../../../versions.env) names, by its hash and not by a tag or a branch,
  checks that what came back is that commit, and starts every build from it with `git clean`, so nothing from an
  earlier build survives. It uses the `frontend/` directory.
* The run-time packages are installed from a `package.json` made from upstream's (upstream lists its build tools
  under `dependencies` too), with `--omit=dev --omit=optional --ignore-scripts` and for the artifact's platform
  (`--os=linux --cpu=<x64|arm64> --libc=glibc`), not the host's. The build stops if the artifact contains a
  native addon (`*.node`): the runtime is Node 24 on glibc, and none is expected.
* **There is no lockfile.** The one upstream ships records the URLs of a private package feed, so the versions
  float within the ranges upstream's `package.json` declares, as in [`agents/node-fastify`](../../node-fastify/README.md).
  Two builds of the same commit can differ in their dependencies.

## Run it

In this directory, `./build.sh` builds just this app. With the platform and its companion services
running, `make run` builds, publishes, deploys and smoke-tests it. To run the whole stack, use
these commands from the repository root:

```bash
make observability                   # build, publish, deploy and smoke-test the three pieces of the stack
make smoke APP=jlib-ui               # the checks again
make footprint APP=jlib-ui
make dashboards DASHBOARDS=jlib      # http://localhost:3000, with the WebSocket on 3001
```

[`smoke.sh`](smoke.sh) waits up to 20 s for the dashboard to reach the jlib-server, then checks `/api/health`, that
`/` and `/bundle.js` are served and that `/api/apps` answers (an application that never reported is a `404`). It
only reads, and it does not cover the WebSocket: it forwards one port.

## Gotchas

* **The page needs two ports.** It loads its data once over HTTP and then takes every update from
  `ws://localhost:3001`, a number written into the bundle. A browser that reaches the page through a port-forward
  therefore needs port 3001 forwarded to the same number as well, and `make dashboards` does that. Without it the
  page keeps the data of its first load (it retries the socket every 5 s), and only its refresh button brings newer
  data. Served from anywhere but your own machine (behind an Ingress, say), the socket would point at that machine
  and the page would never update.
* **The browser needs internet access.** The page loads Tailwind from `cdn.tailwindcss.com` and the icons from
  `unpkg.com/lucide@latest`, which is not a pinned version. Without them the data shows, unstyled, and the scripts
  are whatever those hosts serve. This is a development tool for a local cluster.
* **There is no authentication.** Anyone who can reach port 3000 sees the jar inventory and, on each application's
  JVM page, its command line, environment variables and system properties (so an application on `java-25-jlib` must
  not hold a secret in any of them: see the [summarizer](../wikipedia-summarizer/README.md)). They can also name
  applications and, with `POST /api/server-config`, point the dashboard at another URL: the Pod then polls that
  address every ten seconds and relays what it answers. The setting lasts until the Pod restarts, when it goes back
  to `JLIB_SERVER_URL`. CORS is open. The Service is `ClusterIP` and a port-forward is the way in; on a shared
  cluster restrict who can reach the port with a NetworkPolicy.
* **The probes only say that the dashboard is up.** `/api/health` answers whether or not the jlib-server does, so
  the Pod stays Ready while the server is down; the `jlibServerStatus` field and the page itself show the
  difference, and the smoke test checks it.
* **The grace period is 5 s.** The server is PID 1, handles `SIGINT` and not `SIGTERM`, and keeps no state, so
  Kubernetes would only wait out the default 30 s before it kills it. `terminationGracePeriodSeconds: 5` keeps
  rollouts quick.
* Service links are off (`enableServiceLinks: false`): otherwise Kubernetes would inject variables such as
  `JLIB_SERVER_PORT=tcp://...` into the app's environment.
