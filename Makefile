SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Every directory under agents/ with an agent.env is an agent: a Runtime Concierge in one framework.
# Each Wikipedia component with an app.env is an app: a workload that runs on a Brewlet runtime
# the same way, without being a Concierge. The per-workload targets take either one as AGENT=<name>
# or APP=<name>.
AGENTS := $(sort $(patsubst agents/%/agent.env,%,$(wildcard agents/*/agent.env)))
WIKIPEDIA := agents/wikipedia
APPS := $(sort $(patsubst $(WIKIPEDIA)/%/app.env,%,$(wildcard $(WIKIPEDIA)/*/app.env)))
AGENT ?= $(APP)
EXAMPLE_DIR := $(strip $(addprefix agents/,$(filter $(AGENTS),$(AGENT))) $(addprefix $(WIKIPEDIA)/,$(filter $(APPS),$(AGENT))))

# The documentation site builds with mkdocs when it is installed, and in this image otherwise.
MKDOCS_IMAGE := squidfunk/mkdocs-material:$(shell sed -n 's/^MKDOCS_MATERIAL_VERSION=//p' versions.env)

.PHONY: help doctor list up cluster runtimes sidecar down build publish deploy smoke undeploy agent \
        agents build-all auth deauth status logs ask whoami inspect layers footprint rotate rotate-status clean docs docs-serve \
        observability wikipedia summarize dashboards telemetry check check-agent

help: ## Show this help
	@echo "Usage: make <target> [AGENT=<name> | APP=<name>]"; echo
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo; echo "Agents: $(AGENTS)"; echo "Apps:   $(APPS)"

check-agent:
	@test "$(words $(AGENT))" = 1 && test -n "$(EXAMPLE_DIR)" || { echo "set AGENT=<name> (or APP=<name>), one of: $(AGENTS) $(APPS)" >&2; exit 2; }

doctor: ## Check the host tools this repository needs
	@scripts/checks/doctor.sh

list: ## List the example agents and apps, their language and the runtime they run on
	@printf '%-22s %-6s %-8s %-18s %s\n' NAME KIND LANGUAGE FRAMEWORK RUNTIME
	@for a in $(AGENTS); do \
	  f=agents/$$a/agent.env; \
	  printf '%-22s %-6s %-8s %-18s %s\n' "$$a" agent "$$(sed -n 's/^LANGUAGE=//p' $$f)" "$$(sed -n 's/^FRAMEWORK=//p' $$f)" "$$(sed -n 's/^RUNTIME=//p' $$f)"; \
	done
	@for a in $(APPS); do \
	  f=$(WIKIPEDIA)/$$a/app.env; \
	  printf '%-22s %-6s %-8s %-18s %s\n' "$$a" app "$$(sed -n 's/^LANGUAGE=//p' $$f)" "$$(sed -n 's/^FRAMEWORK=//p' $$f)" "$$(sed -n 's/^RUNTIME=//p' $$f)"; \
	done

# --- Platform (done once) ------------------------------------------------------------------------
up: cluster runtimes sidecar ## Bring up the whole platform: cluster, runtimes, Copilot CLI sidecar

cluster: ## Create the kind cluster, a local registry and install Brewlet
	@scripts/platform/cluster-up.sh

runtimes: ## Approve the Ops-owned language runtimes (java-25, java-25-jlib, node-24, python-3.13, dotnet-10)
	@scripts/platform/runtime-register.sh

sidecar: ## Build and push the Copilot CLI sidecar image
	@scripts/platform/sidecar-build.sh

down: ## Delete the cluster and the registry
	@scripts/platform/cluster-down.sh

# --- One agent or app ----------------------------------------------------------------------------
build: check-agent ## Build the OCI artifact of AGENT (code + dependencies + launch.json)
	@$(MAKE) --no-print-directory -C "$(EXAMPLE_DIR)" build

publish: check-agent ## Push AGENT to the local registry and verify it
	@$(MAKE) --no-print-directory -C "$(EXAMPLE_DIR)" publish

layers: check-agent ## Show what the published artifact of AGENT is made of: layers and sizes
	@scripts/workloads/layers.sh $(AGENT)

footprint: ## Artifact size and memory in use of the deployed agents and apps (or of AGENT=<name>)
	@scripts/workloads/footprint.sh $(AGENT)

deploy: check-agent ## Deploy AGENT: one Pod with the app on a Brewlet runtime, plus the CLI sidecar when it has one
	@$(MAKE) --no-print-directory -C "$(EXAMPLE_DIR)" deploy

smoke: check-agent ## Check the deployed AGENT through a port-forward
	@$(MAKE) --no-print-directory -C "$(EXAMPLE_DIR)" smoke

