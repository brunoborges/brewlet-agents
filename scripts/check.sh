#!/usr/bin/env bash
# Static checks that need neither a cluster nor Docker. They guard the contract every agent shares
# (agents/README.md), the Ops runtime catalog, the manifests the deploy step would apply, the
# documentation wiring and the scripts themselves. CI runs them on every push.
#
#   scripts/check.sh            (or: make check)
set -uo pipefail
source "$(dirname "$0")/lib.sh"
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

# A digest that cannot exist, to render manifests without a registry.
zeros="0000000000000000000000000000000000000000000000000000000000000000"

# --- versions.env -------------------------------------------------------------------------------
log "versions.env"
for v in BREWLET_VERSION CLUSTER_NAME REGISTRY_PORT COPILOT_CLI_VERSION COPILOT_CLI_SHA256_LINUX_ARM64 \
         COPILOT_CLI_SHA256_LINUX_X64 INTEGRATIONS_SHA SIDECAR_NAME SIDECAR_PORT AGENT_NAMESPACE AGENT_SECRET; do
  [ -n "${!v:-}" ] || fail "versions.env does not set $v"
done
[[ "${INTEGRATIONS_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail "INTEGRATIONS_SHA must be a full 40-character commit"
for v in COPILOT_CLI_SHA256_LINUX_ARM64 COPILOT_CLI_SHA256_LINUX_X64; do
  [[ "${!v:-}" =~ ^[0-9a-f]{64}$ ]] || fail "$v must be a SHA-256 (64 hex characters)"
done

# --- the Ops runtime catalog ---------------------------------------------------------------------
log "runtimes"
runtime_ids=" "
for f in runtimes/*.env; do
  id="$(basename "$f" .env)"
  runtime_ids="$runtime_ids$id "
  for key in IMAGE RUNTIME_UID RUNTIME_GID ECOSYSTEM ABI MOUNT_PATHS DESCRIPTION INTERPRETER; do
    [ -n "$(env_value "$f" "$key")" ] || fail "$f: $key is missing"
  done
  [[ "$(env_value "$f" IMAGE)" =~ @sha256:[0-9a-f]{64}$ ]] || fail "$f: IMAGE must be pinned by digest (name@sha256:<64 hex>)"
  [[ "$(env_value "$f" INTERPRETER)" == /* ]] || fail "$f: INTERPRETER must be an absolute path"
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

  for key in AGENT_NAME LANGUAGE FRAMEWORK RUNTIME PORT; do
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

  # launch.json is the only contract with the runtime.
  if [ -f "$dir/launch.json" ]; then
    if jq -e . "$dir/launch.json" >/dev/null 2>&1; then
      interpreter="$(env_value "$runtime_env" INTERPRETER)"
      jq -e --arg rt "$runtime" --arg interp "$interpreter" '
          .schemaVersion == 1
          and .runtimeImages == [$rt]
          and (.process.entrypoint[0] == $interp)
          and (.process.workingDir == "/app")
          and (((.env // {}) | has("PATH")) | not)
        ' "$dir/launch.json" >/dev/null \
        || fail "$name: launch.json must have schemaVersion 1, runtimeImages [\"$runtime\"], entrypoint[0] \"$interpreter\", workingDir \"/app\" and no PATH"
    else
      fail "$name: launch.json is not valid JSON"
    fi
  else
    fail "$name: launch.json is missing"
  fi

  # layers: "<directory>:<path in the artifact>", one per line.
  if [ -f "$dir/layers" ]; then
    layer_re='^[A-Za-z0-9._-]+:/app(/[A-Za-z0-9._/-]*)?$'
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      [[ "$line" =~ $layer_re ]] || fail "$name: layers entry '$line' must look like <directory>:/app"
    done < "$dir/layers"
  fi

  [ -f "$dir/build.sh" ] || fail "$name: build.sh is missing"
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

  # The manifest renders completely and describes what Brewlet needs.
  if manifest="$(ARCH=arm64 scripts/agent-render.sh "$name" "$REGISTRY_HOST/agents/$name@sha256:$zeros" \
        "$REGISTRY_HOST/$SIDECAR_NAME@sha256:$zeros" 2>&1)"; then
    if grep -q '@@' <<<"$manifest"; then
      fail "$name: the rendered manifest still has an unfilled @@placeholder@@"
    elif json="$(yaml_to_json <<<"$manifest" 2>&1)"; then
      jq -e --arg rt "$runtime" '
          (map(select(.kind == "Deployment")) | first) as $d
          | ($d.spec.template) as $t
          | ([.[].kind] | sort) == ["Deployment", "Service", "ServiceAccount"]
            and $t.metadata.annotations["runtime-image.brewlet.sh/agent"] == $rt
            and $t.spec.runtimeClassName == "brewlet"
            and ([$t.spec.containers[].name] == ["agent"])
            and ([$t.spec.initContainers[].name] == ["copilot-cli"])
            and ($t.spec.containers[0].image | test("@sha256:[0-9a-f]{64}$"))
            and ($t.spec.initContainers[0].image | test("@sha256:[0-9a-f]{64}$"))
            and $d.metadata.annotations["brewlet.sh/restart-on-rotation"] == "true"
        ' <<<"$json" >/dev/null || fail "$name: the rendered manifest does not select runtime $runtime with a digest-pinned agent and sidecar"
    elif [ $? -eq 127 ]; then
      warn "$name: no Ruby or PyYAML to parse the manifest; skipped"
    else
      fail "$name: the rendered manifest is not valid YAML: $json"
    fi
  else
    fail "$name: the manifest does not render: $manifest"
  fi

  [ "$failures" -gt "$bad" ] || ok "$name"
done
[ "$count" -gt 0 ] || fail "no agents found under agents/"

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
else
  fail "mkdocs.yml is missing"
fi

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
  # shellcheck disable=SC2086 # word splitting of the file list is intended
  shellcheck -S warning -e SC1090,SC1091 $shell_files || fail "shellcheck found problems"
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
ok "all checks passed ($count agents)"
