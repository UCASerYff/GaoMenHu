"""Windows registration and launch transport for GaoAction directory packages."""

import os
import re
import subprocess
import sys
from pathlib import Path

from .actions import MAX_MANIFEST_BYTES, _valid_bundle, filesystem_entry, strict_json
from .errors import AppError

REGISTRATION = r"Software\GaoSeries\GaoAction"


def descriptor_path():
    if getattr(sys, "frozen", False):
        return Path(sys.executable).parent / "GaoCapabilities.json"
    return Path(__file__).resolve().parents[2] / "GaoCapabilities.Windows.json"


def installed_registrations():
    if os.name != "nt":
        return {}
    import winreg

    entries = {}
    for hive in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
        for view in (winreg.KEY_WOW64_32KEY, winreg.KEY_WOW64_64KEY):
            try:
                with winreg.OpenKey(hive, REGISTRATION, access=winreg.KEY_READ | view) as root:
                    for index in range(min(256, winreg.QueryInfoKey(root)[0])):
                        bundle_id = winreg.EnumKey(root, index)
                        if not _valid_bundle(bundle_id):
                            continue
                        try:
                            with winreg.OpenKey(root, bundle_id) as key:
                                executable, exe_type = winreg.QueryValueEx(key, "Executable")
                                capabilities, cap_type = winreg.QueryValueEx(key, "Capabilities")
                            if exe_type == cap_type == winreg.REG_SZ and isinstance(executable, str) and isinstance(capabilities, str):
                                entries[bundle_id] = (Path(executable), Path(capabilities))
                        except (OSError, ValueError):
                            continue
            except OSError:
                continue
    return entries


def _declared_provider(bundle_id, entries):
    registration = entries.get(bundle_id)
    if not registration:
        raise AppError("没有找到已安装并登记 GaoAction 的接收方。", "provider_missing")
    executable, descriptor = registration
    try:
        if (not executable.is_absolute() or executable.suffix.lower() != ".exe" or executable.parent != descriptor.parent
                or ".." in executable.parts or descriptor.name.lower() != "gaocapabilities.json"
                or (os.name == "nt" and not re.fullmatch(r"[A-Za-z]:", executable.drive))):
            raise ValueError("registration path")
        for folder in reversed(executable.parents):
            filesystem_entry(folder, directory=True)
        filesystem_entry(executable)
        if not 0 < filesystem_entry(descriptor).st_size <= MAX_MANIFEST_BYTES:
            raise ValueError("descriptor length")
        with descriptor.open("rb") as source:
            raw = source.read(MAX_MANIFEST_BYTES + 1)
        if len(raw) > MAX_MANIFEST_BYTES:
            raise ValueError("descriptor length")
        document = strict_json(raw)
        runtime = document.get("windowsTransport")
        if (type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 1
                or document.get("bundleID") != bundle_id or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", str(document.get("appVersion")))
                or not isinstance(runtime, dict) or runtime.get("argument") != "--gaoaction"):
            raise ValueError("provider declaration")
    except (OSError, ValueError, TypeError, AttributeError, AppError) as exc:
        raise AppError("接收方的安装路径或 GaoAction 声明不可用。", "provider_incompatible") from exc
    return executable, document


class ActionTransport:
    def __init__(self, registrations=installed_registrations, spawn=subprocess.Popen):
        self.registrations = registrations
        self.spawn = spawn

    def targets(self, action):
        entries = self.registrations()
        providers = []
        for bundle_id in entries:
            try:
                _, document = _declared_provider(bundle_id, entries)
                _download_capability(document, action)
            except AppError:
                continue
            providers.append({"bundleID": bundle_id, "version": document["appVersion"]})
        return sorted(providers, key=lambda item: item["bundleID"])

    def verify(self, manifest):
        executable, document = _declared_provider(manifest["targetBundleID"], self.registrations())
        action = manifest["action"]
        if manifest["kind"] == "result":
            results = document.get("resultActions", document["windowsTransport"].get("resultActions"))
            if not isinstance(results, list) or action not in results:
                raise AppError("接收方未声明可接收这类结果。", "provider_incompatible")
        else:
            capability = _download_capability(document, action)
            schema = capability["parametersSchema"]
            parameters = manifest["parameters"]
            fields = schema["properties"]
            urls = fields["urls"]
            lower, upper = urls.get("minItems", 1), urls.get("maxItems", 32)
            if (set(parameters) - set(fields) or set(schema.get("required", [])) - set(parameters)
                    or type(lower) is not int or type(upper) is not int or not lower <= len(parameters["urls"]) <= upper
                    or ("mediaType" in parameters and not isinstance(parameters["mediaType"], str))
                    or ("mediaType" in parameters and parameters["mediaType"] not in fields["mediaType"].get("enum", []))):
                raise AppError("接收方未声明本次参数能力。", "provider_incompatible")
        return executable

    def send(self, package, manifest):
        executable = self.verify(manifest)
        try:
            self.spawn([str(executable), "--gaoaction", str(package.absolute())], cwd=str(executable.parent),
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as exc:
            raise AppError("接收方未能启动，交接包已保留。", "delivery_failed") from exc


def _download_capability(document, action):
    actions = document.get("actions")
    if action != "downloads.prepare" or not isinstance(actions, list):
        raise AppError("接收方未声明文件下载能力。", "provider_incompatible")
    matches = [item for item in actions if isinstance(item, dict) and item.get("action") == action]
    if len(matches) == 1:
        capability = matches[0]
        schema = capability.get("parametersSchema", {})
        fields = schema.get("properties", {}) if isinstance(schema, dict) else {}
        urls = fields.get("urls", {}) if isinstance(fields, dict) else {}
        item = urls.get("items", {}) if isinstance(urls, dict) else {}
        required = schema.get("required") if isinstance(schema, dict) else None
        media = fields.get("mediaType") if isinstance(fields, dict) else None
        if (capability.get("requiresUserConfirmation") is True and isinstance(schema, dict) and schema.get("type") == "object"
                and isinstance(required, list) and all(isinstance(field, str) for field in required) and "urls" in required
                and set(required) <= {"urls", "mediaType"} and isinstance(urls, dict) and urls.get("type") == "array"
                and isinstance(item, dict) and item.get("type") == "string"
                and (media is None or (isinstance(media, dict) and media.get("type") == "string" and isinstance(media.get("enum"), list)))):
            return capability
    raise AppError("接收方未声明须经复核的文件下载能力。", "provider_incompatible")
