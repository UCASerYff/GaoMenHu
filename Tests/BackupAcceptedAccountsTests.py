#!/usr/bin/env python3
"""Focused account-addition acceptance fixtures; never touches real app data."""
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("backup_verify", Path(__file__).resolve().parents[1] / "Scripts/backup_verify.py")
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)
checks = 0


def check(value):
    global checks
    assert value
    checks += 1


def reject(call):
    global checks
    try:
        call()
    except (RuntimeError, OSError, ValueError, KeyError, TypeError):
        checks += 1
    else:
        raise AssertionError("unsafe fixture accepted")


def account(identifier):
    return {"id": identifier, "username": "fixture", "label": "fixture", "hasPassword": True, "loginHosts": []}


def library(existing=False):
    first = {"id": "site-a", "name": "Example", "url": "https://example.org/", "color": "#000000", "icon": None,
             "allowedBrowsers": ["edge"], "defaultBrowser": "edge", "profiles": {"edge": "fixture-profile"}, "accounts": []}
    if existing:
        first.update(accounts=[account("old-account")], defaultAccount="old-account")
    second = {**copy.deepcopy(first), "id": "site-b", "name": "Second", "url": "https://example.net/", "accounts": []}
    second.pop("defaultAccount", None)
    return {"schema": 1, "sites": [first, second], "tiles": [{"id": "site-a", "kind": "site"}, {"id": "site-b", "kind": "site"}], "appearance": "system"}


original = library()
added = copy.deepcopy(original)
added["sites"][0].update(accounts=[account("new-account")], defaultAccount="new-account")
encoded = lambda value: json.dumps(value).encode()
check(upgrade.accepted_account_additions(encoded(original), encoded(added), ["site-a"]) == 1)
for mutate in (
    lambda value: value["sites"][0].update(url="https://changed.example.org/"),
    lambda value: value["sites"][1].update(name="changed"),
    lambda value: value["sites"][0].update(profiles={"edge": "changed"}),
    lambda value: value.update(tiles=list(reversed(value["tiles"]))),
    lambda value: value["sites"][1].update(accounts=[account("new-account")], defaultAccount="new-account"),
):
    invalid = copy.deepcopy(added)
    mutate(invalid)
    reject(lambda: upgrade.accepted_account_additions(encoded(original), encoded(invalid), ["site-a"]))
reject(lambda: upgrade.accepted_account_additions(encoded(original), encoded(added), ["site-b"]))
reject(lambda: upgrade.accepted_account_additions(encoded(original), encoded(added), ["missing"]))
reject(lambda: upgrade.accepted_account_additions(encoded(original), encoded(added), ["site-a", "site-a"]))
reject(lambda: upgrade.accepted_account_additions(encoded(original), encoded(original), ["site-a"]))
with_old = library(existing=True)
append_old = copy.deepcopy(with_old)
append_old["sites"][0]["accounts"].append(account("new-account"))
check(upgrade.accepted_account_additions(encoded(with_old), encoded(append_old), ["site-a"]) == 1)
for mutate in (
    lambda value: value["sites"][0]["accounts"].pop(0),
    lambda value: value["sites"][0]["accounts"][0].update(username="changed"),
    lambda value: value["sites"][0]["accounts"].reverse(),
    lambda value: value["sites"][0].update(defaultAccount="new-account"),
):
    invalid = copy.deepcopy(append_old)
    mutate(invalid)
    reject(lambda: upgrade.accepted_account_additions(encoded(with_old), encoded(invalid), ["site-a"]))
icons = copy.deepcopy(added)
icons["sites"][1].update(icon="fixture-remote-icon", iconCheckedAt=123)
reject(lambda: upgrade.accepted_account_additions(encoded(original), encoded(icons), ["site-a"]))
check(upgrade.accepted_account_additions(encoded(original), encoded(icons), ["site-a"], True) == 1)
icons["sites"][1]["iconSource"] = "custom"
reject(lambda: upgrade.accepted_account_additions(encoded(original), encoded(icons), ["site-a"], True))


