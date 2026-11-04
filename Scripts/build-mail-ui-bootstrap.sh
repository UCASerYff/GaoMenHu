#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 2 ]] || { echo 'usage: build-mail-ui-bootstrap.sh /absolute/existing.noindex/unique-mail-ui-bootstrap /absolute/original-human-authorization-fact.json' >&2; exit 1; }
# Root must hold the exact Master/build_lease.py owner/token before invoking.
# This builds a private CLI only. Root first checks HUMAN_FACT against its
# separately trusted original SHA. Only the SHA enters this temporary build;
# the fact's path, answer and content never enter public source or the App.
DEST=$(python3 - "$1" <<'PY'
from pathlib import Path
import os, stat, sys
raw=sys.argv[1]
p=Path(raw)
if not p.is_absolute() or any(x in ('','.','..') for x in raw.split('/')[1:]) or p.suffix=='.app' or p.exists() or p.is_symlink():
    raise SystemExit('An unused absolute non-app output is required')
ancestors=(p.parent,*p.parent.parents)
if not all(stat.S_ISDIR(d.lstat().st_mode) for d in ancestors):
    raise SystemExit('Existing real ancestors without links are required')
if not any(d.name.endswith('.noindex') for d in ancestors):
    raise SystemExit('Output must be inside an existing .noindex container')
s=p.parent.lstat()
if s.st_uid!=os.getuid() or s.st_mode&0o022:
    raise SystemExit('Unsafe output parent')
print(p)
PY
)
SCRATCH=$(mktemp -d /private/tmp/gaomenhu-mail-ui-bootstrap.XXXXXX.noindex)
trap 'rm -rf "$SCRATCH"' EXIT
python3 - "$2" "$SCRATCH/AuthorizationPin.swift" <<'PY'
import hashlib, os, stat, sys
raw,out=sys.argv[1:]
parts=raw.split('/')
if not raw.startswith('/') or len(raw.encode())>16384 or len(parts)<2 or any(p in ('','.','..') for p in parts[1:]):
    raise SystemExit('Human authorization must be an exact absolute no-link file')
def parent_fd():
    parent=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
    try:
        for component in parts[1:-1]:
            child=os.open(component,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
            os.close(parent);parent=child
        return parent
    except BaseException:
        os.close(parent);raise
def identity(s):
    return (s.st_dev,s.st_ino,s.st_uid,s.st_gid,s.st_mode,s.st_flags,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
parent=parent_fd()
try:
    original_parent=os.fstat(parent)
    fd=os.open(parts[-1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid!=os.getuid() or before.st_nlink!=1 or before.st_mode&0o077 or not before.st_mode&0o400 or not 0<before.st_size<=32*1024*1024:
            raise SystemExit('Unsafe original authorization fact')
        h=hashlib.sha256();size=0
        while True:
            chunk=os.read(fd,65536)
            if not chunk:break
            size+=len(chunk)
            if size>32*1024*1024:raise SystemExit('Authorization budget exceeded')
            h.update(chunk)
        if size!=before.st_size or identity(before)!=identity(os.fstat(fd)) or identity(before)!=identity(os.stat(parts[-1],dir_fd=parent,follow_symlinks=False)):
            raise SystemExit('Original authorization changed during pinning')
        reopened=parent_fd()
        try:
            now=os.fstat(reopened)
            if (now.st_dev,now.st_ino,now.st_uid,now.st_gid,now.st_mode)!=(original_parent.st_dev,original_parent.st_ino,original_parent.st_uid,original_parent.st_gid,original_parent.st_mode):
                raise SystemExit('Authorization parent changed during pinning')
        finally:os.close(reopened)
        pin=h.hexdigest()
    finally:os.close(fd)
finally:os.close(parent)
descriptor=os.open(out,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(descriptor,'w') as generated:
    generated.write('enum MailUIOnlyBootstrapPinnedAuthorization { static let sha256 = "'+pin+'" }\n')
    generated.flush();os.fsync(generated.fileno())
PY
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -module-cache-path "$SCRATCH/cache" \
  "$PROJECT_DIR/Sources/Mail/MailModels.swift" "$PROJECT_DIR/Sources/Mail/MailStorage.swift" \
  "$PROJECT_DIR/Sources/Mail/MailSubmission.swift" "$PROJECT_DIR/Sources/Mail/MailUIOnlyBootstrap.swift" \
  "$PROJECT_DIR/Tools/MailUIOnlyBootstrapMain.swift" "$SCRATCH/AuthorizationPin.swift" -framework Foundation -framework CryptoKit \
  -o "$SCRATCH/mail-ui-bootstrap"
python3 - "$SCRATCH/mail-ui-bootstrap" "$DEST" <<'PY'
from pathlib import Path
import os, secrets, stat, sys
source,target=map(Path,sys.argv[1:])
for d in (target.parent,*target.parent.parents):
    if not stat.S_ISDIR(d.lstat().st_mode):raise SystemExit('Output ancestors changed')
temporary=target.parent/('.mail-ui-bootstrap-'+secrets.token_hex(16))
try:
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o700)
    with os.fdopen(fd,'wb') as out,source.open('rb') as inp:
        while True:
            chunk=inp.read(1024*1024)
            if not chunk:break
            out.write(chunk)
        out.flush();os.fsync(out.fileno())
    os.link(temporary,target,follow_symlinks=False)
    directory=os.open(target.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:os.fsync(directory)
    finally:os.close(directory)
finally:
    if temporary.exists():temporary.unlink()
PY
printf 'Built offline UI-only initialization utility: %s\n' "$DEST"
