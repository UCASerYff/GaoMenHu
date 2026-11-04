#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 3 ]] || { echo 'usage: build-download-history-isolator.sh OUT.noindex/tool ROOT_APPROVED_SNAPSHOT ROOT_HUMAN_FACT' >&2; exit 1; }
# Root must hold Master/build_lease.py and independently verify both original
# private input digests before invoking. This only compiles; it never migrates.
TASK_ROOT=$(mktemp -d /private/tmp/portal-history-isolator-build.XXXXXX.noindex)
trap 'rm -rf "$TASK_ROOT"' EXIT
python3 - "$1" "$2" "$3" "$TASK_ROOT/ApprovalBuildPin.swift" <<'PY'
import hashlib, json, os, stat, sys
from pathlib import Path
def private_read(raw):
    p=Path(raw)
    if not p.is_absolute() or '..' in p.parts: raise SystemExit('physical private input required')
    parent=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
    try:
        for part in p.parts[1:-1]:
            nxt=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent);os.close(parent);parent=nxt
        fd=os.open(p.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
        try:
            a=os.fstat(fd)
            if not stat.S_ISREG(a.st_mode) or a.st_uid!=os.getuid() or a.st_nlink!=1 or a.st_mode&0o077 or not 0<a.st_size<=33554432: raise SystemExit('unsafe approval input')
            data=bytearray()
            while True:
                b=os.read(fd,65536)
                if not b: break
                data.extend(b)
                if len(data)>33554432: raise SystemExit('approval budget exceeded')
            z=os.fstat(fd); named=os.stat(p.name,dir_fd=parent,follow_symlinks=False)
            fields=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns,s.st_mode,s.st_nlink,s.st_uid)
            if fields(a)!=fields(z) or fields(z)!=fields(named): raise SystemExit('approval input changed')
            return bytes(data)
        finally: os.close(fd)
    finally: os.close(parent)
out=Path(sys.argv[1]); parent=out.parent.resolve(strict=True)
if not out.is_absolute() or out.exists() or out.is_symlink() or not any(p.name.endswith('.noindex') for p in [parent,*parent.parents]): raise SystemExit('unused output in existing .noindex required')
snapshot=private_read(sys.argv[2]); fact=private_read(sys.argv[3]); s=json.loads(snapshot); f=json.loads(fact)
sh=hashlib.sha256(snapshot).hexdigest(); fh=hashlib.sha256(fact).hexdigest()
if s.get('schemaVersion')!=1 or len(s.get('exactApprovedRecords',[]))!=4 or f.get('kind')!='GaoSeriesHumanExplicitScopeAuthorization' or f.get('approvedMissingHistorySnapshotSHA256')!=sh or f.get('sourceFullyVerified') is not False: raise SystemExit('approval chain mismatch')
code='enum PortalHistoryIsolationBuildPin {\n static let approvedSnapshotSHA256 = "'+sh+'"\n static let humanFactSHA256 = "'+fh+'"\n}\n'
fd=os.open(sys.argv[4],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as stream: stream.write(code)
PY
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -module-cache-path "$TASK_ROOT/cache" \
 "$PROJECT_DIR/Sources/Downloads/DownloadModels.swift" "$PROJECT_DIR/Sources/Downloads/DownloadStore.swift" "$PROJECT_DIR/Sources/Downloads/HTTPTransfer.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadActionPackage.swift" "$PROJECT_DIR/Sources/Downloads/DownloadExchangeJournal.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadExchange.swift" "$PROJECT_DIR/Sources/Downloads/DownloadMigration.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadHistoryIsolation.swift" "$PROJECT_DIR/Tools/DownloadHistoryIsolationMain.swift" "$TASK_ROOT/ApprovalBuildPin.swift" \
 -framework AppKit -framework CryptoKit -framework Security -o "$TASK_ROOT/download-history-isolator"
python3 - "$TASK_ROOT/download-history-isolator" "$1" <<'PY'
import os, shutil, sys
from pathlib import Path
p=Path(sys.argv[2]); parent=p.parent.resolve(strict=True)
fd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
    out=os.open(p.name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o700,dir_fd=fd)
    with open(sys.argv[1],'rb') as source, os.fdopen(out,'wb') as target:
        shutil.copyfileobj(source,target); target.flush(); os.fsync(target.fileno())
    os.fsync(fd)
finally: os.close(fd)
PY
printf 'Built private coordinated history isolator: %s\n' "$1"
