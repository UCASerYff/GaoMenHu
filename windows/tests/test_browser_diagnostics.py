"""Verify diagnostic evidence without opening real browser profile data."""

import json
import os
import shutil
import stat
import sys
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

import pytest

from gaomenhu import NATIVE_HOST_NAME, browser_diagnostics as diagnostics, browsers
from gaomenhu.browser_session import PROFILE_SECONDS
from gaomenhu.errors import AppError
from gaomenhu.native import native_manifest
from gaomenhu.service import PortalService


class Registry:
    HKEY_CURRENT_USER = 101
    HKEY_LOCAL_MACHINE = 102
    KEY_QUERY_VALUE = 1
    KEY_WOW64_32KEY = 512
    KEY_WOW64_64KEY = 256
    REG_SZ = 1
    REG_EXPAND_SZ = 2

    def __init__(self):
        self.entries = {}
        self.opened = []

    def register(self, vendor, value, *, hive=HKEY_CURRENT_USER, view=0, kind=REG_SZ):
        self.entries[hive, view, rf"SOFTWARE\{vendor}\NativeMessagingHosts\{NATIVE_HOST_NAME}"] = (str(value), kind)

    def OpenKey(self, hive, subkey, reserved, access):
        assert reserved == 0 and access & self.KEY_QUERY_VALUE
        identifier = (hive, access & ~self.KEY_QUERY_VALUE, subkey)
        self.opened.append(identifier)
        if identifier not in self.entries:
            raise FileNotFoundError
        return nullcontext(self.entries[identifier])

    @staticmethod
    def QueryValueEx(value, name):
        assert name == ""
        if isinstance(value, OSError):
            raise value
        return value


def test_edge_checks_current_user_fallbacks_before_machine_and_32_before_64(tmp_path):
    registry = Registry()
    current_user_chrome = tmp_path / "current-user-chrome.json"
    machine_chrome = tmp_path / "machine-chrome.json"
    machine_edge = tmp_path / "machine-edge.json"
    registry.register(r"Google\Chrome", current_user_chrome)
    registry.register(r"Google\Chrome", machine_chrome, hive=registry.HKEY_LOCAL_MACHINE, view=registry.KEY_WOW64_32KEY)
    registry.register(r"Microsoft\Edge", machine_edge, hive=registry.HKEY_LOCAL_MACHINE, view=registry.KEY_WOW64_64KEY)

    entry, problem = diagnostics._registered_manifest(registry, "edge")
    assert problem is None and entry == (current_user_chrome, "当前用户 · Chrome")
    assert len(registry.opened) == 3
    assert diagnostics._registered_manifest(registry, "chrome")[0][0] == current_user_chrome

    del registry.entries[registry.HKEY_CURRENT_USER, 0, rf"SOFTWARE\Google\Chrome\NativeMessagingHosts\{NATIVE_HOST_NAME}"]
    entry, problem = diagnostics._registered_manifest(registry, "edge")
    assert problem is None and entry == (machine_chrome, "此电脑 32 位登记 · Chrome")


def test_missing_and_unreadable_registry_are_distinct(tmp_path):
    registry = Registry()
    assert diagnostics._registered_manifest(registry, "chrome")[1]["code"] == "registration_missing"
    denied = registry.HKEY_CURRENT_USER, 0, rf"SOFTWARE\Google\Chrome\NativeMessagingHosts\{NATIVE_HOST_NAME}"
    registry.entries[denied] = PermissionError()
    registry.register(r"Google\Chrome", tmp_path / "valid-fallback.json", hive=registry.HKEY_LOCAL_MACHINE, view=registry.KEY_WOW64_32KEY)
    entry, evidence = diagnostics._registered_manifest(registry, "chrome")
    assert entry is None and evidence["status"] == "unknown" and evidence["code"] == "registration_unreadable"


