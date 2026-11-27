"""Passive evidence for the bundled Chrome and Edge helper."""

import base64
import ctypes
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

from . import EXTENSION_ID, NATIVE_HOST_NAME
from .browser_session import PROFILE_SECONDS
from .browsers import executable, extension_directory
from .native import EXTENSION_ORIGIN

HOST_EXECUTABLE = "GaoMenHu-bridge.exe"
HOST_MANIFEST = NATIVE_HOST_NAME + ".json"
BROWSER_NAMES = {"chrome": "Chrome", "edge": "Edge"}
REGISTRY_VENDORS = {"chrome": (r"Google\Chrome",), "edge": (r"Microsoft\Edge", "Chromium", r"Google\Chrome")}
EXTENSION_FILES = ("background.js", "content.js", "popup.html", "popup.js", "popup.css", "icon16.png", "icon48.png", "icon128.png")
MANIFEST_LIMIT = 64 * 1024
ORIGIN = re.compile(r"chrome-extension://[a-p]{32}/")


def _evidence(status, code, detail):
    return {"status": status, "code": code, "detail": detail}


def _installation_root():
    return Path(sys.executable).absolute().parent if getattr(sys, "frozen", False) else None


def _local_drive_path(path):
    if not path.is_absolute() or not re.fullmatch(r"[a-zA-Z]:", path.drive):
        return False
    drive_type = ctypes.windll.kernel32.GetDriveTypeW
    drive_type.argtypes = (ctypes.c_wchar_p,)
    drive_type.restype = ctypes.c_uint
    return drive_type(path.anchor) in (2, 3, 6)  # removable, fixed, RAM disk


def _owned_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
        raise ValueError("Not a regular local package file")
    return info


def _plain_directory_chain(folder):
    for directory in (*reversed(folder.parents), folder):
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            return False
    return True


def _read_manifest(path):
    if _owned_file(path).st_size > MANIFEST_LIMIT:
        raise ValueError("Manifest is too large")
    with path.open("rb") as source:
        data = source.read(MANIFEST_LIMIT + 1)
    if len(data) > MANIFEST_LIMIT:
        raise ValueError("Manifest is too large")
    document = json.loads(data.decode("utf-8"))
    if not isinstance(document, dict):
        raise ValueError("Not a manifest object")
    return document


def _package_status(folder):
    if os.name == "nt" and not _local_drive_path(folder):
        return _evidence("unknown", "package_drive_unknown", "助手目录不在可核对的本地盘路径上。")
    try:
        if not _plain_directory_chain(folder):
            return _evidence("unknown", "package_redirected", "助手目录包含重定向，无法核对随安装提供的文件。")
        manifest = _read_manifest(folder / "manifest.json")
        public_key = base64.b64decode(manifest.get("key", ""), validate=True)
        hashed = hashlib.sha256(public_key).hexdigest()[:32]
        identity = hashed.translate(str.maketrans("0123456789abcdef", "abcdefghijklmnop"))
        permissions = manifest.get("permissions")
        if (manifest.get("manifest_version") != 3 or identity != EXTENSION_ID or not isinstance(permissions, list)
                or "nativeMessaging" not in permissions or manifest.get("background") != {"service_worker": "background.js"}):
            raise ValueError("Packaged extension identity or native messaging permission differs")
        if any(_owned_file(folder / name).st_size == 0 for name in EXTENSION_FILES):
            raise ValueError("Incomplete packaged extension")
    except FileNotFoundError:
        return _evidence("issue", "package_missing", "随安装提供的助手文件不完整。请用原安装包修复或覆盖安装搞门户。")
    except OSError:
        return _evidence("unknown", "package_unreadable", "无法读取随安装提供的助手目录。请检查当前 Windows 用户的文件权限。")
    except (TypeError, ValueError, RecursionError):
        return _evidence("issue", "package_invalid", "随安装提供的助手清单、扩展身份或所需文件异常。请用原安装包修复搞门户。")
    return _evidence("ok", "package_verified", "随安装提供的助手文件、扩展身份和原生消息权限已核对。")


