#!/usr/bin/env python3
"""Narrow download reauthorization acceptance fixtures.

Only in-memory JSON and a private temporary .noindex file tree are used. No App,
LS, volume query, browser, bookmark resolution, credentials or transport runs.
"""
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import uuid
from unittest.mock import patch


PROJECT = Path(__file__).resolve().parents[1]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, PROJECT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


model = load("portal_download_acceptance_fixture", "Scripts/download_acceptance.py")
checks = 0


def check(condition, label):
    global checks
    if not condition:
        raise AssertionError(label)
    checks += 1
    print("PASS", checks, label, flush=True)


def rejects(operation, label):
    try:
        operation()
    except RuntimeError:
        check(True, label)
    else:
        raise AssertionError(label + ": unsafe acceptance permitted")


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha(value):
    return hashlib.sha256(value).hexdigest()


def envelope(value):
    raw = encoded(value)
    return encoded({"payload": base64.b64encode(raw).decode("ascii"), "sha256": sha(raw)})


GRANT = "10000000-0000-4000-8000-000000000001"
JOB = "20000000-0000-4000-8000-000000000002"
ITEM = "30000000-0000-4000-8000-000000000003"
VOLUME = "40000000-0000-4000-8000-000000000004"
INSTALLATION = "50000000-0000-4000-8000-000000000005"
SOURCE = "https://example.invalid/synthetic.bin"
PAYLOAD = b"synthetic original published content"
OLD_BOOKMARK = base64.b64encode(b"synthetic old selection").decode("ascii")
NEW_BOOKMARK = base64.b64encode(b"synthetic explicit renewed selection").decode("ascii")


def original():
    return {
        "schemaVersion": 1, "revision": 40, "installationID": INSTALLATION,
        "migrationHistory": ["v1: fixture", "fixture explicit import"],
        "settings": {"concurrency": 2, "speedLimitBytesPerSecond": 0,
                     "maxItemBytes": 20 * 1024 ** 3, "maxStagingBytes": 40 * 1024 ** 3,
                     "appearance": "system"},
        "destinations": [{"id": GRANT, "displayPath": "/private/tmp/synthetic-selected.noindex",
                          "bookmark": OLD_BOOKMARK, "device": 28, "inode": 101,
                          "volumeUUID": VOLUME, "requiresReauthorization": True}],
        "jobs": [{"id": JOB, "requestID": "60000000-0000-4000-8000-000000000006",
                  "itemIDs": [ITEM], "createdAt": 810000000}],
        "items": [{"id": ITEM, "jobID": JOB, "destinationID": GRANT,
                   "state": "completed", "sourceURL": SOURCE,
                   "sourceFingerprint": sha(SOURCE.encode("utf-8")), "displayURL": SOURCE,
                   "suggestedName": "synthetic.bin", "bytesReceived": len(PAYLOAD),
                   "expectedBytes": len(PAYLOAD), "bytesPerSecond": 0,
                   "sha256": sha(PAYLOAD), "createdAt": 810000000,
                   "attempts": 1, "stagingName": ITEM + ".part", "stagingDevice": 28,
                   "stagingInode": 202, "partialSHA256": sha(PAYLOAD),
                   "artifact": {"fileName": "synthetic.bin", "byteCount": len(PAYLOAD),
                                "sha256": sha(PAYLOAD), "device": 28, "inode": 202}}],
    }


def renewed(value=None, revision=45, device=30):
    result = copy.deepcopy(original() if value is None else value)
    result["revision"] = revision
    result["destinations"][0].update(bookmark=NEW_BOOKMARK, device=device, requiresReauthorization=False)
    for item in result["items"]:
        if item["destinationID"] == GRANT:
            if "stagingDevice" in item:
                item["stagingDevice"] = device
            for field in ("artifact", "pendingArtifact"):
                if item.get(field) is not None:
                    item[field]["device"] = device
    return result


def accept(first=None, current=None, previous=None, grant=GRANT):
    return model.accepted_download_reauthorization(
        envelope(original() if first is None else first),
        envelope(renewed() if current is None else current),
        envelope(renewed(revision=44) if previous is None else previous), grant)


