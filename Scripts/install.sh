#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$PROJECT_DIR/Scripts/install.py" "$@"
