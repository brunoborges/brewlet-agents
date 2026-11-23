#!/usr/bin/env bash
# Builds the agent into $APP_DIR. Called by scripts/workloads/build.sh, which then packages
# $APP_DIR as a Brewlet application artifact (see the "layers" file next to this script).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib/common.sh"
: "${APP_DIR:?run this through scripts/workloads/build.sh}"
: "${ARCH:?run this through scripts/workloads/build.sh}"
need dotnet

# Dependencies are resolved for the target, not for the build host.
case "$ARCH" in
  arm64) RID=linux-arm64 ;;
  amd64) RID=linux-x64 ;;
  *) die "unsupported ARCH: $ARCH" ;;
esac

# Framework-dependent: the dotnet-10 runtime image provides the shared framework, so only the
# application and the libraries that are not part of it are published. The restore reads the
# integration from build/integrations/dotnet (see nuget.config) and everything else from nuget.org.
STAGE="$(dirname "$APP_DIR")/publish"
rm -rf "$STAGE"
retry 3 dotnet restore "$HERE/Concierge.csproj" -r "$RID" --nologo -v minimal
dotnet publish "$HERE/Concierge.csproj" -c Release -r "$RID" --self-contained false \
  -p:UseAppHost=false -p:DebugType=none --no-restore --nologo -v minimal -o "$STAGE"

# The Copilot CLI runs in the sidecar. Microsoft.Copilot.SDK bundles it into the publish output
# when its build assets are active, so make sure it did not sneak in.
bundled="$(find "$STAGE" \( -path '*/runtimes/*' -o -iname 'copilot' -o -iname 'copilot.*' -o -iname 'libcopilot*' \))"
[ -z "$bundled" ] || die "the Copilot CLI must not be part of the artifact, found: $bundled"

# deps: every library (the large, stable layer). code: the application assembly, its descriptors and
# its settings (the prompt is embedded in the assembly). Anything else is a surprise worth failing on.
mkdir -p "$APP_DIR/deps" "$APP_DIR/code"
for file in "$STAGE"/*; do
  case "$(basename "$file")" in
    Concierge.dll|Concierge.deps.json|Concierge.runtimeconfig.json|appsettings.json) mv "$file" "$APP_DIR/code/" ;;
    *.dll) mv "$file" "$APP_DIR/deps/" ;;
    *) die "unexpected file in the publish output: $file" ;;
  esac
done
rm -rf "$STAGE"
