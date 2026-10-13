#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Keep the previous application until real business/data acceptance succeeds.
exec python3 "$PROJECT_DIR/Scripts/backup_verify.py" install "$@"
