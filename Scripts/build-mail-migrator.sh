#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 1 ]] || { echo 'usage: build-mail-migrator.sh /absolute/container.noindex/mail-migrator' >&2; exit 1; }
DEST=$(python3 - "$1" <<'PY'
from pathlib import Path
import os, stat, sys
raw = sys.argv[1]
p = Path(raw)
parts = raw.split('/')
if not p.is_absolute() or any(x in ('', '.', '..') for x in parts[1:]) or p.suffix == '.app' or p.exists() or p.is_symlink():
    raise SystemExit('An unused absolute non-app output path is required')
parent = p.parent
for directory in (parent, *parent.parents):
    if not stat.S_ISDIR(directory.lstat().st_mode):
        raise SystemExit('Output ancestors must be existing real directories, without symlinks')
if not any(x.name.endswith('.noindex') for x in (parent, *parent.parents)):
    raise SystemExit('Output must be inside an already existing .noindex container')
info = parent.lstat()
if info.st_uid != os.getuid() or info.st_mode & 0o022:
    raise SystemExit('Output parent must belong to this user and not be writable by other users')
print(p)
PY
)
TASK_ROOT=$(mktemp -d /private/tmp/portal-mail-migrator.XXXXXX.noindex)
trap 'rm -rf "$TASK_ROOT"' EXIT
# Acquire Master/build_lease.py before this compilation. It does not execute the
# utility, initialize data, read a credential, or start either application.
SDK=$(xcrun --sdk macosx --show-sdk-path)
clang -O2 -arch arm64 -mmacosx-version-min=14.0 -isysroot "$SDK" \
  -c "$PROJECT_DIR/Sources/Mail/MailNative.c" -o "$TASK_ROOT/MailNative.o"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -sdk "$SDK" \
  -module-cache-path "$TASK_ROOT/cache" -import-objc-header "$PROJECT_DIR/Sources/Mail/MailNative.h" \
  "$PROJECT_DIR/Sources/Mail/MailModels.swift" "$PROJECT_DIR/Sources/Mail/MailStorage.swift" "$PROJECT_DIR/Sources/Mail/MailSubmission.swift" \
  "$PROJECT_DIR/Sources/Mail/MailMigration.swift" "$PROJECT_DIR/Tools/MailMigrationMain.swift" \
  "$TASK_ROOT/MailNative.o" -lcurl -lsqlite3 \
  -framework AppKit -framework SwiftUI -framework WebKit -framework CryptoKit -framework Security \
  -framework Network -framework AuthenticationServices -framework UserNotifications \
  -o "$TASK_ROOT/mail-migrator"
# A hard-link publication fails if the destination appeared during compilation.
# install(1) would otherwise overwrite an unexpected new file at the same path.
python3 - "$TASK_ROOT/mail-migrator" "$DEST" <<'PY'
from pathlib import Path
import os, stat, sys
source, target = Path(sys.argv[1]), Path(sys.argv[2])
for directory in (target.parent, *target.parent.parents):
    if not stat.S_ISDIR(directory.lstat().st_mode):
        raise SystemExit('Output ancestors changed; refusing publication')
# The build staging and requested output may be on different volumes. Copy to a
# private new sibling first, then publish using an exclusive no-overwrite link.
import secrets
name = target.parent / ('.mail-migrator-' + secrets.token_hex(16))
try:
    descriptor = os.open(str(name), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o700)
    with os.fdopen(descriptor, 'wb') as out, source.open('rb') as inp:
        while True:
            chunk = inp.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
        out.flush()
        os.fsync(out.fileno())
    os.link(str(name), str(target), follow_symlinks=False)
    directory_fd = os.open(str(target.parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    if name.exists():
        name.unlink()
PY
printf 'Built coordinated mail migration utility: %s\n' "$DEST"