before = original()
current = renewed()
previous = renewed(revision=44)
input_bytes = (envelope(before), envelope(current), envelope(previous))
result = model.accepted_download_reauthorization(*input_bytes, GRANT)
check(isinstance(result, dict) and result["grantID"] == GRANT, "explicit original grant is the acceptance scope")
check(result["oldDevice"] == 28 and result["newDevice"] == 30,
      "verified normalization is the same grant across a mount device change")
check(result["directoryInode"] == 101 and result["volumeUUID"] == VOLUME,
      "original directory and volume identity are retained")
check((envelope(before), envelope(current), envelope(previous)) == input_bytes,
      "model verification does not modify original or current input objects")
check(OLD_BOOKMARK not in json.dumps(result) and NEW_BOOKMARK not in json.dumps(result),
      "acceptance metadata does not export bookmark bytes")
check(accept(current=renewed(device=28), previous=renewed(revision=44, device=28))["newDevice"] == 28,
      "explicit renewal also works when the current device number is unchanged")

# Unknown future fields are preserved by exact comparison, never dropped by a
# typed rewrite in order to make an otherwise changed model look acceptable.
extension = original()
extension["extensionPreserved"] = {"unknown": ["exact", {"nested": 1}]}
check(accept(extension, renewed(extension), renewed(extension, revision=44))["grantID"] == GRANT,
      "unchanged unknown fields remain part of the original model")
changed_extension = renewed(extension)
changed_extension["extensionPreserved"]["unknown"][1]["nested"] = 2
rejects(lambda: accept(extension, changed_extension, renewed(extension, revision=44)),
        "changed unknown fields cannot be discarded to obtain acceptance")
changed_extension["extensionPreserved"]["unknown"][1]["nested"] = True
rejects(lambda: accept(extension, changed_extension, renewed(extension, revision=44)),
        "JSON boolean is not interchangeable with an unknown numeric field")

for label, mutate in (
    ("different volume", lambda value: value["destinations"][0].update(volumeUUID=str(uuid.uuid4()))),
    ("missing volume", lambda value: value["destinations"][0].pop("volumeUUID")),
    ("invalid volume", lambda value: value["destinations"][0].update(volumeUUID="not-a-volume")),
    ("different directory inode", lambda value: value["destinations"][0].update(inode=102)),
    ("different original path", lambda value: value["destinations"][0].update(displayPath="/private/tmp/other.noindex")),
    ("empty renewed bookmark", lambda value: value["destinations"][0].update(bookmark="")),
    ("invalid renewed bookmark", lambda value: value["destinations"][0].update(bookmark="***")),
    ("reauthorization remains required", lambda value: value["destinations"][0].update(requiresReauthorization=True)),
    ("nonboolean cleared authorization", lambda value: value["destinations"][0].update(requiresReauthorization=0)),
    ("zero current device", lambda value: value["destinations"][0].update(device=0)),
    ("artifact device differs", lambda value: value["items"][0]["artifact"].update(device=31)),
    ("staging device differs", lambda value: value["items"][0].update(stagingDevice=31)),
    ("artifact inode replaced", lambda value: value["items"][0]["artifact"].update(inode=203)),
    ("artifact hash changed", lambda value: value["items"][0]["artifact"].update(sha256="0" * 64)),
    ("artifact byte count changed", lambda value: value["items"][0]["artifact"].update(byteCount=99)),
    ("source URL changed", lambda value: value["items"][0].update(sourceURL="https://example.invalid/other.bin")),
    ("item state changed", lambda value: value["items"][0].update(state="queued")),
    ("item byte count changed", lambda value: value["items"][0].update(bytesReceived=99)),
    ("staging inode changed", lambda value: value["items"][0].update(stagingInode=203)),
    ("job request identity changed", lambda value: value["jobs"][0].update(requestID=str(uuid.uuid4()))),
    ("test job remains", lambda value: value["jobs"].append({**value["jobs"][0], "id": str(uuid.uuid4())})),
    ("test item remains", lambda value: value["items"].append({**value["items"][0], "id": str(uuid.uuid4())})),
    ("test grant remains", lambda value: value["destinations"].append({**value["destinations"][0], "id": str(uuid.uuid4())})),
    ("migration history changed", lambda value: value["migrationHistory"].append("invented baseline")),
    ("settings changed", lambda value: value["settings"].update(concurrency=1)),
    ("current revision not increased", lambda value: value.update(revision=40)),
    ("boolean revision", lambda value: value.update(revision=True)),
):
    invalid = renewed()
    mutate(invalid)
    rejects(lambda value=invalid: accept(current=value), label + " is outside explicit reauthorization")

