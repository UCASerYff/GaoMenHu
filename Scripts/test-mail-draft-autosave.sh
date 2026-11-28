#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gaomenhu-draft-autosave.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_DIR="$TEST_ROOT/Fixtures.noindex"
mkdir -m 700 "$TEST_DIR"
swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" \
  "$PROJECT_DIR/Sources/Mail/MailModels.swift" "$PROJECT_DIR/Sources/Mail/MailDraftAutosave.swift" \
  "$PROJECT_DIR/Tests/MailDraftAutosaveTests.swift" -o "$TEST_DIR/draft-tests"
"$TEST_DIR/draft-tests" "$TEST_DIR"
