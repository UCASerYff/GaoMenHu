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


print(f"Download authorization comparison tests passed: {checks}")