rejects(lambda: accept(grant=""), "missing explicit original grant is rejected")
rejects(lambda: accept(grant=str(uuid.uuid4())), "a different explicit grant cannot select a convenient record")
old_without_volume = original()
old_without_volume["destinations"][0].pop("volumeUUID")
rejects(lambda: accept(first=old_without_volume), "missing original UUID cannot be treated as a path grant")
already_authorized = original()
already_authorized["destinations"][0]["requiresReauthorization"] = False
rejects(lambda: accept(first=already_authorized), "the original receipt must require explicit reauthorization")

for label, mutate in (
    ("previous replaced original migration history", lambda value: value["migrationHistory"].__setitem__(0, "source older history")),
    ("previous still uses pre-import identity", lambda value: value.update(installationID=str(uuid.uuid4()))),
    ("previous changed original source URL", lambda value: value["items"][0].update(sourceURL="https://example.invalid/replaced.bin")),
    ("previous contains a test job", lambda value: value["jobs"].append({**value["jobs"][0], "id": str(uuid.uuid4())})),
    ("previous uses inconsistent device", lambda value: value["items"][0]["artifact"].update(device=29)),
    ("previous revision did not advance", lambda value: value.update(revision=40)),
    ("previous revision follows current", lambda value: value.update(revision=46)),
):
    invalid = renewed(revision=44)
    mutate(invalid)
    rejects(lambda value=invalid: accept(previous=value), label + " is rejected against original CURRENT model")

other_grant = original()
second_id = "70000000-0000-4000-8000-000000000007"
other_grant["destinations"].append({**copy.deepcopy(other_grant["destinations"][0]),
                                   "id": second_id, "inode": 303,
                                   "displayPath": "/private/tmp/another-selected.noindex"})
changed_other = renewed(other_grant)
changed_other["destinations"][1].update(bookmark=NEW_BOOKMARK, device=30, requiresReauthorization=False)
rejects(lambda: accept(other_grant, changed_other, renewed(other_grant, revision=44)),
        "one explicit grant never authorizes another grant's renewal")

broken = json.loads(envelope(renewed()))
broken["sha256"] = "0" * 64
rejects(lambda: model.accepted_download_reauthorization(envelope(original()), encoded(broken),
                                                       envelope(renewed(revision=44)), GRANT),
        "current envelope hash corruption is rejected")
broken_previous = json.loads(envelope(renewed(revision=44)))
broken_previous["payload"] = "***"
rejects(lambda: model.accepted_download_reauthorization(envelope(original()), envelope(renewed()),
                                                       encoded(broken_previous), GRANT),
        "invalid previous envelope base64 is rejected")


def raw_envelope(raw):
    return encoded({"payload": base64.b64encode(raw).decode("ascii"), "sha256": sha(raw)})


duplicate_current = encoded(renewed())[:-1] + b',"revision":45}'
rejects(lambda: model.accepted_download_reauthorization(envelope(original()), raw_envelope(duplicate_current),
                                                       envelope(renewed(revision=44)), GRANT),
        "duplicate payload JSON fields do not provide a selectable baseline")
overflow_current = encoded(renewed())[:-1] + b',"unknownNumber":1e9999}'
rejects(lambda: model.accepted_download_reauthorization(envelope(original()), raw_envelope(overflow_current),
                                                       envelope(renewed(revision=44)), GRANT),
        "overflowing JSON number cannot enter the accepted model")


# Even a legitimate model transition is not a default file-hash exemption.
# Keep this guard independent of future explicit finalize proof plumbing.
upgrade = load("portal_download_acceptance_installer_fixture", "Scripts/backup_verify.py")

