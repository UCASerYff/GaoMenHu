#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Root must own Master/build_lease.py before this targeted synthetic suite.
SCRATCH=$(mktemp -d /private/tmp/gaomenhu-mail-ui-bootstrap-tests.XXXXXX.noindex)
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$SCRATCH/cache" \
  "$PROJECT_DIR/Sources/Mail/MailModels.swift" "$PROJECT_DIR/Sources/Mail/MailStorage.swift" \
  "$PROJECT_DIR/Sources/Mail/MailSubmission.swift" "$PROJECT_DIR/Sources/Mail/MailUIOnlyBootstrap.swift" \
  "$PROJECT_DIR/Sources/Mail/MailMigration.swift" "$PROJECT_DIR/Tests/MailUIOnlyBootstrapTests.swift" \
  -framework Foundation -framework CryptoKit -o "$SCRATCH/mail-ui-bootstrap-tests"
"$SCRATCH/mail-ui-bootstrap-tests"
