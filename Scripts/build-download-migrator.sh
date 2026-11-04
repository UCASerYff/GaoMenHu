#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 1 ]] || { echo 'usage: build-download-migrator.sh /absolute/container.noindex/download-migrator' >&2; exit 1; }
DEST=$(python3 - "$1" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); parent=p.parent.resolve(strict=True)
if not p.is_absolute() or p.exists() or p.is_symlink() or not any(x.name.endswith('.noindex') and x.is_dir() and not x.is_symlink() for x in [parent,*parent.parents]):
 raise SystemExit('An unused absolute output inside an existing .noindex container is required')
print(parent/p.name)
PY
)
TASK_ROOT=$(mktemp -d /private/tmp/portal-migrator-build.XXXXXX.noindex)
trap 'rm -rf "$TASK_ROOT"' EXIT
# The coordinator must acquire Master/build_lease.py first. This compiles only;
# it never executes the migration utility or starts either application.
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -module-cache-path "$TASK_ROOT/cache" \
 "$PROJECT_DIR/Sources/Downloads/DownloadModels.swift" "$PROJECT_DIR/Sources/Downloads/DownloadStore.swift" "$PROJECT_DIR/Sources/Downloads/HTTPTransfer.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadActionPackage.swift" "$PROJECT_DIR/Sources/Downloads/DownloadExchangeJournal.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadExchange.swift" "$PROJECT_DIR/Sources/Downloads/DownloadMigration.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadHistoryIsolation.swift" \
 "$PROJECT_DIR/Tools/DownloadMigrationMain.swift" \
 -framework AppKit -framework CryptoKit -framework Security -o "$TASK_ROOT/download-migrator"
install -m 700 "$TASK_ROOT/download-migrator" "$DEST"
printf 'Built coordinated migration utility: %s\n' "$DEST"
