# Troubleshooting

Start with what is running:

```bash
make status                      # the agents' Pods and the Brewlet runtimes
make logs AGENT=java-spring      # the agent's log, then the sidecar's
make doctor                      # the host tools
```

The scripts keep their own kubeconfig in `build/kubeconfig` and never touch your current `kubectl`
context. To use `kubectl` yourself:

```bash
export KUBECONFIG=$PWD/build/kubeconfig
kubectl -n agents get pods
```

## The first runtime install prints an `lstat` error

`make runtimes` waits for the node to install the runtimes, and while the first image is downloading
the Brewlet worker reports `lstat /run/brewlet: no such file or directory`. That is expected: the
directory appears when the first runtime finishes installing. Pulling a runtime image can take ten
minutes or more on a slow link; the command waits up to 40 minutes. Follow it with:

```bash
kubectl get nodeprofile,runtimeimages
```

Rerunning `make runtimes` is safe at any time; runtimes that are already approved are left alone.

## A Pod is stuck

| Symptom | Likely cause | What to do |
|---------|--------------|------------|
| `ImagePullBackOff` on the agent or the sidecar | The node cannot reach the registry as `localhost:5001`. | `docker ps` should list `brewlet-agents-registry`; `docker network inspect kind` should list it too; `docker exec brewlet-agents-control-plane cat /etc/containerd/certs.d/localhost:5001/hosts.toml` should point at `http://brewlet-agents-registry:5000`. `make cluster` rewires all three. |
| `ImagePullBackOff` with `not found` | The artifact or sidecar was never pushed. | `make publish AGENT=<name>`, or `make sidecar`. |
| `Pending` with `Insufficient memory` | Docker Desktop's memory is exhausted, often by other kind clusters. | Raise Docker's memory limit, delete clusters you do not need, or deploy fewer agents. A Pod's memory request is the agent's `MEMORY_REQUEST` plus the sidecar's 128 MiB request; across these examples it ranges from 224 to 384 MiB. If an agent does not set `MEMORY_REQUEST`, the render script defaults it to 192 MiB. |
| The Pod is rejected by admission | A manifest used a tag instead of a digest, or the runtime id in the annotation is not approved. | Use `make deploy`, which renders the digest; `kubectl get runtimeimages` lists the approved ids. |
| `CrashLoopBackOff` of `agent` | The process exited. | `make logs AGENT=<name>` shows why. If `kubectl -n agents describe pod` reports `OOMKilled`, raise `MEMORY_LIMIT` in the agent's `agent.env` and run `make deploy AGENT=<name>`. |
| The Pod stays `1/2` or `0/2` | The sidecar is not ready, or `/readyz` fails. | See the next sections. |

## `/readyz` answers 503

`/readyz` is ready only when the agent can ping the Copilot CLI sidecar. When it fails with
`copilot_cli_unreachable`, look at the sidecar:

```bash
kubectl -n agents logs deployment/java-spring -c copilot-cli
```

The usual causes are an exited sidecar (look for a CLI error), a mismatch between the two
`COPILOT_CONNECTION_TOKEN` values (they both come from the `copilot-cli` Secret; if you edited it,
restart the agents), or a sidecar that is still starting. `/healthz` stays up in all of these cases,
on purpose, so the Pod is never restarted for a dependency's sake.

## `/ask` returns an error

| Response | Meaning | Fix |
|----------|---------|-----|
| 503 `copilot_not_authenticated` | The sidecar has no GitHub credentials. | `make auth`. See [GitHub authentication](authentication.md). |
| 503 `copilot_unavailable` | The agent cannot reach the sidecar. | As for `/readyz` above. |
| 504 `timeout` | No answer within two minutes. | Try again; a slow model, or a network problem on the sidecar's side. |
| 502 `agent_error` | The SDK reported another failure. | `make logs AGENT=<name>`. |
| 400 `bad_request` | The question is missing, empty or over 4000 characters, or the conversation id is malformed. | Fix the request. |

## Rotation

See [patch day](rotation.md) for what the rotation does. Three things you may meet when you run it:

* **The agents still run the old JDK after `make rotate`.** Only Pods that start after a rotation use the
  new generation. `scripts/demo-rotation.sh` waits a minute for Brewlet's operator to restart the agents
  and otherwise runs `kubectl rollout restart` itself. By hand:
  `kubectl -n agents rollout restart deployment`. See [how the Pods follow](rotation.md#how-the-pods-follow).
* **`note: current source could not be inspected for compatibility comparison: … DigestMismatch`.**
  It appears when the rewind rotates *away from* the Microsoft-registry image. The Brewlet CLI could not
  fetch that old source again to compare it with the new image, and says so. The checks on the new image
  (platforms and golden image config) still ran and passed, the rotation goes ahead, and rotating back prints
  no note. A plain `curl` of the same digest from `mcr.microsoft.com` returns bytes with the expected
  SHA-256, so the image is not corrupt; the cause is not known. In a real rotation, a skipped comparison
  means nothing warns you about a change between the old and the new image, so read the impact report
  yourself.
* **`the RuntimeImage changed while the CLI was patching it (attempt 1 of 5); asking again`.** Brewlet's
  operator updates the `RuntimeImage` status about every 30 seconds, even when nothing is happening, and
  `brewlet k8s runtime rotate` reads the object and then patches it. When the two cross, the API server
  answers `the object has been modified` and nothing is written. `scripts/runtime-rotate.sh` asks again, up
  to five times. If you run the Brewlet command by hand and see that error, run it again.

## Builds

* **Maven Central or npm is flaky.** The build scripts retry downloads. If one still fails, run the
  same `make build AGENT=<name>` again; Maven keeps what it already downloaded in `build/m2`.
* **The wrong architecture.** Everything follows the architecture of your Docker daemon (`docker info`):
  the kind node, the sidecar, the runtimes and the artifacts must all be the same, so build and run on
  the same machine. An `exec format error` means something was built for the other one;
  `make down && make up` starts clean.
* **Maven is not installed.** It does not need to be: the integrations ship a Maven Wrapper that the
  scripts use.
* **Python wheels do not download.** The Python agents install their dependencies for the target with
  `uv pip install --python-platform …`, which fetches wheels from `files.pythonhosted.org`. If your
  network blocks that host (some corporate proxies and filters do), `uv` fails after a TLS error while
  `pypi.org` itself still works. Set `UV_INDEX_URL` to a mirror you can reach.

## The documentation does not build

`make docs` uses `mkdocs` when it is installed and a pinned `squidfunk/mkdocs-material` image otherwise.
If `pip install -r docs/requirements.txt` cannot fetch from PyPI for the same reason as above, the
Docker image is the way around it: it already contains everything.

## Starting over

| Command | What it removes |
|---------|-----------------|
| `make undeploy AGENT=<name>` | One agent. |
| `make deauth` | The GitHub token from the cluster. |
| `make clean` | Build output under `build/agents` and `build/integrations`. The cluster stays. |
| `make down` | The cluster and the local registry. |

`make down` only touches the cluster and the registry created by this project (`brewlet-agents` and
`brewlet-agents-registry`); other kind clusters on the machine are left alone.