with tempfile.TemporaryDirectory(prefix="mendao-account-acceptance-", suffix=".noindex", dir="/private/tmp") as temp:
    root = Path(temp).resolve()
    home, backups, apps = root / "Home", root / "Backups", root / "Applications"
    data = home / "Library/Application Support/MenDao"
    data.mkdir(parents=True)
    apps.mkdir()
    for browser in ("Google/Chrome", "Microsoft Edge"):
        (home / "Library/Application Support" / browser / "NativeMessagingHosts").mkdir(parents=True)
    prefs = {"Geometry": "fixture"}
    unavailable = set()

    def metadata(ids):
        missing = len(set(ids) & unavailable)
        return {"passwordReferences": len(ids), "available": len(ids) - missing, "unavailable": missing,
                "status": "fixture-existence-only"}

    real_load, real_verify = upgrade.load_state, upgrade.verify
    upgrade.load_state = lambda path, backup_root=backups: real_load(path, backups)
    def fixture_verify(path, *args, **kwargs):
        assert not args or args == (home, backups)
        return real_verify(path, home=home, backup_root=backups, **kwargs)

    upgrade.verify = fixture_verify
    upgrade.preferences = lambda: (plistlib.dumps(prefs), copy.deepcopy(prefs))
    upgrade.keychain_metadata = metadata
    upgrade.APPLICATIONS = apps

    def signature(arguments):
        assert arguments[:3] == ["/usr/bin/codesign", "--verify", "--strict"]
        assert Path(arguments[3]).is_relative_to(root) and upgrade.has_noindex_container(Path(arguments[3]).parent)

    upgrade.run_checked = signature

    def fake_app(path, version, build):
        upgrade.private_write(path / "Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": upgrade.APP_ID,
                              "CFBundleExecutable": "MenDao", "CFBundleShortVersionString": version, "CFBundleVersion": build}))
        upgrade.private_write(path / "Contents/MacOS/MenDao", b"non-executable fixture")

    fake_app(apps / "搞门户.app", "1.16", "116")
    with patch.object(Path, "home", return_value=home):
        (data / "library.json").write_bytes(encoded(original))
        (data / "fixture-attachment.txt").write_bytes(b"preserved attachment")
        old_backup = upgrade.snapshot(home, backups)
        fake_app(old_backup / "PreviousApplications/搞门户.app", "1.15", "115")
        old_state = upgrade.load_state(old_backup)
        old_state.update(phase="installed", oldApplications=["搞门户.app"], newVersion="1.16", newBuild="116")
        upgrade.update_state(old_backup, old_state)
        old_program = upgrade.application_record(old_backup / "PreviousApplications/搞门户.app")
        (data / "library.json").write_bytes(encoded(added))
        current_backup = upgrade.snapshot(home, backups)
        reject(lambda: upgrade.finalize(old_backup))
        reject(lambda: upgrade.finalize(old_backup, accepted_account_site_ids=["site-a"]))
        reject(lambda: upgrade.finalize(old_backup, accepted_data_backup=current_backup))
        reject(lambda: upgrade.finalize(old_backup, accepted_data_backup=old_backup, accepted_account_site_ids=["site-a"]))
        reject(lambda: upgrade.finalize(old_backup, accepted_data_backup=current_backup, accepted_account_site_ids=["site-b"]))
        (current_backup / "MenDao/fixture-attachment.txt").write_bytes(b"corrupt")
        reject(lambda: upgrade.finalize(old_backup, accepted_data_backup=current_backup, accepted_account_site_ids=["site-a"]))
        (current_backup / "MenDao/fixture-attachment.txt").write_bytes(b"preserved attachment")
        (data / "extra.txt").write_bytes(b"not in fresh snapshot")
        reject(lambda: upgrade.finalize(old_backup, accepted_data_backup=current_backup, accepted_account_site_ids=["site-a"]))
        (data / "extra.txt").unlink()
        (data / "fixture-attachment.txt").write_bytes(b"changed before new snapshot")
        changed_attachment_backup = upgrade.snapshot(home, backups)
        reject(lambda: upgrade.finalize(old_backup, accepted_data_backup=changed_attachment_backup, accepted_account_site_ids=["site-a"]))
        (data / "fixture-attachment.txt").unlink()
        missing_attachment_backup = upgrade.snapshot(home, backups)
        reject(lambda: upgrade.finalize(old_backup, accepted_data_backup=missing_attachment_backup, accepted_account_site_ids=["site-a"]))
        (data / "fixture-attachment.txt").write_bytes(b"preserved attachment")
        unavailable.add("new-account")
        reject(lambda: upgrade.finalize(old_backup, accepted_data_backup=current_backup, accepted_account_site_ids=["site-a"]))
        unavailable.clear()
        prefs["Unexpected"] = True
        reject(lambda: upgrade.finalize(old_backup, accepted_data_backup=current_backup, accepted_account_site_ids=["site-a"]))
        prefs.pop("Unexpected")
        def replace_after_fresh(path, *args, **kwargs):
            if path == old_backup and kwargs.get("_accepted_account_sites"):
                replaced = copy.deepcopy(added)
                replaced["sites"][0].update(accounts=[account("unbacked-account")], defaultAccount="unbacked-account")
                (data / "library.json").write_bytes(encoded(replaced))
            return fixture_verify(path, *args, **kwargs)

        with patch.object(upgrade, "verify", replace_after_fresh):
            reject(lambda: upgrade.finalize(old_backup, accepted_data_backup=current_backup, accepted_account_site_ids=["site-a"]))
        (data / "library.json").write_bytes(encoded(added))
        check(upgrade.load_state(old_backup)["phase"] == "installed")
        upgrade.finalize(old_backup, accepted_data_backup=current_backup, accepted_account_site_ids=["site-a"])
        final = upgrade.load_state(old_backup)
        check(final["phase"] == "finalized")
        check(final["counts"] == old_state["counts"] and final["files"] == old_state["files"]
              and final["keychain"] == old_state["keychain"])
        check(final["acceptedDataBackup"]["counts"]["accounts"] == 1
              and final["acceptedDataBackup"]["newAccounts"] == 1)
        check(final["acceptedDataBackup"]["stateSHA256"] == upgrade.digest((current_backup / "state.json").read_bytes()))
        check(final["rollbackApplications"] == {"搞门户.app": old_program}
              and upgrade.application_record(old_backup / "PreviousApplications/搞门户.app") == old_program)
        check((data / "library.json").read_bytes() == encoded(added)
              and (old_backup / "MenDao/library.json").read_bytes() == encoded(original))

print(f"Accepted account additions: {checks} isolated checks passed; no real apps, credentials or user data accessed.")
