#!/usr/bin/env python3
import runpy
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
checks = 0

def check(condition, label):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1

def rejects(operation, label):
    try:
        operation()
    except RuntimeError:
        check(True, label)
    else:
        raise AssertionError(label)

loaded = runpy.run_path(str(ROOT / "Scripts/install.py"), run_name="install_policy_test")
with tempfile.TemporaryDirectory(prefix="gmh-install-", dir="/private/tmp") as temporary:
    outer = Path(temporary)
    candidate = loaded["validate_build_destination"](outer / "Candidate.noindex" / "搞门户.app")
    check(candidate.name == "搞门户.app", "valid noindex destination accepted")
    rejects(lambda: loaded["validate_build_destination"](outer / "搞门户.app"), "indexable destination rejected")
    rejects(lambda: loaded["validate_build_destination"](outer / "Candidate.noindex" / "Portal.txt"), "non-app destination rejected")
source = (ROOT / "Scripts/install.py").read_text()
check("PreviousApplications" not in source and "snapshot(" not in source and "rollback" not in source, "installer has no backup or rollback path")
check('APP_ID = "cn.mendao.launcher"' in source and 'Path("/Applications/搞门户.app")' in source, "installer identity and formal path are exact")
check('TEAM = "5G96498KGJ"' in source, "installer enforces stable signing team")
print(f"Install policy tests passed: {checks}")
