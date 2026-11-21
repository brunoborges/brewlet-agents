#!/usr/bin/env bash
# Packs the .NET integration (CopilotSdk.Extensions.Hosting) into a NuGet package in
# build/integrations/dotnet, a local feed the agents restore it from.
# Invoked by scripts/integrations-build.sh, never directly.
set -euo pipefail
source "$(dirname "$0")/../lib.sh"
need dotnet

PROJECT="$INTEGRATIONS_SRC/dotnet/src/CopilotSdk.Extensions.Hosting"
LOG="$INTEGRATIONS_OUT/build.log"
: > "$LOG"

# The feed must hold exactly one version of the package, so drop what an earlier pin left behind.
rm -f "$INTEGRATIONS_OUT"/*.nupkg "$INTEGRATIONS_OUT"/*.snupkg

# The pinned tree sets no version, so every pin would pack as 1.0.0 and NuGet's global package
# cache would keep serving the first one. A suffix derived from the pin keeps the versions apart.
# CopilotSkipCliDownload: the SDK's MSBuild targets would otherwise download the Copilot CLI for
# the build host; the package only carries the library, and agents use a sidecar CLI.
# The pinned tree sits inside this repository's worktree, so without the last two properties the
# package metadata would name this repository's commit instead of the pinned one.
pack() {
  # The SDK version is picked from the pinned tree's global.json, which dotnet looks up from the working directory.
  # PackageOutputPath instead of -o: with this tree, SDK 10.0.401 forwards -o to MSBuild as a bare argument and fails.
  ( cd "$PROJECT" && dotnet pack -c Release \
      -p:PackageOutputPath="$INTEGRATIONS_OUT" \
      -p:VersionSuffix="g${INTEGRATIONS_SHA:0:12}" \
      -p:CopilotSkipCliDownload=true \
      -p:RepositoryCommit="$INTEGRATIONS_SHA" \
      -p:IncludeSourceRevisionInInformationalVersion=false )
}

# nuget.org sometimes resets connections; a retry resumes from what is already in the package cache.
log "  CopilotSdk.Extensions.Hosting"
retry 3 pack >> "$LOG" 2>&1 \
  || { tail -40 "$LOG" >&2; die "CopilotSdk.Extensions.Hosting pack failed (full log: $LOG)"; }

ls "$INTEGRATIONS_OUT"/CopilotSdk.Extensions.Hosting.*.nupkg >/dev/null 2>&1 \
  || die "dotnet pack produced no CopilotSdk.Extensions.Hosting package (full log: $LOG)"
