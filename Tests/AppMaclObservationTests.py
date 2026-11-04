#!/usr/bin/env python3
"""Explicit root-MACL observation fixtures; never uses real apps or privileges.

Native program identity/move evidence belongs only to non-executable synthetic
directories under our temporary .noindex container. Codesign is intercepted and
the newly observed MACL is a record-level synthetic overlay: no MACL, permission,
LaunchServices, user data or application is actually written or launched.
"""
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import runpy
import tempfile
import uuid


PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("portal_macl_observation_fixture", PROJECT / "Scripts/app_macl_observation.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
checks = 0
MACL_KEY = base64.b64encode(b"com.apple.macl").decode("ascii")
MACL = bytes(range(72))
MACL_B64 = base64.b64encode(MACL).decode("ascii")


def encoded(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(",", ":"), allow_nan=False).encode()


def sha(value):
    return hashlib.sha256(value).hexdigest()


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
        raise AssertionError(label + ": unsafe observation accepted")


def record():
    def node(inode, mode):
        return {"dev": 30, "ino": inode, "uid": 501, "gid": 20,
                "mode": mode, "flags": 0, "size": 96, "nlink": 1, "mtime_ns": 1_800_000_000_000,
                "xattrs_b64": {}, "acl": {"present": False, "external_b64": None, "text_b64": None,
                                          "absenceProof": "synthetic explicit absence"}}
    return {"recordFormat": 2, "version": "1.17", "build": "117",
            "files": {"Contents/Info.plist": sha(b"synthetic info"), "Contents/MacOS/MenDao": sha(b"synthetic program")},
            "directories": ["Contents", "Contents/MacOS"],
            "metadataTree": {".": node(101, 0o40700), "Contents": node(102, 0o40700),
                             "Contents/MacOS": node(103, 0o40700), "Contents/MacOS/MenDao": node(104, 0o100600)}}


def observed(before):
    value = copy.deepcopy(before)
    value["metadataTree"]["."]["xattrs_b64"][MACL_KEY] = MACL_B64
    return value


def authority(before, after, **changes):
    value = {"format": 1, "operation": "new-formal-root-macl-observation.v1", "appID": "cn.mendao.launcher",
             "version": "1.17", "build": "117", "object": "new", "formalPath": "/Applications/搞门户.app",
             "upgradeBackup": "/private/tmp/synthetic-upgrade.noindex",
             "upgradeStateSHA256": sha(b"synthetic original installed state"),
             "applicationSafetyAnchorSHA256": sha(b"synthetic immutable anchor"),
             "applicationSafetyHeadSHA256": sha(b"synthetic immutable head"),
             "currentDataBackup": "/private/tmp/synthetic-current.noindex",
             "currentDataBackupStateSHA256": sha(b"synthetic independent current state"),
             "beforeRecordSHA256": sha(encoded(before)), "afterRecordSHA256": sha(encoded(after)),
             "maclBase64": MACL_B64, "maclSHA256": sha(MACL), "maclBytes": 72}
    value.update(changes)
    return value


def parsed(value):
    raw = encoded(value)
    return helper.parse_authority(raw, sha(raw))


before = record()
after = observed(before)
fact = authority(before, after)
before_copy, after_copy, fact_copy = encoded(before), encoded(after), encoded(fact)
helper.validate_transition(before, after, parsed(fact))
check(encoded(before) == before_copy and encoded(after) == after_copy and encoded(fact) == fact_copy,
      "exact explicit root addition is accepted without altering any input")
rejects(lambda: helper.parse_authority(encoded(fact), "0" * 64), "authority requires its independently supplied exact pin")
rejects(lambda: helper.validate_transition(before, before, parsed(fact)), "the exact new observed whole record is required")

for label, mutate in (
    ("program bytes", lambda value: value["files"].update({"Contents/MacOS/MenDao": sha(b"other program")})),
    ("root inode", lambda value: value["metadataTree"]["."].update(ino=999)),
    ("root permission", lambda value: value["metadataTree"]["."].update(mode=0o40750)),
    ("root flags", lambda value: value["metadataTree"]["."].update(flags=1)),
    ("root ACL", lambda value: value["metadataTree"]["."]["acl"].update(present=True)),
    ("root unknown xattr", lambda value: value["metadataTree"]["."]["xattrs_b64"].update({base64.b64encode(b"synthetic.extra").decode(): "AA=="})),
    ("child MACL", lambda value: value["metadataTree"]["Contents"]["xattrs_b64"].update({MACL_KEY: MACL_B64})),
    ("boolean replacing numeric metadata", lambda value: value["metadataTree"]["."].update(flags=False)),
    ("unknown record field", lambda value: value.update(unreviewed="new value")),
):
    changed = copy.deepcopy(after)
    mutate(changed)
    # Even a document pinned to this broader after record cannot authorize it.
    approved = parsed(authority(before, changed))
    rejects(lambda changed=changed, approved=approved: helper.validate_transition(before, changed, approved),
            label + " cannot be hidden behind a root MACL observation")

old_with_macl = observed(before)
new_macl = copy.deepcopy(after)
new_macl["metadataTree"]["."]["xattrs_b64"][MACL_KEY] = base64.b64encode(b"z" * 72).decode()
rejects(lambda: helper.validate_transition(old_with_macl, new_macl, parsed(authority(old_with_macl, new_macl))),
        "an existing MACL cannot be replaced as though it were originally absent")
wrong_raw = copy.deepcopy(after)
wrong_raw["metadataTree"]["."]["xattrs_b64"][MACL_KEY] = base64.b64encode(b"x" * 72).decode()
rejects(lambda: helper.validate_transition(before, wrong_raw, parsed(authority(before, wrong_raw))),
        "whole-record approval does not substitute a different raw attribute value")

for label, mutate in (
    ("old object", lambda value: value.update(object="old:搞门户.app")),
    ("different app identity", lambda value: value.update(appID="invalid.synthetic.other")),
    ("another operation", lambda value: value.update(operation="generic-ignore-xattrs")),
    ("boolean format", lambda value: value.update(format=True)),
    ("boolean size", lambda value: value.update(maclBytes=True)),
    ("73-byte payload", lambda value: value.update(maclBytes=73, maclBase64=base64.b64encode(b"z" * 73).decode(), maclSHA256=sha(b"z" * 73))),
    ("wrong raw digest", lambda value: value.update(maclSHA256="0" * 64)),
    ("wrong encoded raw", lambda value: value.update(maclBase64="***")),
    ("missing original state binding", lambda value: value.pop("upgradeStateSHA256")),
    ("same current and upgrade backup", lambda value: value.update(currentDataBackup=value["upgradeBackup"])),
):
    invalid = copy.deepcopy(fact)
    mutate(invalid)
    rejects(lambda invalid=invalid: parsed(invalid), label + " is outside this explicit authority schema")

duplicate = encoded(fact)[:-1] + b',"format":1}'
rejects(lambda: helper.parse_authority(duplicate, sha(duplicate)), "duplicate authority JSON fields are rejected")
nonfinite = encoded(fact)[:-1] + b',"unknown":NaN}'
rejects(lambda: helper.parse_authority(nonfinite, sha(nonfinite)), "non-finite authority JSON values are rejected")
wrong_version = copy.deepcopy(fact)
wrong_version["version"] = "1.99"
rejects(lambda: helper.validate_transition(before, after, parsed(wrong_version)), "authority version must match the exact program record")


# The fixture below exercises the real native move journal. Its only synthetic
# metadata is the explicit MACL overlay in application_record; no xattr is set.
loaded = runpy.run_path(str(PROJECT / "Scripts/backup_verify.py"), run_name="portal_macl_journal_fixture")
m = loaded["application_authority"].__globals__
real_record = m["application_record"]
real_load = m["load_state"]
active = [None]


def forbidden(*args, **kwargs):
    raise AssertionError("Real App, credentials, user data, LS or process access is forbidden")


for key in ("preferences", "native_hosts", "keychain_metadata", "snapshot", "verify", "stop_owned_processes",
            "query_application_registration", "refresh_application_registration"):
    m[key] = forbidden


def fake_signature(arguments):
    f = active[0]
    assert arguments[:3] == ["/usr/bin/codesign", "--verify", "--strict"]
    assert Path(arguments[3]).is_relative_to(f.root)
    f.signature_calls.append(arguments)


m["run_checked"] = fake_signature


def record_overlay(path):
    result = real_record(path)
    f = active[0]
    if f is not None and f.is_observed and Path(path) == f.formal:
        result["metadataTree"]["."]["xattrs_b64"][MACL_KEY] = MACL_B64
    return result


m["application_record"] = record_overlay


with tempfile.TemporaryDirectory(prefix="portal-macl-observation-", suffix=".noindex", dir="/private/tmp") as temporary:
    outer = Path(temporary)

    class Fixture:
        def __init__(self):
            self.root = outer / uuid.uuid4().hex
            self.apps = self.root / "Applications"
            self.backups = self.root / "Backups"
            self.backup = self.backups / ("升级-" + uuid.uuid4().hex + ".noindex")
            self.fresh = self.backups / ("升级-current-" + uuid.uuid4().hex + ".noindex")
            self.previous = self.backup / "PreviousApplications"
            self.stage = self.apps / (".GaoMenHu-install-" + uuid.uuid4().hex + ".noindex")
            self.formal = self.apps / "搞门户.app"
            self.staged = self.stage / "搞门户.app"
            self.is_observed = False
            self.signature_calls = []
            for path in (self.root, self.apps, self.backups, self.backup, self.fresh, self.previous, self.stage):
                path.mkdir(mode=0o700)
            self.use()
            self.fake_app(self.formal, "1.16")
            self.fake_app(self.staged, "1.17")
            state = {"format": 1, "appID": m["APP_ID"], "phase": "replacing", "oldApplications": ["搞门户.app"],
                     "newVersion": "1.17", "newBuild": "117"}
            m["private_write"](self.backup / "state.json", encoded(state))
            m["bind_application_safety"](self.backup, {"搞门户.app": self.formal}, self.staged)
            m["move_application_original"](self.backup, "old:搞门户.app", self.previous / "搞门户.app")
            m["move_application_original"](self.backup, "new", self.formal)
            state = m["load_state"](self.backup)
            state["phase"] = "installed"
            m["update_state"](self.backup, state)
            self.chain = m["application_authority"](self.backup)
            self.before = copy.deepcopy(self.chain["objects"]["new"]["record"])
            assert MACL_KEY not in self.before["metadataTree"]["."]["xattrs_b64"]
            self.old_record = copy.deepcopy(self.chain["objects"]["old:搞门户.app"]["record"])
            self.original_events = {p.name: p.read_bytes() for p in (self.backup / "ApplicationSafety").iterdir()}
            self.original_state = (self.backup / "state.json").read_bytes()
            fresh_state = {"format": 1, "appID": m["APP_ID"], "phase": "backedUp", "oldApplications": [],
                           "fixtureOnly": "complete independent current snapshot"}
            m["private_write"](self.fresh / "state.json", encoded(fresh_state))
            self.snapshot = {"path": str(self.fresh), "stateSHA256": sha(encoded(fresh_state)), "counts": {"fixture": 1}}
            self.is_observed = True
            self.after = m["application_record"](self.formal)
            self.fact = authority(self.before, self.after, formalPath=str(self.formal), upgradeBackup=str(self.backup),
                                  upgradeStateSHA256=sha(self.original_state),
                                  applicationSafetyAnchorSHA256=self.chain["hashes"][0],
                                  applicationSafetyHeadSHA256=self.chain["hashes"][-1],
                                  currentDataBackup=str(self.fresh), currentDataBackupStateSHA256=self.snapshot["stateSHA256"])
            self.fact_file = self.root / "private-observation-authority.json"
            m["private_write"](self.fact_file, encoded(self.fact))
            self.fact_pin = sha(encoded(self.fact))

        def use(self):
            active[0] = self
            m["APPLICATIONS"] = self.apps
            m["BACKUPS"] = self.backups
            m["load_state"] = lambda path: real_load(path, self.backups)

        def fake_app(self, path, version):
            assert path.is_relative_to(outer) and any(parent.name.endswith(".noindex") for parent in path.parents)
            m["private_write"](path / "Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": m["APP_ID"],
                "CFBundleExecutable": "MenDao", "CFBundleShortVersionString": version, "CFBundleVersion": version.replace(".", "")}))
            m["private_write"](path / "Contents/MacOS/MenDao", b"non-executable synthetic program " + version.encode())

        def rewrite_fact(self, **changes):
            self.fact.update(changes)
            raw = encoded(self.fact)
            self.fact_file.write_bytes(raw)
            self.fact_pin = sha(raw)

        def unchanged_events(self):
            return all((self.backup / "ApplicationSafety" / name).read_bytes() == raw
                       for name, raw in self.original_events.items())

        def observe(self, snapshot=None):
            self.use()
            # This is the only adapter if the parent chooses a different public
            # explicit function name; the tested behavior is not mocked here.
            return m["observe_application_macl"](self.backup, self.fact_file, self.fact_pin,
                                                  self.snapshot if snapshot is None else snapshot)

    f = Fixture()
    rejects(lambda: m["verify_application_objects"](f.backup),
            "ordinary identity verification rejects the unaccepted root addition")
    check(f.unchanged_events() and (f.backup / "state.json").read_bytes() == f.original_state,
          "default strict refusal leaves every original receipt and state unchanged")
    first_result = f.observe()
    accepted = m["verify_application_objects"](f.backup)
    check(accepted["objects"]["new"]["record"] == f.after and f.unchanged_events(),
          "explicit observation appends new identity without rewriting original events")
    check(accepted["objects"]["old:搞门户.app"]["record"] == f.old_record
          and m["application_record"](f.previous / "搞门户.app") == f.old_record,
          "old original remains completely unchanged after observation")
    check(m["load_state"](f.backup)["phase"] == "installed", "observation alone never claims finalized acceptance")
    event = accepted["events"][-1]
    check(event["kind"] == "app-root-macl-observed"
          and event["authoritySHA256"] == f.fact_pin
          and base64.b64decode(event["authorityBase64"], validate=True) == encoded(f.fact)
          and base64.b64decode(event["beforeStateBase64"], validate=True) == f.original_state,
          "appended evidence preserves the exact pinned authority and original state bytes")
    check(first_result["approvalSHA256"] == f.fact_pin and first_result["idempotent"] is False,
          "first explicit acceptance reports its exact approval without claiming a replay")
    count = len(accepted["events"])
    repeated = f.observe()
    check(len(m["application_authority"](f.backup)["events"]) == count and repeated["idempotent"] is True,
          "repeating the same explicit authority does not append another observation")
    check(MACL_KEY not in real_record(f.formal)["metadataTree"]["."]["xattrs_b64"],
          "observation records synthetic evidence without writing a MACL or permission")

    for label, mutate in (
        ("wrong original state hash", lambda item: item.rewrite_fact(upgradeStateSHA256="0" * 64)),
        ("wrong original head", lambda item: item.rewrite_fact(applicationSafetyHeadSHA256="0" * 64)),
        ("wrong original anchor", lambda item: item.rewrite_fact(applicationSafetyAnchorSHA256="0" * 64)),
        ("wrong fresh snapshot", lambda item: item.rewrite_fact(currentDataBackupStateSHA256="0" * 64)),
        ("wrong formal path", lambda item: item.rewrite_fact(formalPath=str(item.stage / "搞门户.app"))),
        ("wrong backup path", lambda item: item.rewrite_fact(upgradeBackup=str(item.fresh))),
    ):
        f = Fixture()
        mutate(f)
        rejects(f.observe, label + " cannot authorize a lifecycle event")
        check(f.unchanged_events() and (f.backup / "state.json").read_bytes() == f.original_state,
              label + " refuses before appending or updating a pointer")

    f = Fixture()
    wrong_snapshot = {**f.snapshot, "stateSHA256": "0" * 64}
    rejects(lambda: f.observe(snapshot=wrong_snapshot), "a different verified-current snapshot is outside the explicit authority")
    check(f.unchanged_events(), "wrong current snapshot cannot alter immutable original events")

    f = Fixture()
    state = m["load_state"](f.backup)
    state["phase"] = "acceptanceFailed"
    m["update_state"](f.backup, state)
    f.rewrite_fact(upgradeStateSHA256=sha((f.backup / "state.json").read_bytes()))
    rejects(f.observe, "non-installed phase cannot acquire the new-formal lifecycle exception")
    check(f.unchanged_events(), "wrong-phase observation preserves original event bytes")

    f = Fixture()
    destination = f.backup / "FailedApplication.noindex/搞门户.app"
    m["_append_application_event"](f.backup, {
        "kind": "move-intent", "moveID": str(uuid.uuid4()), "object": "new",
        "from": str(f.formal), "to": str(destination), "before": f.before,
    })
    pending = m["application_authority"](f.backup)
    f.rewrite_fact(upgradeStateSHA256=sha((f.backup / "state.json").read_bytes()),
                   applicationSafetyHeadSHA256=pending["hashes"][-1])
    pending_count = len(pending["events"])
    rejects(f.observe, "pending native movement cannot be completed or relabeled by a lifecycle observation")
    check(len(m["application_authority"](f.backup)["events"]) == pending_count and f.formal.exists(),
          "pending-move rejection neither recovers the movement nor appends an observation")

    f = Fixture()
    class SimulatedCrash(BaseException):
        pass
    real_update = m["update_state"]
    def interrupted_pointer(path, state):
        if Path(path) == f.backup and state["applicationSafety"]["count"] > len(f.chain["events"]):
            raise SimulatedCrash()
        return real_update(path, state)
    m["update_state"] = interrupted_pointer
    try:
        try:
            f.observe()
        except SimulatedCrash:
            pass
        else:
            raise AssertionError("synthetic failure did not reach post-event/pre-pointer boundary")
    finally:
        m["update_state"] = real_update
    interrupted = m["application_authority"](f.backup)
    check(len(interrupted["events"]) == len(f.chain["events"]) + 1
          and (f.backup / "state.json").read_bytes() == f.original_state,
          "event durability survives a simulated crash before its state pointer update")
    f.observe()
    resumed = m["application_authority"](f.backup)
    check(len(resumed["events"]) == len(interrupted["events"])
          and resumed["state"]["applicationSafety"]["headSHA256"] == resumed["hashes"][-1]
          and resumed["state"]["applicationSafety"]["count"] == len(resumed["events"]),
          "the same authority repairs only its committed pointer without replaying or duplicating the event")
    check(f.unchanged_events(), "post-event interruption never overwrites the original chain prefix")

    f = Fixture()
    f.observe()
    binary = f.formal / "Contents/MacOS/MenDao"
    os.chmod(binary, 0o640)
    rejects(lambda: m["verify_application_objects"](f.backup),
            "another real metadata drift remains rejected after the explicit observation")
    rejects(f.observe, "the same authority cannot hide another drift through its idempotent path")
    check(f.unchanged_events(), "later drift does not rewrite earlier lifecycle or baseline receipts")

    f = Fixture()
    rejects(lambda: m["_application_move_delta"](f.before, f.after, False),
            "lifecycle observation cannot borrow an unobserved native rename exception")
    check(f.unchanged_events(), "unobserved-rename rejection cannot append lifecycle evidence")

    # Couple the actual finalize entry to the actual append/replay machinery.
    # Only unrelated business snapshots and LS registration are synthetic here;
    # program identities, native receipts and the observation remain real logic.
    def wired_finalize(item, mutate_safety=False, **override):
        item.use()
        item.finalize_calls = []
        saved_functions = {key: m[key] for key in ("verify_exact_current_snapshot", "verify", "refresh_application_registration")}
        def current_snapshot(path):
            assert Path(path) == item.fresh
            item.finalize_calls.append(("snapshot", m["load_state"](item.backup)["applicationSafety"]["count"]))
            return copy.deepcopy(item.snapshot)
        def business_verify(path, **kwargs):
            assert Path(path) == item.backup
            current = m["load_state"](item.backup)
            item.finalize_calls.append(("business", current["applicationSafety"]["count"]))
            current["dataVerification"] = {"fixtureOnly": True}
            return current
        def registration(path):
            assert Path(path) == item.backup
            current = m["load_state"](item.backup)
            item.finalize_calls.append(("registration", current["applicationSafety"]["count"]))
            current["applicationRegistration"] = {"fixtureOnly": True}
            if mutate_safety:
                current["applicationSafety"]["headSHA256"] = "0" * 64
            m["update_state"](item.backup, current)
        m["verify_exact_current_snapshot"] = current_snapshot
        m["verify"] = business_verify
        m["refresh_application_registration"] = registration
        parameters = {"accepted_data_backup": item.fresh, "accepted_app_macl_authority": item.fact_file,
                      "accepted_app_macl_authority_sha256": item.fact_pin}
        parameters.update(override)
        try:
            m["finalize"](item.backup, **parameters)
        finally:
            m.update(saved_functions)

    f = Fixture()
    wired_finalize(f)
    finalized = m["application_authority"](f.backup)
    check(finalized["state"]["phase"] == "finalized"
          and finalized["state"]["applicationSafety"]["count"] == len(f.chain["events"]) + 1
          and finalized["state"]["applicationSafety"]["headSHA256"] == finalized["hashes"][-1],
          "actual finalize freezes and preserves the newly appended full Safety pointer")
    check(f.finalize_calls[0] == ("snapshot", len(f.chain["events"]))
          and all(count == len(f.chain["events"]) + 1 for _, count in f.finalize_calls[1:])
          and any(kind == "business" for kind, _ in f.finalize_calls)
          and any(kind == "registration" for kind, _ in f.finalize_calls),
          "fresh snapshot and observation precede strict program/business acceptance and entry-state freezing")
    check(f.unchanged_events()
          and finalized["objects"]["old:搞门户.app"]["record"] == f.old_record
          and finalized["state"]["acceptedDataBackup"]["appRootMaclObservation"]["approvalSHA256"] == f.fact_pin,
          "finalization records the explicit observation while preserving baseline and old original")

    f = Fixture()
    rejects(lambda: wired_finalize(f, mutate_safety=True),
            "registration-time Safety drift cannot be excluded from finalization's full-state CAS")
    pending_state = m["load_state"](f.backup)
    check(any(kind == "registration" for kind, _ in f.finalize_calls)
          and pending_state["phase"] == "installed" and "acceptedAt" not in pending_state
          and pending_state["applicationSafety"]["headSHA256"] == "0" * 64 and f.unchanged_events(),
          "post-registration pointer mismatch stays pending without restoring an earlier state or claiming acceptance")

    f = Fixture()
    rejects(lambda: wired_finalize(f, accepted_app_macl_authority_sha256=None),
            "finalize requires both the explicit authority and its independent pin")
    check(not f.finalize_calls and (f.backup / "state.json").read_bytes() == f.original_state and f.unchanged_events(),
          "missing authority pin refuses before snapshot, observation or finalization mutation")

    f = Fixture()
    rejects(lambda: wired_finalize(f, accepted_data_backup=None),
            "finalize cannot append the explicit observation without an independent current backup")
    check(not f.finalize_calls and (f.backup / "state.json").read_bytes() == f.original_state and f.unchanged_events(),
          "missing independent backup refuses before observation or strict program verification")

print("App MACL observation:", checks,
      "targeted synthetic checks passed; no real App, MACL, LS, credentials, user data or GUI touched.")