def _registry_locations(registry, browser):
    vendors = REGISTRY_VENDORS[browser]
    # HKCU Software is shared. The machine view order follows Chrome and Edge's native messaging lookup.
    for hive, view, scope in (
        (registry.HKEY_CURRENT_USER, 0, "当前用户"),
        (registry.HKEY_LOCAL_MACHINE, registry.KEY_WOW64_32KEY, "此电脑 32 位登记"),
        (registry.HKEY_LOCAL_MACHINE, registry.KEY_WOW64_64KEY, "此电脑 64 位登记"),
    ):
        for vendor in vendors:
            subkey = rf"SOFTWARE\{vendor}\NativeMessagingHosts\{NATIVE_HOST_NAME}"
            name = vendor.rsplit("\\", 1)[-1]
            yield hive, view, subkey, f"{scope} · {name}"


def _registered_manifest(registry, browser):
    malformed = False
    for hive, view, subkey, source in _registry_locations(registry, browser):
        try:
            with registry.OpenKey(hive, subkey, 0, registry.KEY_QUERY_VALUE | view) as key:
                try:
                    value, kind = registry.QueryValueEx(key, "")
                except FileNotFoundError:
                    malformed = True
                    continue
        except FileNotFoundError:
            continue
        except OSError:
            return None, _evidence("unknown", "registration_unreadable", f"无法读取{source}。暂时无法确认浏览器会使用哪条登记。")
        if not isinstance(value, str) or kind not in (registry.REG_SZ, registry.REG_EXPAND_SZ):
            malformed = True
            continue
        if kind == registry.REG_EXPAND_SZ:
            return None, _evidence("unknown", "registration_expandable", f"{source}使用可展开的路径，无法核对浏览器实际读取的位置。")
        if not value or "\0" in value or not Path(value).is_absolute():
            return None, _evidence("issue", "registration_path_invalid", f"{source}的助手清单路径无效。请用搞门户安装包修复登记。")
        return (Path(value), source), None
    if malformed:
        return None, _evidence("issue", "registration_missing_value", "已找到助手登记项，但没有可读取的清单路径。请用搞门户安装包修复登记。")
    return None, _evidence("issue", "registration_missing", "未找到助手登记。请运行搞门户安装包，并选择注册 Chrome 和 Edge 的搞门户助手。")


def _same_path(left, right):
    return os.path.normcase(os.path.normpath(left)) == os.path.normcase(os.path.normpath(right))