# Exercise the production FD/hash witness with real owned temporary files.
# Only the internal-volume UUID query is replaced; the class, directory walks,
# file reads, hashes, identity checks and descriptor lifetime are real.
PhysicalVerifier = upgrade.DownloadAcceptancePhysical
real_volume_query = upgrade._download_acceptance_volume
with tempfile.TemporaryDirectory(prefix="portal-download-physical-", suffix=".noindex", dir="/private/tmp") as temporary:
    physical_outer = Path(temporary)
    try:
        for mode in ("missing-stage", "empty-stage", "content-change", "extra-hardlink", "path-replaced", "volume-changed"):
            selected = physical_outer / uuid.uuid4().hex
            selected.mkdir(mode=0o700)
            artifact = selected / "synthetic.bin"
            artifact.write_bytes(PAYLOAD)
            os.chmod(artifact, 0o600)
            directory_stat, artifact_stat = selected.stat(), artifact.stat()
            device = directory_stat.st_dev
            first = original()
            first["destinations"][0].update(displayPath=str(selected), device=device + 16,
                                            inode=directory_stat.st_ino)
            first["items"][0].update(stagingDevice=device + 16, stagingInode=artifact_stat.st_ino)
            first["items"][0]["artifact"].update(device=device + 16, inode=artifact_stat.st_ino)
            current = renewed(first, device=device)
            previous = renewed(first, revision=44, device=device)
            evidence = accept(first, current, previous)
            current_volume = [VOLUME]
            volume_calls = []
            def synthetic_volume(requested_device):
                assert requested_device == device
                volume_calls.append(requested_device)
                return current_volume[0]
            upgrade._download_acceptance_volume = synthetic_volume
            if mode == "empty-stage":
                (selected / (".GaoXiaZai-Staging-" + GRANT.upper())).mkdir(mode=0o700)
            witness = PhysicalVerifier(evidence)
            try:
                if mode in ("missing-stage", "empty-stage"):
                    witness.validate()
                    check(artifact.read_bytes() == PAYLOAD and artifact.stat().st_ino == artifact_stat.st_ino
                          and artifact.stat().st_mode & 0o777 == 0o600 and len(volume_calls) >= 2,
                          mode + " production physical verifier preserves the original non-executable artifact")
                elif mode == "content-change":
                    artifact.write_bytes(b"X" * len(PAYLOAD))
                    rejects(witness.validate, "physical witness rejects artifact bytes changed after construction")
                elif mode == "extra-hardlink":
                    os.link(artifact, selected / "extra-name.bin")
                    rejects(witness.validate, "physical witness rejects an extra artifact hard link")
                elif mode == "path-replaced":
                    os.rename(artifact, selected / "Displaced.bin")
                    artifact.write_bytes(PAYLOAD)
                    os.chmod(artifact, 0o600)
                    rejects(witness.validate, "physical witness rejects a replacement path with identical bytes")
                else:
                    current_volume[0] = str(uuid.uuid4())
                    rejects(witness.validate, "physical witness rejects a changed volume UUID")
            finally:
                witness.close()
            check(witness.root_fd == -1 and witness.stage_fd == -1 and not witness.files,
                  mode + " closes every production witness descriptor")
    finally:
        upgrade._download_acceptance_volume = real_volume_query


def forbidden(*args, **kwargs):
    raise AssertionError("No real credentials, system query, process or registration is allowed")


for function in ("preferences", "native_hosts", "keychain_metadata", "stop_owned_processes",
                 "query_application_registration", "run_checked"):
    setattr(upgrade, function, forbidden)

