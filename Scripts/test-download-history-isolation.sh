#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Explicit targeted synthetic checks, run only after Root build GO/lease.
TASK_ROOT=$(mktemp -d /private/tmp/portal-history-isolation-tests.XXXXXX.noindex)
trap 'rm -rf "$TASK_ROOT"' EXIT
xcrun swiftc -swift-version 5 -Onone -target arm64-apple-macos14.0 -module-cache-path "$TASK_ROOT/cache" \
 "$PROJECT_DIR/Sources/Downloads/DownloadModels.swift" "$PROJECT_DIR/Sources/Downloads/DownloadStore.swift" "$PROJECT_DIR/Sources/Downloads/HTTPTransfer.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadActionPackage.swift" "$PROJECT_DIR/Sources/Downloads/DownloadExchangeJournal.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadExchange.swift" "$PROJECT_DIR/Sources/Downloads/DownloadMigration.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadHistoryIsolation.swift" "$PROJECT_DIR/Tests/DownloadHistoryIsolationTests.swift" \
 -framework AppKit -framework CryptoKit -framework Security -o "$TASK_ROOT/tests"
"$TASK_ROOT/tests"