@pytest.fixture
def install(tmp_path, monkeypatch):
    if os.name != "nt":
        pytest.skip("Native messaging registry and local drive probe require Windows")
    root = tmp_path / "隔离安装"
    root.mkdir()
    package = root / "BrowserExtension"
    shutil.copytree(browsers.extension_directory(), package)
    host = root / diagnostics.HOST_EXECUTABLE
    host.write_bytes(b"isolated fixture regular file")
    manifest = native_manifest(host)
    manifest["path"] = host.name
    (root / diagnostics.HOST_MANIFEST).write_text(json.dumps(manifest), encoding="utf-8")
    registration = Registry()
    monkeypatch.setitem(sys.modules, "winreg", registration)
    monkeypatch.setattr(diagnostics, "_installation_root", lambda: root)
    monkeypatch.setattr(diagnostics, "executable", lambda browser: f"fixture-{browser}.exe")
    return root, registration, manifest


@pytest.mark.parametrize(("change", "code"), [
    ({"name": "cn.other.host"}, "registration_host_invalid"),
    ({"type": "other"}, "registration_host_invalid"),
    ({"allowed_origins": []}, "registration_origin_invalid"),
    ({"allowed_origins": [diagnostics.EXTENSION_ORIGIN, "chrome-extension://*/*"]}, "registration_origin_invalid"),
    ({"path": "other.exe"}, "registration_host_elsewhere"),
    ({"path": r"\\server\share\host.exe"}, "registration_host_elsewhere"),
])
def test_manifest_checks_host_identity_authorized_extension_and_current_binary(install, change, code):
    root, registry, manifest = install
    path = root / diagnostics.HOST_MANIFEST
    registry.register(r"Google\Chrome", path)
    path.write_text(json.dumps(manifest | change), encoding="utf-8")
    assert diagnostics._registration_status("chrome", root)["code"] == code


def test_no_manifest_reads_outside_expected_installation(install, tmp_path, monkeypatch):
    root, registry, _ = install
    other = tmp_path / "SensitiveFixture" / diagnostics.HOST_MANIFEST

    def reject_read(_):
        pytest.fail("Unexpected manifest read")

    monkeypatch.setattr(diagnostics, "_read_manifest", reject_read)
    registry.register(r"Google\Chrome", other)
    assert diagnostics._registration_status("chrome", root)["code"] == "registration_manifest_elsewhere"
    registry.register(r"Google\Chrome", r"\\fixture.invalid\share\cn.mendao.bridge.json")
    assert diagnostics._registration_status("chrome", root)["code"] == "registration_drive_unknown"
    registry.register(r"Google\Chrome", r"\\?\C:\fixture\cn.mendao.bridge.json")
    assert diagnostics._registration_status("chrome", root)["code"] == "registration_drive_unknown"


def test_registry_manifest_does_not_cross_an_installation_junction(install, monkeypatch):
    root, registry, _ = install
    registry.register(r"Google\Chrome", root / diagnostics.HOST_MANIFEST)
    original = Path.lstat

    def directory_metadata(path):
        if path == root.parent:
            return SimpleNamespace(st_mode=stat.S_IFDIR, st_file_attributes=stat.FILE_ATTRIBUTE_REPARSE_POINT)
        if path == root / diagnostics.HOST_MANIFEST:
            pytest.fail("Manifest lookup crossed a redirected parent directory")
        return original(path)

    monkeypatch.setattr(Path, "lstat", directory_metadata)
    registration = diagnostics._registration_status("chrome", root)
    assert registration["status"] == "unknown" and registration["code"] == "registration_directory_redirected"


