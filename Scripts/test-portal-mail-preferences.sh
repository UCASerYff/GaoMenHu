#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Caller must hold Master/build_lease.py before running this compiler. Only the
# standalone preference reader and isolated fixtures are linked; no app, store,
# defaults suite, credential, browser or network session is opened.
TEST_ROOT="$(mktemp -d /private/tmp/gaomenhu-mail-preferences.XXXXXX.noindex)"
trap 'rm -rf "$TEST_ROOT"' EXIT
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$TEST_ROOT/module-cache" \
  "$PROJECT_DIR/Sources/PortalMailPreferences.swift" \
  "$PROJECT_DIR/Tests/PortalMailPreferencesTests.swift" \
  -framework Foundation -o "$TEST_ROOT/mail-preferences-tests"
"$TEST_ROOT/mail-preferences-tests" "$TEST_ROOT"
