# jlib-server

The data collection server of [jlib-inspector](https://github.com/brunoborges/jlib-inspector), running as an app on
the plain `java-25` Brewlet runtime. Java applications on the [`java-25-jlib`](../../../docs/observability.md#the-java-25-jlib-runtime)
runtime report to it which jars their JVM loads; the [jlib-ui](../jlib-ui/README.md) dashboard shows what it
collected. Together they answer the question jlib-inspector exists for: *which of my applications use this
library, in which version, right now?*

jlib-inspector is an experimental project, and upstream says it is not for production. Here it is a
development tool on a local cluster.

## What it does

The agent in the `java-25-jlib` runtime sends a report every 30 seconds to the server named by `JLIB_SERVER_URL`
in the application's Pod. A report holds the JDK, the command line, the JVM flags and garbage collector it can
read, **every environment variable and every system property** of the process, and every jar loaded so far.
The server keeps them in memory and serves them over HTTP:

| Request | Response |
| --- | --- |
| `PUT /api/apps/{id}` | A report. This is what the agent sends. |
| `PUT /api/apps/{id}/metadata` | A name, a description and tags for an application |
| `GET /api/apps`, `/api/apps/{id}`, `/api/apps/{id}/jars`, `/api/apps/{id}/jvm` | The applications, and what one reported |
| `GET /api/jars`, `/api/jars/{id}` | Every jar, de-duplicated across applications, and where each is used |
| `GET /api/dashboard` | The totals and the applications, as the UI shows them |
| `GET /report` | The unique jars across all applications |
| `GET /health` | The probe |

An application's id is a hash of its command line, the checksums of the jars named on it and the JDK version.
The same artifact on the same runtime keeps its id when its Pod is replaced; a rebuilt artifact is a new
application.

```bash
make observability                   # deploy it (and the UI and the Aspire dashboard)
make telemetry                       # check that the summarizer's report arrived
kubectl -n observability port-forward svc/jlib-server 8080:8080 &
curl -s localhost:8080/api/dashboard | jq '{applicationCount, jarCount, serverStatus}'
```

## What is in the artifact

```text
/app/jlib-inspector-server.jar   layer "app"   the shaded release jar (jlib-inspector 1.1.0)
/app/logging.properties          layer "app"   java.util.logging configuration
launch.json                      launch layer  /usr/jdk/bin/java -XX:MaxRAMPercentage=50 ... -jar /app/jlib-inspector-server.jar 8080
```

| layer | compressed |
| --- | --- |
| app | 119.0 KiB |
| launch | 333 B |
| whole artifact | 119.4 KiB |

Nothing here is compiled. [`build.sh`](build.sh) downloads `jlib-inspector-server-1.1.0-shaded.jar` from the
GitHub release `v1.1.0`, compares it with `JLIB_INSPECTOR_SHA256_SERVER` in [`versions.env`](../../../versions.env) and
stops on a difference. The download is cached in `build/downloads`, which `make clean` keeps. Moving to another
release means changing the version and the checksums in that file.

Measured on the kind cluster; the Deployment asks for 50m CPU, 128Mi, limit 256Mi: the working set is 86 MiB.

## Build notes

* Host tools: `curl` and `openssl`. No JDK and no Maven: the jar is the upstream release.
* The server logs every report, and every jar in it, at `INFO`, and each instrumented JVM reports every 30 s.
  [`logging.properties`](logging.properties) raises the server's own loggers to `WARNING` and keeps its start-up
  line, so the Pod's log holds errors and not a stream of reports.
* It runs on `java-25`, not on `java-25-jlib`: the server is not inspected itself.

## Run it

In this directory, `./build.sh` builds just this app. With the platform and its companion services
running, `make run` builds, publishes, deploys and smoke-tests it. To run the whole stack, use
these commands from the repository root:

```bash
make observability                   # deploy Aspire, then build, publish, deploy and smoke-test jlib-server and jlib-ui
make smoke APP=jlib-server           # the checks again
make footprint APP=jlib-server
make dashboards DASHBOARDS=jlib      # the UI, on http://localhost:3000
```

[`smoke.sh`](smoke.sh) only reads: the dashboard document, the application and jar lists and the `404` for an
application that never reported. It does not depend on which applications happen to be deployed, and it does not
write, because the server cannot delete what a check would add.

## Gotchas

* **It keeps everything in memory.** A restart of its Pod empties it; the applications come back within 30 s, as
  each one reports again. There is no way to remove one application except that restart, which is also how a
  rebuilt application's old entry goes away.
* **There is no authentication.** Anything in the cluster that can reach port 8080 can read the inventory of jars
  and write a report, including one for an application that does not exist. The Service is `ClusterIP`; on a
  shared cluster restrict who can reach it with a NetworkPolicy. Applications opt in to reporting
  (`JLIB_SERVER_URL`), so a Pod without the variable is never listed.
* **An application's report is sensitive, and the server serves it to anyone.** It names the JDK, the command line,
  every environment variable, every system property and every jar the application loads, with their paths
  (`GET /api/apps/{id}/jvm` returns the first four). The agent has no option to leave any of it out. An
  application on `java-25-jlib` must therefore keep its secrets out of its environment, its `-D` properties and its
  arguments, and read them from a file mounted from a Secret, as the
  [summarizer](../wikipedia-summarizer/README.md) does. Treat the server like the inventory it is.
* The Pod's root filesystem is read-only (`/tmp` is an `emptyDir`), and Service links are off.
