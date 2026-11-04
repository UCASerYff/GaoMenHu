#!/usr/bin/env python3
"""Focused registration fixtures; no real process, LS query/mutation or user data.

Native metadata and immutable move receipts belong only to non-executable
synthetic directories inside our temporary .noindex container. Every subprocess
is intercepted, including codesign and lsregister.
"""
import copy
import json
import os
from pathlib import Path
import plistlib
import runpy
import subprocess
import tempfile
import types
import uuid


PROJECT = Path(__file__).resolve().parents[1]
loaded = runpy.run_path(str(PROJECT / "Scripts/backup_verify.py"), run_name="portal_registration_fixture")
m = loaded["refresh_application_registration"].__globals__
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
    except (RuntimeError, subprocess.CalledProcessError):
        check(True, label)
    else:
        raise AssertionError(label + ": unsafe operation accepted")


with tempfile.TemporaryDirectory(prefix="portal-registration-", suffix=".noindex", dir="/private/tmp") as temporary:
    outer = Path(temporary)
    original_load = m["load_state"]
    active = [None]

    def forbidden(*args, **kwargs):
        raise AssertionError("Real app/data/credentials/UI access is forbidden")

    for name in ("stop_owned_processes", "preferences", "native_hosts", "keychain_metadata", "snapshot", "verify"):
        m[name] = forbidden

    class Fixture:
        def __init__(self):
            self.root = outer / str(uuid.uuid4())
            self.apps = self.root / "Applications"
            self.backups = self.root / "Backups"
            self.backup = self.backups / ("升级-" + str(uuid.uuid4()) + ".noindex")
            self.previous = self.backup / "PreviousApplications"
            self.failed = self.backup / "FailedApplication.noindex"
            self.stage = self.apps / (".GaoMenHu-install-" + uuid.uuid4().hex + ".noindex")
            self.formal = self.apps / "搞门户.app"
            self.staged = self.stage / "搞门户.app"
            self.commands = []
            self.records = []
            self.query_failure = False
            self.query_override = None
            self.unregister_failure = False
            self.before_query = None
            self.after_register = None
            for path in (self.root, self.apps, self.backups, self.backup, self.previous, self.failed, self.stage):
                path.mkdir(mode=0o700)
            self.use()
            self.fake_app(self.formal, "1.16")
            self.fake_app(self.staged, "1.17")
            state = {"format": 1, "appID": m["APP_ID"], "phase": "replacing", "oldApplications": ["搞门户.app"],
                     "newVersion": "1.17", "newBuild": "117"}
            m["private_write"](self.backup / "state.json", m["_app_json"](state))
            m["bind_application_safety"](self.backup, {"搞门户.app": self.formal}, self.staged)
            # Exact failed-install/rollback layout: original is back at the
            # formal path, failed new original is sealed in .noindex, stage gone.
            m["move_application_original"](self.backup, "old:搞门户.app", self.previous / "搞门户.app")
            m["move_application_original"](self.backup, "new", self.formal)
            rollback_chain = m["application_authority"](self.backup)
            state = m["load_state"](self.backup)
            state["rollbackTransaction"] = {
                "format": 2, "fromPhase": state["phase"],
                "oldApplications": {"搞门户.app": rollback_chain["objects"]["old:搞门户.app"]["record"]},
                "retireCurrent": True,
                "retiredApplication": rollback_chain["objects"]["new"]["record"],
                "applicationSafetyAnchor": state["applicationSafety"]["anchorSHA256"],
            }
            state["failedApplicationPath"] = "FailedApplication.noindex/搞门户.app"
            state["phase"] = "rollingBack"
            m["update_state"](self.backup, state)
            m["move_application_original"](self.backup, "new", self.failed / "搞门户.app")
            m["move_application_original"](self.backup, "old:搞门户.app", self.formal)
            self.stage.rmdir()
            self.chain = m["application_authority"](self.backup)
            self.records = [self.record(self.formal, self.chain["objects"]["old:搞门户.app"]["record"])]
            self.commands = []

        def use(self):
            active[0] = self
            m["APPLICATIONS"] = self.apps
            m["BACKUPS"] = self.backups
            m["load_state"] = lambda path: original_load(path, self.backups)

        def fake_app(self, path, version):
            assert path.is_relative_to(outer)
            m["private_write"](path / "Contents/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": m["APP_ID"], "CFBundleExecutable": "MenDao",
                "CFBundleName": "搞门户", "CFBundleShortVersionString": version,
                "CFBundleVersion": version.replace(".", "")}))
            m["private_write"](path / "Contents/MacOS/MenDao", b"non-executable synthetic fixture " + version.encode())

        def record(self, path, metadata, identifier=None, name="搞门户"):
            return {"path": str(path), "identifier": identifier or m["APP_ID"], "codeInfoID": identifier or m["APP_ID"],
                    "name": name, "inode": metadata["metadataTree"]["."]["ino"],
                    "executableInode": metadata["metadataTree"]["Contents/MacOS/MenDao"]["ino"],
                    "version": metadata["version"], "build": metadata["build"]}

        def dump(self):
            if self.query_override is not None:
                return self.query_override
            blocks = []
            for index, row in enumerate(self.records, 1):
                blocks.append("\n".join([
                    "bundle id:                  " + row["name"] + " (0x%x)" % index,
                    "container:                  / (0x4)",
                    "mount state:                mounted",
                    "path:                       " + row["path"] + " (0x%x)" % (index + 20),
                    "directory:                  " + str(Path(row["path"]).parent),
                    "name:                       " + row["name"],
                    "displayName:                " + row["name"],
                    "identifier:                 " + row["identifier"],
                    "codeInfoID:                 " + row["codeInfoID"],
                    "executable:                 Contents/MacOS/MenDao",
                    "class:                      kLSBundleClassApplication (0x2)",
                    "versionString:              " + row["build"],
                    "displayVersion:             " + row["version"],
                    "inode:                      " + str(row["inode"]),
                    "exec inode:                 " + str(row["executableInode"]),
                ]))
            return "\n--------------------------------------------------------------------------------\n".join(blocks) + "\n"

        def refresh(self):
            self.use()
            m["refresh_application_registration"](self.backup)

        def ls_mutations(self):
            return [args for args in self.commands if args[0] == m["APP_LSREGISTER"] and args[1] != "-dump"]

    def fake_run(arguments, **kwargs):
        fixture = active[0]
        args = list(map(str, arguments))
        fixture.commands.append(args)
        stdout = ""
        if args[0] == "/usr/bin/codesign":
            assert args[1:3] == ["--verify", "--strict"] and Path(args[-1]).is_relative_to(outer)
        elif args[0] == m["APP_LSREGISTER"]:
            if args[1:] == ["-dump"]:
                if fixture.before_query:
                    callback = fixture.before_query
                    fixture.before_query = None
                    callback()
                if fixture.query_failure:
                    raise subprocess.CalledProcessError(67, args, output="", stderr="synthetic query failure")
                stdout = fixture.dump()
            elif len(args) == 3 and args[1] == "-u":
                assert Path(args[2]).is_relative_to(outer)
                if fixture.unregister_failure:
                    raise subprocess.CalledProcessError(1, args, output="", stderr="synthetic unregister failure")
                fixture.records = [row for row in fixture.records if row["path"] != args[2]]
            elif len(args) == 3 and args[1] == "-f":
                assert args[2] == str(fixture.formal)
                if fixture.after_register:
                    callback = fixture.after_register
                    fixture.after_register = None
                    callback()
            else:
                raise AssertionError("Unexpected registration command: " + repr(args))
        else:
            raise AssertionError("Unexpected external command: " + repr(args))
        if not kwargs.get("text") and not kwargs.get("encoding") and kwargs.get("universal_newlines") is not True:
            stdout = stdout.encode()
        return subprocess.CompletedProcess(args, 0, stdout=stdout, stderr="" if isinstance(stdout, str) else b"")

    m["subprocess"] = types.SimpleNamespace(run=fake_run, CalledProcessError=subprocess.CalledProcessError,
                                           PIPE=subprocess.PIPE, DEVNULL=subprocess.DEVNULL, STDOUT=subprocess.STDOUT)

    f = Fixture()
    before = {key: copy.deepcopy(value["record"]) for key, value in f.chain["objects"].items()}
    f.refresh()
    check(not any(args[1] == "-u" for args in f.ls_mutations()), "missing unregistered stage never receives blind unregister")
    check(any(args[1:] == ["-f", str(f.formal)] for args in f.ls_mutations()), "only sealed formal app is registered")
    check(all(m["application_record"](Path(value["path"])) == before[key] for key, value in f.chain["objects"].items()),
          "refresh preserves sealed original metadata and inodes")
    check(m["load_state"](f.backup)["phase"] == "rollingBack", "registration alone does not falsify rollback outcome")

    f = Fixture()
    original_new = f.chain["genesis"]["objects"]["new"]["record"]
    f.records.append(f.record(f.staged, original_new))
    f.refresh()
    check([args[2] for args in f.ls_mutations() if args[1] == "-u"] == [str(f.staged)],
          "remaining exact historical stage record alone is unregistered")

    f = Fixture()
    failed = f.failed / "搞门户.app"
    f.records.append(f.record(failed, f.chain["objects"]["new"]["record"]))
    f.refresh()
    check([args[2] for args in f.ls_mutations() if args[1] == "-u"] == [str(failed)] and failed.exists(),
          "existing sealed failed app unregisters only its actual record and stays preserved")

    for kind in ("unknown-bid-path", "unknown-same-name", "known-path-wrong-identity", "codeinfo-only"):
        f = Fixture()
        unknown = f.root / "Unknown.noindex/搞门户.app"
        row = f.record(unknown, f.chain["objects"]["new"]["record"])
        if kind == "unknown-same-name":
            row["identifier"] = row["codeInfoID"] = "invalid.synthetic.other"
        elif kind == "known-path-wrong-identity":
            row["path"] = str(f.staged)
            row["identifier"] = row["codeInfoID"] = "invalid.synthetic.other"
        elif kind == "codeinfo-only":
            row["path"] = str(f.root / "Unrelated.app")
            row["name"] = "Other"
            row["identifier"] = "invalid.synthetic.other"
            row["codeInfoID"] = m["APP_ID"]
        f.records.append(row)
        rejects(f.refresh, kind + " rejects without unregistering any unknown identity")
        check(not f.ls_mutations(), kind + " stops before any registration mutation")

    f = Fixture()
    f.query_override = f.dump().replace("\ndirectory:", "\npath: " + str(f.formal) + "\ndirectory:", 1)
    rejects(f.refresh, "duplicate path field cannot select a convenient owned path")
    check(not f.ls_mutations(), "ambiguous duplicate path is rejected before mutations")

    f = Fixture()
    foreign = f.record(f.staged, f.chain["genesis"]["objects"]["new"]["record"])
    foreign["inode"] += 10_000_000
    f.records.append(foreign)
    rejects(f.refresh, "known historical path with unknown inode is not accepted as owned")
    check(not f.ls_mutations(), "unknown inode at known path stops before any mutation")

    for kind in ("empty-dump", "malformed-target", "missing-positive-anchor", "query-failure"):
        f = Fixture()
        if kind == "empty-dump":
            f.query_override = "\n\n"
        elif kind == "malformed-target":
            f.query_override = "bundle id: 搞门户 (0x1)\nidentifier: cn.mendao.launcher\n"
        elif kind == "missing-positive-anchor":
            f.records = [f.record(f.staged, f.chain["genesis"]["objects"]["new"]["record"])]
        else:
            f.query_failure = True
        rejects(f.refresh, kind + " refuses to treat absence or query failure as success")
        check("applicationRegistration" not in m["load_state"](f.backup), kind + " writes no success receipt")

    f = Fixture()
    f.records.append(f.record(f.staged, f.chain["genesis"]["objects"]["new"]["record"]))
    f.unregister_failure = True
    rejects(f.refresh, "genuine unregister failure is propagated")
    check("applicationRegistration" not in m["load_state"](f.backup), "unregister failure never seals success")

    f = Fixture()
    state = m["load_state"](f.backup)
    state["applicationSafety"]["headSHA256"] = "0" * 64
    m["update_state"](f.backup, state)
    rejects(f.refresh, "changed immutable chain pointer refuses registration")
    check(not f.ls_mutations(), "pointer mismatch is detected before any registration mutation")

    f = Fixture()
    def change_pointer():
        state = m["load_state"](f.backup)
        state["applicationSafety"]["headSHA256"] = "0" * 64
        m["update_state"](f.backup, state)
    f.before_query = change_pointer
    rejects(f.refresh, "chain pointer changing during LS query is not accepted")
    check(not f.ls_mutations(), "post-query pointer mismatch is detected before mutations")

    f = Fixture()
    binary = f.formal / "Contents/MacOS/MenDao"
    def change_metadata():
        os.chmod(binary, 0o640)
    f.after_register = change_metadata
    rejects(f.refresh, "metadata changed during formal registration is detected")
    check("applicationRegistration" not in m["load_state"](f.backup), "post-registration metadata mismatch writes no success receipt")

print("Application registration:", checks, "focused synthetic checks passed; no real App, LS, data, Keychain, GUI or process used.")
