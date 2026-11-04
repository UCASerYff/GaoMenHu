#!/bin/bash
set -euo pipefail
umask 077
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Caller owns the exact Master/build_lease.py. Synthetic console checks only;
# there is no application, browser, panel, loopback server or transfer fixture.
TASK_ROOT=$(mktemp -d /private/tmp/portal-mount-epoch-tests.XXXXXX.noindex)
trap 'rm -rf "$TASK_ROOT"' EXIT
xcrun swiftc -swift-version 5 -Onone -target arm64-apple-macos14.0 -module-cache-path "$TASK_ROOT/cache" \
 "$PROJECT_DIR/Sources/Downloads/DownloadModels.swift" "$PROJECT_DIR/Sources/Downloads/DownloadStore.swift" \
 "$PROJECT_DIR/Sources/Downloads/HTTPTransfer.swift" "$PROJECT_DIR/Sources/Downloads/DownloadMountEpoch.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadManager.swift" "$PROJECT_DIR/Tests/DownloadMountEpochTests.swift" \
 -framework AppKit -framework CryptoKit -framework Security -framework Network -o "$TASK_ROOT/tests"
"$TASK_ROOT/tests"
