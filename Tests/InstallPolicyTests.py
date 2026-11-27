#!/usr/bin/env python3
import plistlib
import runpy
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

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
with tempfile.TemporaryDirectory(prefix="gmh-install-", dir="/private/tmp" if sys.platform == "darwin" else None) as temporary:
    outer = Path(temporary)
    candidate = loaded["validate_build_destination"](outer / "Candidate.noindex" / "搞门户.app")
    check(candidate.name == "搞门户.app", "valid noindex destination accepted")
    rejects(lambda: loaded["validate_build_destination"](outer / "搞门户.app"), "indexable destination rejected")
    rejects(lambda: loaded["validate_build_destination"](outer / "Candidate.noindex" / "Portal.txt"), "non-app destination rejected")
    version = (ROOT / "VERSION").read_text().strip()
    build = (ROOT / "BUILD").read_text().strip()
    contents = candidate / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    for executable in ("MenDao", "MenDaoBridge"):
        (contents / "MacOS" / executable).touch()
    info = {"CFBundleIdentifier": "cn.mendao.launcher", "CFBundleShortVersionString": version, "CFBundleVersion": build}
    manifest = contents / "Info.plist"
    manifest.write_bytes(plistlib.dumps(info))
    verify_candidate = loaded["verify_candidate"]
    codesign = Mock(return_value=SimpleNamespace(stdout="TeamIdentifier=5G96498KGJ", stderr=""))
    with patch.dict(verify_candidate.__globals__, {"run": codesign}):
        check(verify_candidate(candidate, version, build) == info, "current marketing version and independent build accepted")
        check(codesign.call_count == 4, "all candidate signature checks still run")
        manifest.write_bytes(plistlib.dumps({**info, "CFBundleVersion": str(int(build) - 1)}))
        rejects(lambda: verify_candidate(candidate, version, build), "old build with matching marketing version rejected")
        check(codesign.call_count == 4, "build mismatch stops before signature checks")
source = (ROOT / "Scripts/install.py").read_text(encoding="utf-8")
check("PreviousApplications" not in source and "snapshot(" not in source and "rollback" not in source, "installer has no backup or rollback path")
check('APP_ID = "cn.mendao.launcher"' in source and 'Path("/Applications/搞门户.app")' in source, "installer identity and formal path are exact")
check('TEAM = "5G96498KGJ"' in source, "installer enforces stable signing team")
print(f"Install policy tests passed: {checks}")
