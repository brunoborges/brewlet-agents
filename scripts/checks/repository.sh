#!/usr/bin/env bash
# Static checks that need neither a cluster nor Docker. They guard the contract every agent and app
# shares (agents/README.md, agents/wikipedia/README.md), the Ops runtime catalog, each workload's
# deployment.yaml, the telemetry stack's manifest, the documentation wiring and the scripts
# themselves. CI runs them on every push.
#
#   scripts/checks/repository.sh            (or: make check)
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
need jq git
cd "$ROOT" || exit 1
failures=0
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; failures=$((failures + 1)); }

# YAML on stdin to a JSON array (one element per document) on stdout, using whichever of Ruby or
# PyYAML is installed.
yaml_to_json() {
  if command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_stream($stdin.read))'
  elif python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import json, sys, yaml; print(json.dumps(list(yaml.safe_load_all(sys.stdin))))'
  else
    return 127
  fi
}

# A digest that cannot exist, to pin manifests without a registry.
zeros="0000000000000000000000000000000000000000000000000000000000000000"

# launch.json is the only contract with the runtime. Arguments: name, directory, runtime id.
check_launch_json() {
  local name="$1" dir="$2" runtime="$3" interpreter
  if [ ! -f "$dir/launch.json" ]; then
    fail "$name: launch.json is missing"
  elif ! jq -e . "$dir/launch.json" >/dev/null 2>&1; then
    fail "$name: launch.json is not valid JSON"
  else
    interpreter="$(env_value "runtimes/$runtime.env" INTERPRETER 2>/dev/null)"
    jq -e --arg rt "$runtime" --arg interp "$interpreter" '
        .schemaVersion == 1
        and .runtimeImages == [$rt]
        and (.process.entrypoint[0] == $interp)
        and (.process.workingDir == "/app")
        and (((.env // {}) | has("PATH")) | not)
      ' "$dir/launch.json" >/dev/null \
      || fail "$name: launch.json must have schemaVersion 1, runtimeImages [\"$runtime\"], entrypoint[0] \"$interpreter\", workingDir \"/app\" and no PATH"
  fi
}

# layers: "<directory>:<path in the artifact>", one per line. Arguments: name, directory.
check_layers() {
  local name="$1" dir="$2" line layer_re='^[A-Za-z0-9._-]+:/app(/[A-Za-z0-9._/-]*)?$'
  [ -f "$dir/layers" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ $layer_re ]] || fail "$name: layers entry '$line' must look like <directory>:/app"
  done < "$dir/layers"
}

# Verify the local entry points without building an artifact or touching the cluster.
check_example_commands() {
  local dir="$1"
  [ -x "$dir/build.sh" ] || fail "$dir/build.sh is missing or not executable"
  make -n -C "$dir" build publish deploy smoke run >/dev/null || fail "$dir: incomplete example Makefile"
}

# A Pod template that Pod Security "restricted" admits (the namespaces enforce it), with every
# container read-only, unprivileged and without capabilities.
hardened_jq='
  def hardened($t):
    ($t.spec.securityContext.seccompProfile.type == "RuntimeDefault")
    and ([$t.spec.containers[], ($t.spec.initContainers // [])[]
          | (if .securityContext.runAsNonRoot == null then $t.spec.securityContext.runAsNonRoot
             else .securityContext.runAsNonRoot end) == true
            and .securityContext.readOnlyRootFilesystem == true
            and .securityContext.allowPrivilegeEscalation == false
            and .securityContext.capabilities.drop == ["ALL"]] | all);
'

# --- versions.env -------------------------------------------------------------------------------
log "versions.env"
for v in BREWLET_VERSION CLUSTER_NAME REGISTRY_PORT COPILOT_CLI_VERSION COPILOT_CLI_IMAGE FETCH_IMAGE \
         INTEGRATIONS_SHA SIDECAR_NAME SIDECAR_PORT AGENT_NAMESPACE AGENT_SECRET \
         OBSERVABILITY_NAMESPACE JLIB_INSPECTOR_VERSION JLIB_INSPECTOR_COMMIT JLIB_INSPECTOR_SHA256_AGENT \
         JLIB_INSPECTOR_SHA256_SERVER OTEL_DASHBOARD OTEL_DASHBOARD_IMAGE; do
  [ -n "${!v:-}" ] || fail "versions.env does not set $v"
done
for v in INTEGRATIONS_SHA JLIB_INSPECTOR_COMMIT; do
  [[ "${!v:-}" =~ ^[0-9a-f]{40}$ ]] || fail "$v must be a full 40-character commit"
done
for v in JLIB_INSPECTOR_SHA256_AGENT JLIB_INSPECTOR_SHA256_SERVER; do
  [[ "${!v:-}" =~ ^[0-9a-f]{64}$ ]] || fail "$v must be a SHA-256 (64 hex characters)"
done
[[ "${OTEL_DASHBOARD_IMAGE:-}" =~ @sha256:[0-9a-f]{64}$ ]] || fail "OTEL_DASHBOARD_IMAGE must be pinned by digest (name@sha256:<64 hex>)"
[[ "${COPILOT_CLI_IMAGE:-}" == "ghcr.io/github/copilot-cli:${COPILOT_CLI_VERSION:-}@sha256:"* \
   && "${COPILOT_CLI_IMAGE:-}" =~ @sha256:[0-9a-f]{64}$ ]] \
  || fail "COPILOT_CLI_IMAGE must be ghcr.io/github/copilot-cli:<COPILOT_CLI_VERSION> pinned by digest (@sha256:<64 hex>)"

# --- the Ops runtime catalog ---------------------------------------------------------------------
# A runtime names an approved image (IMAGE). A derived runtime (BASE, CONTEXT) has none: it is built
# over the approved image of its BASE by scripts/platform/runtime-build.sh, so only its layers may differ.
log "runtimes"
runtime_ids=" "
for f in runtimes/*.env; do
  id="$(basename "$f" .env)"
  runtime_ids="$runtime_ids$id "
  for key in RUNTIME_UID RUNTIME_GID ECOSYSTEM ABI MOUNT_PATHS DESCRIPTION INTERPRETER; do
    [ -n "$(env_value "$f" "$key")" ] || fail "$f: $key is missing"
  done
  [[ "$(env_value "$f" INTERPRETER)" == /* ]] || fail "$f: INTERPRETER must be an absolute path"
  base="$(env_value "$f" BASE)"
  if [ -z "$base" ]; then
    [[ "$(env_value "$f" IMAGE)" =~ @sha256:[0-9a-f]{64}$ ]] || fail "$f: IMAGE must be pinned by digest (name@sha256:<64 hex>)"
    continue
  fi
  context="$(env_value "$f" CONTEXT)"
  [ -z "$(env_value "$f" IMAGE)" ] || fail "$f: a derived runtime has no IMAGE; the build produces it"
  [ -f "$context/Dockerfile" ] || fail "$f: CONTEXT '$context' must be a directory with a Dockerfile"
  if [ ! -f "runtimes/$base.env" ]; then
    fail "$f: BASE '$base' is not in the catalog"
  elif [ -z "$(env_value "runtimes/$base.env" IMAGE)" ]; then
    fail "$f: BASE '$base' must have a pinned IMAGE; a derived runtime cannot be a base"
  else
    for key in RUNTIME_UID RUNTIME_GID ECOSYSTEM ABI MOUNT_PATHS INTERPRETER; do
      [ "$(env_value "$f" "$key")" = "$(env_value "runtimes/$base.env" "$key")" ] \
        || fail "$f: $key must equal $base's ($(env_value "runtimes/$base.env" "$key")): only the layers differ"
    done
  fi
done

# --- the agents ----------------------------------------------------------------------------------
log "agents"
canonical="agents/java-spring/src/main/resources/prompts/concierge.md"
[ -f "$canonical" ] || fail "$canonical (the reference system prompt) is missing"
count=0
for env_file in agents/*/agent.env; do
  [ -f "$env_file" ] || continue
  dir="$(dirname "$env_file")"
  name="$(basename "$dir")"
  count=$((count + 1))
  bad=$failures

  for key in AGENT_NAME LANGUAGE FRAMEWORK RUNTIME; do
    [ -n "$(env_value "$env_file" "$key")" ] || fail "$name: agent.env is missing $key"
  done
  [ "$(env_value "$env_file" AGENT_NAME)" = "$name" ] || fail "$name: AGENT_NAME must equal the directory name"
  language="$(env_value "$env_file" LANGUAGE)"
  runtime="$(env_value "$env_file" RUNTIME)"
  case "$language" in java|node|python|dotnet) ;; *) fail "$name: LANGUAGE must be java, node, python or dotnet (is '$language')" ;; esac

  # The runtime exists and serves this language.
  runtime_env="runtimes/$runtime.env"
  if [ -f "$runtime_env" ]; then
    [ "$(env_value "$runtime_env" ECOSYSTEM)" = "$language" ] \
      || fail "$name: runtime $runtime is for $(env_value "$runtime_env" ECOSYSTEM), the agent is $language"
  else
    fail "$name: runtime '$runtime' is not in the catalog (runtimes/*.env)"
  fi

  check_launch_json "$name" "$dir" "$runtime"
  check_layers "$name" "$dir"

  check_example_commands "$dir"
  [ -f "$dir/README.md" ] || fail "$name: README.md is missing"

  # The system prompt is one file, identical in every agent, loaded as a resource.
  prompts="$(find "$dir" -path '*/prompts/concierge.md' -not -path '*/node_modules/*' -not -path '*/target/*' \
    -not -path '*/dist/*' -not -path '*/bin/*' -not -path '*/obj/*' -not -path '*/.venv/*' 2>/dev/null)"
  if [ -z "$prompts" ]; then
    fail "$name: no prompts/concierge.md in the agent"
  else
    while IFS= read -r p; do
      cmp -s "$canonical" "$p" || fail "$name: $p differs from $canonical"
    done <<<"$prompts"
  fi

  # deployment.yaml is the whole manifest. Pin it the way the deploy step does, then check that it
  # still agrees with agent.env and versions.env and describes what Brewlet needs.
  if [ ! -f "$dir/deployment.yaml" ]; then
    fail "$name: deployment.yaml is missing"
  elif manifest="$(scripts/workloads/pin.sh "$name" "$REGISTRY_HOST/agents/$name@sha256:$zeros" 2>&1)"; then
    if json="$(yaml_to_json <<<"$manifest" 2>&1)"; then
      jq -e --arg name "$name" --arg ns "$AGENT_NAMESPACE" --arg rt "$runtime" --arg lang "$language" \
            --arg secret "$AGENT_SECRET" --arg cli_url "127.0.0.1:$SIDECAR_PORT" --arg cli_image "$COPILOT_CLI_IMAGE" '
          def env_of($c): ($c.env // []) | map({(.name): (.value // .valueFrom)}) | add;
          (map(select(.kind == "Deployment")) | first) as $d
          | ($d.spec.template) as $t
          | ($t.spec.containers[0]) as $agent
          | ($t.spec.initContainers[0]) as $sidecar
          | env_of($agent) as $e
          | ([.[].kind] | sort) == ["Deployment", "Service", "ServiceAccount"]
            and all(.[]; .metadata.name == $name and .metadata.namespace == $ns)
            and $t.metadata.labels["brewlet-agents.dev/language"] == $lang
            and $t.metadata.annotations["runtime-image.brewlet.sh/agent"] == $rt
            and $t.spec.runtimeClassName == "brewlet"
            and ([$t.spec.containers[].name] == ["agent"])
            and ([$t.spec.initContainers[].name] == ["copilot-cli"])
            and ($agent.image | test("@sha256:[0-9a-f]{64}$"))
            and $sidecar.image == $cli_image
            and $sidecar.args == ["--host", "127.0.0.1"]
            and $d.metadata.annotations["brewlet.sh/restart-on-rotation"] == "true"
            and $e.AGENT_NAME == $name
            and $e.AGENT_RUNTIME_ID == $rt
            and $e.COPILOT_CLI_URL == $cli_url
            and $e.PORT == ($agent.ports[0].containerPort | tostring)
            and $e.COPILOT_CONNECTION_TOKEN.secretKeyRef.name == $secret
            and ([$agent, $sidecar | .resources | .requests.memory and .limits.memory] | all)
        ' <<<"$json" >/dev/null \
        || fail "$name: deployment.yaml disagrees with agent.env or versions.env (name, namespace, language, runtime, secret, sidecar image and loopback address, port) or is missing a pinned image, the Brewlet runtime class or memory requests and limits"
    elif [ $? -eq 127 ]; then
      warn "$name: no Ruby or PyYAML to parse deployment.yaml; skipped"
    else
      fail "$name: deployment.yaml is not valid YAML: $json"
    fi
  else
    fail "$name: deployment.yaml cannot be pinned: $manifest"
  fi

  [ "$failures" -gt "$bad" ] || ok "$name"
done
[ "$count" -gt 0 ] || fail "no agents found under agents/"

# --- the apps ------------------------------------------------------------------------------------
# An app is any other workload on a Brewlet runtime (agents/wikipedia/<name>/app.env, agents/wikipedia/README.md): no Runtime
# Concierge contract, a container called "app", and a namespace of its own choosing. Its name is
# unique across agents and apps. The apps that run on the java-25-jlib runtime report to the
# telemetry stack, so their manifests have to name where it is. That agent also reports the whole
# process environment, so such an app takes no Secret as an environment variable: it mounts the
# keys it needs as files.
log "apps"
jlib_runtime=java-25-jlib
jlib_url="http://jlib-server.$OBSERVABILITY_NAMESPACE.svc:$(env_value agents/wikipedia/jlib-server/app.env SERVICE_PORT)"
otlp_url="http://$OTEL_DASHBOARD.$OBSERVABILITY_NAMESPACE.svc:18890"
app_count=0
for env_file in agents/wikipedia/*/app.env; do
  [ -f "$env_file" ] || continue
  dir="$(dirname "$env_file")"
  name="$(basename "$dir")"
  app_count=$((app_count + 1))
  bad=$failures

  for key in APP_NAME LANGUAGE FRAMEWORK RUNTIME; do
    [ -n "$(env_value "$env_file" "$key")" ] || fail "$name: app.env is missing $key"
  done
  [ "$(env_value "$env_file" APP_NAME)" = "$name" ] || fail "$name: APP_NAME must equal the directory name"
  [ ! -e "agents/$name" ] || fail "$name: agents/$name exists too; names are unique across agents and apps"
  language="$(env_value "$env_file" LANGUAGE)"
  runtime="$(env_value "$env_file" RUNTIME)"
  namespace="$(env_value "$env_file" NAMESPACE)"
  namespace="${namespace:-$AGENT_NAMESPACE}"
  sidecar="$(env_value "$env_file" SIDECAR)"
  integrations="$(env_value "$env_file" INTEGRATIONS)"
  health="$(env_value "$env_file" HEALTH_PATH)"
  health="${health:-/healthz}"
  port="$(env_value "$env_file" SERVICE_PORT)"
  port="${port:-80}"
  case "$language" in java|node|python|dotnet) ;; *) fail "$name: LANGUAGE must be java, node, python or dotnet (is '$language')" ;; esac

  # The runtime exists and serves this language.
  runtime_env="runtimes/$runtime.env"
  if [ -f "$runtime_env" ]; then
    [ "$(env_value "$runtime_env" ECOSYSTEM)" = "$language" ] \
      || fail "$name: runtime $runtime is for $(env_value "$runtime_env" ECOSYSTEM), the app is $language"
  else
    fail "$name: runtime '$runtime' is not in the catalog (runtimes/*.env)"
  fi

  # The optional settings agree with what the scripts do with them.
  [[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "$name: NAMESPACE '$namespace' is not a namespace name"
  case "$sidecar" in
    '') ;;
    "$SIDECAR_NAME")
      [ "$namespace" = "$AGENT_NAMESPACE" ] \
        || fail "$name: an app with the $SIDECAR_NAME sidecar runs in namespace $AGENT_NAMESPACE, where Secret $AGENT_SECRET lives" ;;
    *) fail "$name: SIDECAR must be empty or $SIDECAR_NAME (is '$sidecar')" ;;
  esac
  [ -z "$integrations" ] || [ -f "scripts/integrations/languages/$integrations.sh" ] \
    || fail "$name: INTEGRATIONS '$integrations' is not a language with scripts/integrations/languages/$integrations.sh"
  [[ "$health" == /* ]] || fail "$name: HEALTH_PATH must start with /"
  { [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || fail "$name: SERVICE_PORT must be a port number"

  check_launch_json "$name" "$dir" "$runtime"
  check_layers "$name" "$dir"

  check_example_commands "$dir"
  [ -x "$dir/smoke.sh" ] || fail "$name: smoke.sh is missing or not executable (scripts/workloads/app-smoke.sh runs it)"
  [ -f "$dir/README.md" ] || fail "$name: README.md is missing"

  # deployment.yaml is the whole manifest. Pin it the way the deploy step does, then check that it
  # still agrees with app.env and versions.env and describes what Brewlet and the namespace need.
  if [ ! -f "$dir/deployment.yaml" ]; then
    fail "$name: deployment.yaml is missing"
  elif manifest="$(scripts/workloads/pin.sh "$name" "$REGISTRY_HOST/apps/$name@sha256:$zeros" 2>&1)"; then
    if json="$(yaml_to_json <<<"$manifest" 2>&1)"; then
      jq -e --arg name "$name" --arg ns "$namespace" --arg rt "$runtime" --arg lang "$language" \
            --arg health "$health" --arg port "$port" --arg sidecar "$sidecar" --arg secret "$AGENT_SECRET" \
            --arg cli_url "127.0.0.1:$SIDECAR_PORT" --arg cli_image "$COPILOT_CLI_IMAGE" --arg jlib_runtime "$jlib_runtime" \
            --arg jlib_url "$jlib_url" --arg otlp_url "$otlp_url" "$hardened_jq"'
          def env_of($c): (($c.env // []) | map({(.name): (.value // .valueFrom)}) | add) // {};
          (map(select(.kind == "Deployment")) | first) as $d
          | (map(select(.kind == "Service")) | first) as $s
          | ($d.spec.template) as $t
          | ($t.spec.containers[0]) as $app
          | env_of($app) as $e
          | ([.[].kind] | sort) == ["Deployment", "Service", "ServiceAccount"]
            and all(.[]; .metadata.name == $name and .metadata.namespace == $ns)
            and $d.metadata.labels["app.kubernetes.io/part-of"] == "brewlet-agents"
            and $t.metadata.labels["brewlet-agents.dev/language"] == $lang
            and $t.metadata.annotations["runtime-image.brewlet.sh/app"] == $rt
            and $t.spec.runtimeClassName == "brewlet"
            and $t.spec.enableServiceLinks == false
            and $t.spec.automountServiceAccountToken == false
            and ([$t.spec.containers[].name] == ["app"])
            and ($app.image | test("@sha256:[0-9a-f]{64}$"))
            and $d.metadata.annotations["brewlet.sh/restart-on-rotation"] == "true"
            and ([$t.spec.containers[], ($t.spec.initContainers // [])[] | .resources.requests.memory and .resources.limits.memory] | all)
            and hardened($t)
            and $app.livenessProbe.httpGet.path == $health
            and $s.spec.selector == $d.spec.selector.matchLabels
            and $s.spec.ports[0].port == ($port | tonumber)
            and ([$app.ports[] | .name, .containerPort] | index($s.spec.ports[0].targetPort) != null)
            and (if $sidecar == "" then ($t.spec.initContainers // []) == []
                 else ([$t.spec.initContainers[].name] == [$sidecar])
                   and $t.spec.initContainers[0].image == $cli_image
                   and $t.spec.initContainers[0].args == ["--host", "127.0.0.1"]
                   and $t.spec.initContainers[0].restartPolicy == "Always"
                   and $e.COPILOT_CLI_URL == $cli_url
                   and env_of($t.spec.initContainers[0]).COPILOT_CONNECTION_TOKEN.secretKeyRef.name == $secret
                   and (if $rt == $jlib_runtime
                        then [$t.spec.volumes[]? | select(.secret.secretName == $secret) | .secret.items[]?.key] == ["connection-token"]
                        else $e.COPILOT_CONNECTION_TOKEN.secretKeyRef.name == $secret end)
                 end)
            and all($t.spec.volumes[]? | select(.secret != null); (.secret.items // []) | length > 0)
            and (if $rt == $jlib_runtime
                 then $e.JLIB_SERVER_URL == $jlib_url and $e.OTEL_EXPORTER_OTLP_ENDPOINT == $otlp_url
                   and ([$app.env[]? | select(.valueFrom.secretKeyRef != null
                          or (.name | test("TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|API_?KEY|PRIVATE_?KEY"; "i")))] | length) == 0
                   and ([$app.envFrom[]? | select(.secretRef != null)] | length) == 0
                 else true end)
        ' <<<"$json" >/dev/null \
        || fail "$name: deployment.yaml disagrees with app.env or versions.env (name, namespace, language, runtime, health path, Service port, sidecar image, loopback address and Secret, telemetry endpoints) or lacks a pinned image, the Brewlet runtime class, memory requests and limits, enableServiceLinks: false or the restricted security context; on $jlib_runtime the agent reports the whole environment, so no environment variable may come from a Secret or be named like a credential, and every Secret volume must list the keys it mounts (the GitHub token in $AGENT_SECRET stays with the sidecar)"
    elif [ $? -eq 127 ]; then
      warn "$name: no Ruby or PyYAML to parse deployment.yaml; skipped"
    else
      fail "$name: deployment.yaml is not valid YAML: $json"
    fi
  else
    fail "$name: deployment.yaml cannot be pinned: $manifest"
  fi

  [ "$failures" -gt "$bad" ] || ok "$name"
done
[ "$app_count" -gt 0 ] || fail "no components found under agents/wikipedia/"

# --- the telemetry stack -------------------------------------------------------------------------
# The OpenTelemetry dashboard (agents/wikipedia/observability/otel-dashboard.yaml) is not on a Brewlet runtime;
# it is an ordinary container, pinned by the digest in versions.env the way agents/wikipedia/observability/deploy.sh
# applies it. The apps that report to it name its Service, so this is where that name is defined.
log "observability"
bad=$failures
if manifest="$(agents/wikipedia/observability/deploy.sh --manifest 2>&1)"; then
  if json="$(yaml_to_json <<<"$manifest" 2>&1)"; then
    jq -e --arg name "$OTEL_DASHBOARD" --arg ns "$OBSERVABILITY_NAMESPACE" --arg image "$OTEL_DASHBOARD_IMAGE" "$hardened_jq"'
        def env_of($c): (($c.env // []) | map({(.name): (.value // .valueFrom)}) | add) // {};
        (map(select(.kind == "Deployment")) | first) as $d
        | (map(select(.kind == "Service")) | first) as $s
        | ($d.spec.template) as $t
        | ($t.spec.containers[0]) as $c
        | env_of($c) as $e
        | ([.[].kind] | sort) == ["Deployment", "Service", "ServiceAccount"]
          and all(.[]; .metadata.name == $name and .metadata.namespace == $ns)
          and $d.metadata.labels["app.kubernetes.io/part-of"] == "brewlet-agents"
          and $t.spec.enableServiceLinks == false
          and $t.spec.automountServiceAccountToken == false
          and ([$t.spec.containers[].name] == ["dashboard"])
          and $c.image == $image
          and ($c.resources.requests.memory and $c.resources.limits.memory)
          and hardened($t)
          and $s.spec.selector == $d.spec.selector.matchLabels
          and ([$s.spec.ports[] | {(.name): .port}] | add) == {"ui": 18888, "otlp-grpc": 18889, "otlp-http": 18890}
          and $e.DASHBOARD__FRONTEND__BROWSERTOKEN.secretKeyRef == {"name": $name, "key": "browser-token"}
          and $e.DASHBOARD__API__PRIMARYAPIKEY.secretKeyRef == {"name": $name, "key": "api-key"}
      ' <<<"$json" >/dev/null \
      || fail "otel-dashboard.yaml disagrees with versions.env (name, namespace, image digest) or lacks the Services' ports 18888, 18889 and 18890, the Secret's browser-token and api-key, enableServiceLinks: false, memory requests and limits or the restricted security context"
  elif [ $? -eq 127 ]; then
    warn "no Ruby or PyYAML to parse the OpenTelemetry dashboard's manifest; skipped"
  else
    fail "agents/wikipedia/observability/otel-dashboard.yaml is not valid YAML: $json"
  fi
else
  fail "the OpenTelemetry dashboard's manifest cannot be pinned: $manifest"
fi
[ "$failures" -gt "$bad" ] || ok "$OTEL_DASHBOARD"

# --- documentation wiring --------------------------------------------------------------------------
log "documentation"
if [ -f mkdocs.yml ]; then
  for env_file in agents/*/agent.env; do
    name="$(basename "$(dirname "$env_file")")"
    stub="docs/agents/$name.md"
    if [ ! -f "$stub" ]; then
      fail "$name: $stub is missing (copy a sibling stub: the hook fills it from agents/$name/README.md)"
    else
      grep -q "source: agents/$name/README.md" "$stub" || fail "$stub: missing the 'source: agents/$name/README.md' marker"
    fi
    grep -q "agents/$name.md" mkdocs.yml || fail "$name: not in the mkdocs.yml nav"
  done
  for env_file in agents/wikipedia/*/app.env; do
    [ -f "$env_file" ] || continue
    name="$(basename "$(dirname "$env_file")")"
    stub="docs/apps/$name.md"
    if [ ! -f "$stub" ]; then
      fail "$name: $stub is missing (copy a sibling stub: the hook fills it from agents/wikipedia/$name/README.md)"
    else
      grep -q "source: agents/wikipedia/$name/README.md" "$stub" || fail "$stub: missing the 'source: agents/wikipedia/$name/README.md' marker"
    fi
    grep -q "apps/$name.md" mkdocs.yml || fail "$name: not in the mkdocs.yml nav"
  done
else
  fail "mkdocs.yml is missing"
fi
[ -n "${MKDOCS_MATERIAL_VERSION:-}" ] || fail "versions.env does not set MKDOCS_MATERIAL_VERSION"
grep -q "^mkdocs-material==${MKDOCS_MATERIAL_VERSION:-}\$" docs/requirements.txt 2>/dev/null \
  || fail "docs/requirements.txt must pin mkdocs-material==${MKDOCS_MATERIAL_VERSION:-} (MKDOCS_MATERIAL_VERSION in versions.env)"
for page in $(sed -n 's/^.*: \([A-Za-z0-9_./-]*\.md\)$/\1/p' mkdocs.yml 2>/dev/null); do
  [ -f "docs/$page" ] || fail "mkdocs.yml lists $page, but docs/$page does not exist"
done

# --- workflows -------------------------------------------------------------------------------------
log "workflows"
for f in .github/workflows/*.yml; do
  [ -f "$f" ] || continue
  if err="$(yaml_to_json <"$f" 2>&1 >/dev/null)"; then
    :
  elif [ $? -eq 127 ]; then
    warn "no Ruby or PyYAML to parse $f; skipped"
  else
    fail "$f is not valid YAML: $err"
  fi
done

# --- scripts ---------------------------------------------------------------------------------------
log "scripts"
shell_files="$(git ls-files -co --exclude-standard '*.sh')"
for s in $shell_files; do
  bash -n "$s" 2>/dev/null || fail "$s has a syntax error"
done
if command -v shellcheck >/dev/null 2>&1; then
  # SC2154: the scripts share lowercase state (code, body, base, failures) with the libraries they
  # source, and shellcheck cannot follow the sourced files to see where it is assigned.
  # shellcheck disable=SC2086 # word splitting of the file list is intended
  shellcheck -S warning -e SC1090,SC1091,SC2154 $shell_files || fail "shellcheck found problems"
else
  warn "shellcheck is not installed; skipped"
fi

# --- secrets ---------------------------------------------------------------------------------------
log "secrets"
leaks="$(git grep --untracked -lIE 'gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}' 2>/dev/null || true)"
[ -z "$leaks" ] || fail "these files contain something that looks like a GitHub token: $leaks"

if [ "$failures" -gt 0 ]; then
  die "$failures check(s) failed"
fi
ok "all checks passed ($count agents, $app_count apps)"
