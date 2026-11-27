import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from gaomenhu.native import EXTENSION_ORIGIN, browser_from_ancestors, run_native_host
from gaomenhu.store import default_data_dir

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] != EXTENSION_ORIGIN:
        raise SystemExit(1)
    raise SystemExit(run_native_host(default_data_dir(), browser_from_ancestors()))