with tempfile.TemporaryDirectory(prefix="portal-download-acceptance-", suffix=".noindex", dir="/private/tmp") as temporary:
    root = Path(temporary)
    home, backups = root / "Home", root / "Backups"
    data = home / "Library/Application Support/MenDao"
    backup = backups / "升级-fixture.noindex"
    saved = backup / "MenDao"
    home.mkdir(mode=0o700)
    backups.mkdir(mode=0o700)
    backup.mkdir(mode=0o700)
    check(backups.stat().st_mode & 0o777 == 0o700 and backup.stat().st_mode & 0o777 == 0o700,
          "finalize fixture reaches acceptance guards under a valid private maintenance root")
    for path in (data, saved):
        path.mkdir(mode=0o700, parents=True)
    library = {"schema": 1, "sites": [], "tiles": [], "appearance": "system"}
    old_files = {"library.json": encoded(library), "DownloadCenter/downloads.json": envelope(original()),
                 "DownloadCenter/downloads.previous.json": envelope({**original(), "revision": 38,
                                                                       "migrationHistory": ["older source-only snapshot"]}),
                 "MailCenter/preserved-fixture.bin": b"unchanged synthetic mail evidence"}
    for name, raw in old_files.items():
        for target in (data / name, saved / name):
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            target.write_bytes(raw)
            os.chmod(target, 0o600)
    _, directories = upgrade.file_tree(saved)
    counts, _ = upgrade.validate_library(old_files["library.json"])
    state = {"format": 1, "appID": upgrade.APP_ID, "phase": "installed", "oldApplications": ["搞门户.app"],
             "newVersion": "1.17", "newBuild": "117", "files": {name: sha(raw) for name, raw in old_files.items()},
             "directories": directories, "counts": counts, "snapshots": 0,
             "preferencesSHA256": sha(plistlib.dumps({})), "nativeHosts": {}, "keychain": {"status": "fixture"}}
    (backup / "state.json").write_bytes(encoded(state))
    os.chmod(backup / "state.json", 0o600)
    (data / "DownloadCenter/downloads.json").write_bytes(envelope(renewed()))
    (data / "DownloadCenter/downloads.previous.json").write_bytes(envelope(renewed(revision=44)))
    old_state = (backup / "state.json").read_bytes()
    rejects(lambda: upgrade.verify(backup, home=home, backup_root=backups, keychain=False),
            "without explicit download acceptance the original strict file hashes still reject renewal")
    check((backup / "state.json").read_bytes() == old_state
          and all((saved / name).read_bytes() == raw for name, raw in old_files.items()),
          "default rejection leaves original backup and state unmodified")

    # Verify/finalize wiring uses only synthetic complete snapshots and explicit
    # test doubles for the already independently tested program/physical layers.
    prefs = plistlib.dumps({})
    (backup / "preferences.plist").write_bytes(prefs)
    os.chmod(backup / "preferences.plist", 0o600)
    credentials = {"passwordReferences": 0, "available": 0, "unavailable": 0, "status": "fixture"}
    state["keychain"] = credentials
    state["applicationSafety"] = {"format": 1, "fixtureOnly": True}
    (backup / "state.json").write_bytes(encoded(state))
    upgrade.BACKUPS = backups
    real_load = upgrade.load_state
    upgrade.load_state = lambda path, backup_root=backups: real_load(path, backups)
    real_verify = upgrade.verify
    def fixture_verify(path, *args, **kwargs):
        assert not args
        kwargs.update(home=home, backup_root=backups)
        return real_verify(path, **kwargs)
    upgrade.verify = fixture_verify
    upgrade.preferences = lambda: (prefs, {})
    upgrade.native_hosts = lambda home: {}
    upgrade.keychain_metadata = lambda ids: dict(credentials)
    checked = upgrade.verify(backup, _accepted_download_grant_id=GRANT)
    check(checked["counts"] == counts and (backup / "state.json").read_bytes() == encoded(state),
          "explicit model verification preserves account counts without inventing a new account")

    apps = root / "Applications"
    apps.mkdir(mode=0o700)
    previous_apps = backup / "PreviousApplications"
    previous_apps.mkdir(mode=0o700)
    formal = apps / "搞门户.app"
    upgrade.APPLICATIONS = apps
    app_info_calls = []
    def synthetic_app_info(path):
        app_info_calls.append(path)
        return {"CFBundleShortVersionString": "1.17", "CFBundleVersion": "117"}
    upgrade.app_info = synthetic_app_info
    command_calls = []
    def synthetic_signature(arguments):
        assert arguments == ["/usr/bin/codesign", "--verify", "--strict", str(formal)]
        command_calls.append(arguments)
    upgrade.run_checked = synthetic_signature
    chain = {"state": copy.deepcopy(state),
             "objects": {"new": {"path": str(formal), "record": {"fixture": "new"}},
                         "old:搞门户.app": {"path": str(previous_apps / "搞门户.app"),
                                           "record": {"fixture": "original preserved"}}}}
    upgrade.verify_application_objects = lambda path: copy.deepcopy(chain)
    registration_calls = []
    registration_mutation = [None]
    def synthetic_registration(path):
        registration_calls.append(path)
        current_state = upgrade.load_state(path)
        current_state["applicationRegistration"] = {"fixtureOnly": True}
        if registration_mutation[0] is not None:
            registration_mutation[0](current_state)
        upgrade.update_state(path, current_state)
    upgrade.refresh_application_registration = synthetic_registration

    physical_calls = []
    class SyntheticPhysical:
        def __init__(self, metadata, *args, **kwargs):
            check(metadata["grantID"] == GRANT, "physical verifier receives only the explicitly accepted grant")
            physical_calls.append("open")
        def validate(self):
            physical_calls.append("validate")
        def close(self):
            physical_calls.append("close")
        def __enter__(self):
            return self
        def __exit__(self, *args):
            self.close()
    upgrade.DownloadAcceptancePhysical = SyntheticPhysical

    app_info_before = len(app_info_calls)
    rejects(lambda: upgrade.finalize(backup, accepted_download_grant_id=GRANT),
            "explicit grant acceptance still requires an independent complete current backup")
    check(len(app_info_calls) == app_info_before + 1 and upgrade.load_state(backup)["phase"] == "installed" and not registration_calls,
          "missing current backup cannot finalize or alter program registration")

    fresh = backups / "升级-current-fixture.noindex"
    fresh.mkdir(mode=0o700)
    fresh_saved = fresh / "MenDao"
    fresh_saved.mkdir(mode=0o700)
    current_files, current_directories = upgrade.file_tree(data)
    for name, raw in current_files.items():
        target = fresh_saved / name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        target.write_bytes(raw)
        os.chmod(target, 0o600)
    fresh_state = {**copy.deepcopy(state), "phase": "backedUp", "oldApplications": [],
                   "files": {name: sha(raw) for name, raw in current_files.items()},
                   "directories": current_directories}
    fresh_state.pop("applicationSafety")
    (fresh / "state.json").write_bytes(encoded(fresh_state))
    (fresh / "preferences.plist").write_bytes(prefs)
    os.chmod(fresh / "state.json", 0o600)
    os.chmod(fresh / "preferences.plist", 0o600)
    app_info_before = len(app_info_calls)
    rejects(lambda: upgrade.finalize(backup, accepted_data_backup=fresh),
            "a current backup without an explicit acceptance purpose is insufficient")
    check(len(app_info_calls) == app_info_before + 1,
          "current-backup-only rejection reaches the explicit-purpose guard")
    app_info_before = len(app_info_calls)
    rejects(lambda: upgrade.finalize(backup, accepted_data_backup=backup, accepted_download_grant_id=GRANT),
            "original installation backup cannot impersonate the independent current backup")
    check(len(app_info_calls) == app_info_before + 1,
          "same-backup rejection reaches the independent-snapshot guard")
    for label, mutate in (
        ("counts", lambda value: value["counts"].update(accounts=value["counts"]["accounts"] + 1)),
        ("original file hashes", lambda value: value["files"].update({"library.json": "0" * 64})),
    ):
        initial_state = (backup / "state.json").read_bytes()
        registration_mutation[0] = mutate
        before_registration = len(registration_calls)
        with patch.object(Path, "home", return_value=home):
            rejects(lambda: upgrade.finalize(backup, accepted_data_backup=fresh, accepted_download_grant_id=GRANT),
                    "registration-time changes to " + label + " cannot replace the original acceptance state")
        check(len(registration_calls) == before_registration + 1
              and upgrade.load_state(backup)["phase"] == "installed",
              label + " mutation is detected after the actual registration callback and leaves finalization pending")
        # Only restore this deliberately mutated, self-owned synthetic fixture.
        # The production operation has no state-repair or baseline rewrite path.
        (backup / "state.json").write_bytes(initial_state)
        registration_mutation[0] = None
    registration_before = len(registration_calls)
    with patch.object(Path, "home", return_value=home):
        upgrade.finalize(backup, accepted_data_backup=fresh, accepted_download_grant_id=GRANT)
    final_state = upgrade.load_state(backup)
    check(final_state["phase"] == "finalized" and final_state["counts"] == counts,
          "download-only acceptance finalizes with zero invented account additions")
    check(final_state["acceptedDataBackup"]["path"] == str(fresh)
          and len(registration_calls) == registration_before + 1 and all(path == backup for path in registration_calls),
          "download-only finalization records its distinct complete current snapshot")
    check("validate" in physical_calls and "close" in physical_calls,
          "explicit finalization verifies and releases physical evidence scope")
    check(all((saved / name).read_bytes() == raw for name, raw in old_files.items()),
          "accepted current/previous transition never rewrites original data backup bytes")

print("Download acceptance:", checks,
      "targeted synthetic checks passed; no real App, data, credentials, LS, volume or transport used.")