def _registration_status(browser, root):
    if os.name != "nt":
        return _evidence("unknown", "registration_platform_unknown", "只能在 Windows 中核对浏览器助手登记。")
    import winreg

    entry, problem = _registered_manifest(winreg, browser)
    if problem is not None:
        return problem
    path, source = entry
    if root is None:
        return _evidence("unknown", "registration_other_runtime", f"已找到{source}。开发运行无法核对登记是否属于正式安装。")
    if not _local_drive_path(path):
        return _evidence("unknown", "registration_drive_unknown", f"{source}指向本地盘以外或特殊格式的路径，无法安全核对。")
    if not _same_path(path, root / HOST_MANIFEST):
        return _evidence("issue", "registration_manifest_elsewhere", f"{source}指向当前安装目录之外。请用当前搞门户安装包修复登记。")
    try:
        if not _plain_directory_chain(root):
            return _evidence("unknown", "registration_directory_redirected", f"{source}指定的安装目录包含重定向，无法核对助手清单。")
        manifest = _read_manifest(root / HOST_MANIFEST)
    except FileNotFoundError:
        return _evidence("issue", "registration_manifest_missing", f"{source}指向当前安装，但助手清单文件缺失。请用搞门户安装包修复。")
    except OSError:
        return _evidence("unknown", "registration_manifest_unreadable", f"{source}的助手清单无法读取。请检查安装目录权限。")
    except (ValueError, RecursionError):
        return _evidence("issue", "registration_manifest_invalid", f"{source}的助手清单格式不正确。请用搞门户安装包修复。")

    host = manifest.get("path")
    if (manifest.get("name") != NATIVE_HOST_NAME or manifest.get("type") != "stdio"
            or not isinstance(manifest.get("description"), str) or not isinstance(host, str) or not host or "\0" in host):
        return _evidence("issue", "registration_host_invalid", f"{source}的清单缺少正确的主机名称、类型或程序路径。请用搞门户安装包修复。")
    origins = manifest.get("allowed_origins")
    if (not isinstance(origins, list) or EXTENSION_ORIGIN not in origins
            or any(not isinstance(origin, str) or not ORIGIN.fullmatch(origin) for origin in origins)):
        return _evidence("issue", "registration_origin_invalid", f"{source}的清单未正确授权随安装提供的助手扩展。请用搞门户安装包修复。")
    host_path = Path(host)
    expected_host = root / HOST_EXECUTABLE
    if (host_path.anchor and not host_path.is_absolute()) or not _same_path(root / host_path, expected_host):
        return _evidence("issue", "registration_host_elsewhere", f"{source}的清单未指向当前安装的助手程序。请用搞门户安装包修复。")
    try:
        if _owned_file(expected_host).st_size == 0:
            raise ValueError("Empty native host executable")
    except (FileNotFoundError, ValueError):
        return _evidence("issue", "registration_host_missing", f"{source}的助手程序缺失或不完整。请用搞门户安装包修复。")
    except OSError:
        return _evidence("unknown", "registration_host_unreadable", f"无法核对{source}对应的助手程序。请检查安装目录权限。")
    return _evidence("ok", "registration_verified", f"已核对{source}的助手清单、扩展授权和当前安装的助手程序。")


def _browser_status(browser):
    try:
        found = executable(browser)
    except (OSError, ValueError):
        return _evidence("unknown", "browser_unreadable", "无法检查浏览器程序位置。请确认该浏览器能在 Windows 中打开。")
    if found:
        return _evidence("ok", "browser_found", "已找到 Windows 浏览器程序。")
    return _evidence("issue", "browser_not_found", "在常用安装位置和 Windows 应用登记中未找到浏览器程序。自定义安装位置可能无法识别。")


def diagnose_browsers(service):
    root = _installation_root()
    package = _package_status(root / "BrowserExtension" if root is not None else extension_directory())
    installed = {browser_id: (_browser_status(browser_id), _registration_status(browser_id, root)) for browser_id in BROWSER_NAMES}
    clients = service.browser_session.clients()
    now = service.clock()
    results = []
    for browser_id, name in BROWSER_NAMES.items():
        browser, registration = installed[browser_id]
        profiles = [{"label": row["label"], "ageSeconds": int(max(0, now - row["seen"]))}
                    for row in clients if row["browser"] == browser_id and now - row["seen"] < PROFILE_SECONDS]
        evidence_has_issue = any(item["status"] == "issue" for item in (browser, package, registration))
        if profiles:
            extension = _evidence("ok", "extension_observed", f"最近 {PROFILE_SECONDS} 秒内，已收到 {len(profiles)} 个浏览器资料的助手响应。")
            state = "connected"
            summary = ("已有资料响应。本机配置仍有问题，其他资料或下次连接可能受影响。" if evidence_has_issue
                       else "已有浏览器资料的助手连接到本次运行的搞门户。")
        else:
            extension = _evidence("unknown", "extension_unobserved", f"最近 {PROFILE_SECONDS} 秒未收到助手响应。请在目标浏览器资料的扩展页核对助手是否已加载及启用，再从扩展弹窗重新连接。")
            state = "attention" if evidence_has_issue else "indeterminate"
            summary = ("尚未收到资料响应。请先核对标出的本机问题，再重新检测。" if evidence_has_issue
                       else "尚未收到资料响应。无法从本机登记区分扩展状态、浏览器资料是否打开及浏览器策略限制。")
        results.append({"id": browser_id, "name": name, "state": state, "summary": summary, "browser": browser,
                        "package": package, "registration": registration, "extension": extension, "profiles": profiles})
    return {"ok": True, "browsers": results}
