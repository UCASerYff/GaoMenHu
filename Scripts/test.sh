#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /private/tmp/mendao-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
node --check "$PROJECT_DIR/Resources/app.js"
if [[ -f "$PROJECT_DIR/Resources/features.js" ]]; then node --check "$PROJECT_DIR/Resources/features.js"; fi
node --check "$PROJECT_DIR/BrowserExtension/background.js"
node --check "$PROJECT_DIR/BrowserExtension/content.js"
node --check "$PROJECT_DIR/BrowserExtension/popup.js"
node "$PROJECT_DIR/Tests/Extension.cjs"
swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Sources/Vault.swift" "$PROJECT_DIR/Sources/Socket.swift" "$PROJECT_DIR/Tests/Core.swift" \
  -framework Security -framework LocalAuthentication -o "$TEST_DIR/core"
"$TEST_DIR/core"
swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Sources/LibraryOperations.swift" "$PROJECT_DIR/Tests/LibraryOperationsTests.swift" -o "$TEST_DIR/library"
"$TEST_DIR/library"
swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Sources/FloatingLauncherLogic.swift" "$PROJECT_DIR/Tests/FloatingLauncherLogicTests.swift" -o "$TEST_DIR/floating"
"$TEST_DIR/floating"
swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" "$PROJECT_DIR/Sources/IconLoader.swift" \
  "$PROJECT_DIR/Tests/Icons.swift" -framework AppKit -framework ImageIO -o "$TEST_DIR/icons"
"$TEST_DIR/icons"
swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Sources/LibraryOperations.swift" "$PROJECT_DIR/Sources/FullBackup.swift" \
  "$PROJECT_DIR/Tests/FullBackupTests.swift" -o "$TEST_DIR/full-backup"
"$TEST_DIR/full-backup"
swiftc -swift-version 5 -D DEBUG_TESTING -module-cache-path "$TEST_DIR/cache" "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Sources/LibraryOperations.swift" "$PROJECT_DIR/Sources/FullBackup.swift" \
  "$PROJECT_DIR/Sources/BackupRestore.swift" "$PROJECT_DIR/Tests/BackupRestoreTests.swift" -o "$TEST_DIR/backup-restore"
"$TEST_DIR/backup-restore"
