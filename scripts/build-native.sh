#!/usr/bin/env bash
# Reproducible local build. No dependency download is initiated by this script;
# Go must already have access to the module cache or configured module source.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${TMUX_RADAR_BUILD_OUTPUT:-$ROOT/bin/tmux-radar}"
VERSION="${TMUX_RADAR_BUILD_VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || printf dev)}"
COMMIT="${TMUX_RADAR_BUILD_COMMIT:-$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || printf unknown)}"
BUILD_DATE="${TMUX_RADAR_BUILD_DATE:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"

command -v go >/dev/null 2>&1 || { echo 'tmux-radar: Go is required for a source build' >&2; exit 3; }
mkdir -p "$(dirname "$OUTPUT")"
TEMPORARY="$(dirname "$OUTPUT")/.tmux-radar.tmp.$$"
cleanup() { rm -f "$TEMPORARY"; }
trap cleanup EXIT INT TERM HUP

LDFLAGS="-s -w -X main.buildVersion=$VERSION -X main.buildCommit=$COMMIT -X main.buildDate=$BUILD_DATE"
CGO_ENABLED=0 go build -trimpath -ldflags "$LDFLAGS" -o "$TEMPORARY" "$ROOT/cmd/tmux-radar"
chmod 0755 "$TEMPORARY"
case "$("$TEMPORARY" version 2>/dev/null || true)" in
  *"protocol 1"*) : ;;
  *) echo 'tmux-radar: built binary failed protocol verification' >&2; exit 5 ;;
esac
mv -f "$TEMPORARY" "$OUTPUT"
trap - EXIT INT TERM HUP
printf '%s\n' "$OUTPUT"