def test_missing_wrong_and_verified_registration_are_actionable(install):
    root, registry, manifest = install
    registered = root / diagnostics.HOST_MANIFEST
    registry.register(r"Google\Chrome", registered)
    assert diagnostics._registration_status("chrome", root)["status"] == "ok"
    manifest["path"] = str(root / diagnostics.HOST_EXECUTABLE)
    registered.write_text(json.dumps(manifest), encoding="utf-8")
    assert diagnostics._registration_status("chrome", root)["status"] == "ok"
    (root / diagnostics.HOST_EXECUTABLE).unlink()
    assert diagnostics._registration_status("chrome", root)["code"] == "registration_host_missing"
    registered.write_text(" " * (diagnostics.MANIFEST_LIMIT + 1), encoding="utf-8")
    assert diagnostics._registration_status("chrome", root)["code"] == "registration_manifest_invalid"
    registered.unlink()
    assert diagnostics._registration_status("chrome", root)["code"] == "registration_manifest_missing"


def test_extension_bundle_independent_of_profile_confirmation(install):
    root, _, _ = install
    bundle = root / "BrowserExtension"
    assert diagnostics._package_status(bundle)["code"] == "package_verified"
    path = bundle / "manifest.json"
    original = path.read_text(encoding="utf-8")
    doc = json.loads(original)
    doc["permissions"].remove("nativeMessaging")
    path.write_text(json.dumps(doc), encoding="utf-8")
    assert diagnostics._package_status(bundle)["code"] == "package_invalid"
    path.write_text(original, encoding="utf-8")
    (bundle / "background.js").unlink()
    assert diagnostics._package_status(bundle)["code"] == "package_missing"


def test_only_recent_matching_browser_profile_confirms_extension(install, tmp_path):
    root, registry, _ = install
    registry.register(r"Microsoft\Edge", root / diagnostics.HOST_MANIFEST)
    now = [1000.0]
    service = PortalService(tmp_path / "MenDao", browser_probe=lambda: ["chrome", "edge"], clock=lambda: now[0])
    profile_id = str(uuid4())
    assert service.native_message({"type": "poll", "profileId": profile_id, "label": "隔离 Chrome 资料"}, "chrome")["ok"]
    now[0] += 2

    result = diagnostics.diagnose_browsers(service)
    chrome, edge = result["browsers"]
    assert chrome["state"] == "connected" and chrome["registration"]["status"] == "issue"
    assert chrome["extension"]["code"] == "extension_observed"
    assert chrome["profiles"] == [{"label": "隔离 Chrome 资料", "ageSeconds": 2}]
    assert edge["state"] == "indeterminate" and edge["extension"]["code"] == "extension_unobserved"
    assert edge["registration"]["status"] == "ok" and not edge["profiles"]
    serialized = json.dumps(result, ensure_ascii=False)
    assert str(root) not in serialized and profile_id not in serialized and "token" not in serialized

    now[0] += PROFILE_SECONDS
    chrome, edge = diagnostics.diagnose_browsers(service)["browsers"]
    assert chrome["state"] == "attention" and not chrome["profiles"]
    assert edge["state"] == "indeterminate"


def test_explicit_extension_manager_can_open_when_the_bundle_is_missing(tmp_path, monkeypatch):
    launches = []
    monkeypatch.setattr(browsers, "extension_directory", lambda: tmp_path / "missing")
    monkeypatch.setattr(browsers, "launch_browser", lambda *args: launches.append(args) or "fixture.exe")
    assert browsers.open_extension_setup("edge")["ok"]
    assert launches == [("edge", "edge://extensions/")]
    with pytest.raises(AppError, match="助手目录"):
        browsers.open_extension_setup()


def test_invalid_explicit_browser_never_opens_the_helper_folder(tmp_path, monkeypatch):
    (tmp_path / "manifest.json").write_text("{}", encoding="utf-8")
    monkeypatch.setattr(browsers, "extension_directory", lambda: tmp_path)
    monkeypatch.setattr(os, "startfile", lambda _path: pytest.fail("Unexpected Explorer window"), raising=False)
    for value in ("", 0, False, []):
        with pytest.raises(AppError, match="浏览器"):
            browsers.open_extension_setup(value)