undeploy: check-agent ## Remove AGENT from the cluster
	@scripts/workloads/undeploy.sh $(AGENT)

agent: check-agent ## Build, publish, deploy and smoke-test AGENT
	@$(MAKE) --no-print-directory -C "$(EXAMPLE_DIR)" run

logs: check-agent ## Tail the logs of AGENT (app) and of its Copilot CLI sidecar
	@scripts/workloads/logs.sh $(AGENT)

ask: check-agent ## Ask AGENT a question: make ask AGENT=java-spring Q="Which JDK are you on?" (needs make auth)
	@scripts/workloads/ask.sh $(AGENT) "$$Q"

whoami: check-agent ## Print what AGENT reports about the runtime it is running on (its /runtime document)
	@scripts/workloads/ask.sh $(AGENT) --runtime

inspect: check-agent ## Show how AGENT's Pod is put together: runtime, artifact, sidecar, and who gets the token
	@scripts/workloads/inspect.sh $(AGENT)

# --- All agents ----------------------------------------------------------------------------------
build-all: ## Build and publish every agent and app (no cluster deployment)
	@for dir in $(addprefix agents/,$(AGENTS)) $(addprefix $(WIKIPEDIA)/,$(APPS)); do $(MAKE) --no-print-directory -C "$$dir" build publish || exit 1; done

agents: ## Build, publish, deploy and smoke-test every agent, one after the other
	@for a in $(AGENTS); do $(MAKE) --no-print-directory agent AGENT=$$a || exit 1; done

# --- The Wikipedia summarizer and the telemetry dashboards ---------------------------------------
observability: ## Deploy the telemetry stack: the Aspire OpenTelemetry dashboard and the jlib-inspector server and UI
	@$(MAKE) --no-print-directory -C $(WIKIPEDIA) observability

wikipedia: ## Deploy the Wikipedia summarizer (REST API) and its Node.js front-end (needs make up, make observability)
	@$(MAKE) --no-print-directory -C $(WIKIPEDIA) application

summarize: ## Summarize an article: make summarize URL=https://en.wikipedia.org/wiki/Java_(programming_language) [VIA=frontend]
	@$(MAKE) --no-print-directory -C $(WIKIPEDIA) summarize

telemetry: ## Check that the Java agent's report, and the apps' logs, traces and metrics, reached jlib-inspector and Aspire
	@$(MAKE) --no-print-directory -C $(WIKIPEDIA) telemetry

dashboards: ## Open the dashboards through port-forwards (all, or DASHBOARDS="brewlet jlib otel frontend") until Ctrl-C
	@$(MAKE) --no-print-directory -C $(WIKIPEDIA) dashboards

# --- Credentials and day-2 -----------------------------------------------------------------------
auth: ## Opt in: give the Copilot CLI sidecar your GitHub token (gh auth token, or COPILOT_GITHUB_TOKEN)
	@scripts/platform/copilot-auth.sh

deauth: ## Remove the GitHub token from the cluster again
	@scripts/platform/copilot-auth.sh --remove

status: ## Show the Pods of the agents and apps, and the Brewlet runtimes
	@KUBECONFIG=build/kubeconfig kubectl -n agents get pods -o wide
	@KUBECONFIG=build/kubeconfig kubectl -n observability get pods -o wide
	@KUBECONFIG=build/kubeconfig kubectl get runtimeimages

rotate: ## Demo: Ops rotates the java-25 runtime and every Java agent follows; no agent is rebuilt
	@scripts/demos/rotation.sh all

rotate-status: ## Show the JDK each Java agent runs on, next to its (unchanged) artifact digest
	@scripts/demos/rotation.sh status

# --- Housekeeping --------------------------------------------------------------------------------
check: ## Static checks: the agent contract, launch.json, scripts and manifests (no cluster needed)
	@scripts/checks/repository.sh

clean: ## Remove build output (keeps the cluster, the download caches and the approved runtime images)
	rm -rf build/agents build/apps build/integrations

docs: ## Build the documentation site into build/site (uses mkdocs when installed, otherwise Docker)
	@if command -v mkdocs >/dev/null 2>&1; then \
	  mkdocs build --strict --site-dir build/site; \
	else \
	  docker run --rm -u "$$(id -u):$$(id -g)" -v "$(CURDIR):/docs" $(MKDOCS_IMAGE) build --strict --site-dir build/site; \
	fi

docs-serve: ## Serve the documentation site locally on http://127.0.0.1:8000
	@if command -v mkdocs >/dev/null 2>&1; then \
	  mkdocs serve; \
	else \
	  docker run --rm -it -p 127.0.0.1:8000:8000 -v "$(CURDIR):/docs" $(MKDOCS_IMAGE) serve --dev-addr 0.0.0.0:8000; \
	fi
