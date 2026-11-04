#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TEMP=$(mktemp -d /private/tmp/gaomenhu-download-engine.XXXXXX)
TASK_ROOT="$TASK_TEMP/Tests.noindex"
mkdir -m 700 "$TASK_ROOT"
TASK_SERVER_PID=''
cleanup() {
  if [[ -n "$TASK_SERVER_PID" ]]; then kill "$TASK_SERVER_PID" 2>/dev/null || true; wait "$TASK_SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TASK_TEMP"
}
trap cleanup EXIT
/usr/bin/python3 "$PROJECT_DIR/Tests/EmbeddedDownloadHTTPFixture.py" --info "$TASK_ROOT/ports.json" > "$TASK_ROOT/fixture.log" 2>&1 &
TASK_SERVER_PID="$!"
for attempt in {1..100}; do [[ -f "$TASK_ROOT/ports.json" ]] && break; sleep 0.05; done
[[ -f "$TASK_ROOT/ports.json" ]] || { cat "$TASK_ROOT/fixture.log"; exit 1; }
# Caller must hold Master/build_lease.py before invoking this targeted compiler.
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -module-cache-path "$TASK_ROOT/cache" \
  "$PROJECT_DIR/Sources/Downloads/DownloadModels.swift" "$PROJECT_DIR/Sources/Downloads/DownloadStore.swift" \
  "$PROJECT_DIR/Sources/Downloads/HTTPTransfer.swift" "$PROJECT_DIR/Sources/Downloads/DownloadMountEpoch.swift" "$PROJECT_DIR/Sources/Downloads/DownloadManager.swift" \
  "$PROJECT_DIR/Tests/EmbeddedDownloadCoreTests.swift" -o "$TASK_ROOT/tests"
"$TASK_ROOT/tests" "$TASK_ROOT/ports.json" "$TASK_ROOT/Fixtures"
