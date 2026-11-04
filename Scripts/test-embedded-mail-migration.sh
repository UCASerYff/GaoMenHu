#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
# The coordinator must own Master/build_lease.py before running this compiler.
# No app, credential store, browser, server or real user directory is opened.
SCRATCH=$(mktemp -d /private/tmp/gaomenhu-mail-migration.XXXXXX)
trap 'rm -rf "$SCRATCH"' EXIT
TEST_DIR="$SCRATCH/Build.noindex"
mkdir -m 700 "$TEST_DIR"
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$TEST_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Mail/MailModels.swift" \
  "$PROJECT_DIR/Sources/Mail/MailStorage.swift" "$PROJECT_DIR/Sources/Mail/MailSubmission.swift" \
  "$PROJECT_DIR/Sources/Mail/MailMigration.swift" \
  "$PROJECT_DIR/Tests/MailMigrationTests.swift" \
  -framework Foundation -framework CryptoKit -o "$TEST_DIR/mail-migration"
"$TEST_DIR/mail-migration"
