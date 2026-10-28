#!/usr/bin/env python3
"""Verified private snapshots and reversible two-phase upgrades.

No password value is requested. Browser profiles are never traversed. Backups
live in the project's git-ignored 用户数据备份 directory, never in release assets.
"""
import argparse
import ctypes
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parent.parent
APP_ID = "cn.mendao.launcher"
KEYCHAIN_SERVICE = APP_ID + ".passwords"
BACKUPS = ROOT / "用户数据备份"
APPLICATIONS = Path("/Applications")
APP_NAMES = ("搞门户.app", "门道.app")
MAX_FILE_BYTES = 2 * 1024 ** 3
MAX_TOTAL_BYTES = 4 * 1024 ** 3


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def regular_bytes(path):
    """Reject substituted final components, special files and changing bytes."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1,
                "发现非普通文件或硬链接，已停止备份。")
        require(before.st_size <= MAX_FILE_BYTES, "资料文件过大，已停止备份。")
        with os.fdopen(os.dup(fd), "rb") as stream:
            data = stream.read(MAX_FILE_BYTES + 1)
        after = os.fstat(fd)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                and len(data) == before.st_size, "资料正在变化，请结束操作后重试。")
        return data
    finally:
        os.close(fd)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def private_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def directory(path):
    require(path.is_absolute(), "目录必须为绝对路径。")
    # On macOS /var and /tmp are symlinks; production paths use their canonical
    # parents, while test roots are explicitly resolved by the fixture.
    for ancestor in (path, *path.parents):
        if ancestor.exists() or ancestor.is_symlink():
            require(stat.S_ISDIR(ancestor.lstat().st_mode), "资料或备份路径包含符号链接或非目录。")


def has_noindex_container(path):
    """Check real, existing containers rather than a lexical or symlink name."""
    resolved = path.resolve()
    return any(parent.name.endswith(".noindex") and parent.is_dir() and not parent.is_symlink()
               for parent in (resolved, *resolved.parents))


def validate_build_destination(path):
    require(path.is_absolute() and path.suffix == ".app", "测试 App 必须使用绝对 .app 路径。")
    require(not path.exists() and not path.is_symlink(), "测试 App 目标已存在，停止覆盖。")
    resolved = path.resolve()
    directory(resolved.parent)
    require(has_noindex_container(resolved.parent), "测试 App 必须位于预先创建的真实 .noindex 容器内。")
    return resolved


def file_tree(path):
    directory(path)
    require(path.is_dir(), "原资料目录缺失，不能当作空白覆盖。")
    result, directories, total = {}, [], 0
    for folder, child_dirs, files in os.walk(path, followlinks=False):
        for name in child_dirs:
            item = Path(folder) / name
            require(stat.S_ISDIR(item.lstat().st_mode), "资料目录包含符号链接，已停止备份。")
            directories.append(item.relative_to(path).as_posix())
        for name in files:
            item = Path(folder) / name
            if item == path / "bridge.sock" and stat.S_ISSOCK(item.lstat().st_mode):
                continue
            data = regular_bytes(item)
            total += len(data)
            require(total <= MAX_TOTAL_BYTES, "资料总量超过安全备份上限，已停止更新。")
            result[item.relative_to(path).as_posix()] = data
    return result, sorted(directories)


def valid_web_url(value):
    if not isinstance(value, str) or len(value) >= 8192:
        return False
    try:
        parsed = urllib.parse.urlsplit(value)
        return parsed.scheme.lower() in ("https", "http") and bool(parsed.hostname) and parsed.username is None and parsed.password is None
    except ValueError:
        return False


def validate_library(data):
    """Fail closed on broken/unknown structure; the app is the schema authority."""
    library = json.loads(data)
    require(isinstance(library, dict) and type(library.get("schema")) is int and library["schema"] == 1,
            "资料 schema 损坏或过新，已停止更新。")
    sites, tiles = library.get("sites"), library.get("tiles")
    require(isinstance(sites, list) and isinstance(tiles, list) and len(sites) <= 5000 and len(tiles) <= 5000, "网站资料结构无效。")
    require(isinstance(library.get("appearance", "system"), str)
            and library.get("layoutDensity") in (None, "compact", "comfortable")
            and library.get("iconSize") in (None, 60, 76, 92), "启动台布局设置无效。")
    ids, account_ids, password_ids = set(), set(), []
    for site in sites:
        require(isinstance(site, dict), "网站记录无效。")
        sid, allowed = site.get("id"), site.get("allowedBrowsers")
        require(isinstance(sid, str) and sid and sid not in ids and isinstance(site.get("name"), str)
                and site["name"].strip() and len(site["name"]) <= 100 and valid_web_url(site.get("url"))
                and isinstance(site.get("color"), str) and (site.get("icon") is None or isinstance(site["icon"], str))
                and (site.get("aliases") is None or isinstance(site["aliases"], str) and len(site["aliases"]) <= 500)
                and isinstance(allowed, list) and allowed and all(x in ("chrome", "edge", "safari", "firefox") for x in allowed)
                and site.get("defaultBrowser") in allowed and isinstance(site.get("profiles"), dict)
                and all(isinstance(k, str) and isinstance(v, str) for k, v in site["profiles"].items()), "网站或浏览器绑定无效。")
        ids.add(sid)
        accounts = site.get("accounts")
        require(isinstance(accounts, list) and len(accounts) <= 100, "账号引用无效。")
        local_ids = set()
        for account in accounts:
            require(isinstance(account, dict), "账号引用无效。")
            aid = account.get("id")
            require(isinstance(aid, str) and aid and aid not in account_ids
                    and type(account.get("hasPassword")) is bool
                    and isinstance(account.get("username"), str) and isinstance(account.get("label"), str)
                    and isinstance(account.get("loginHosts"), list), "账号或钥匙串引用无效。")
            for host in account["loginHosts"]:
                require(isinstance(host, str) and host and "*" not in host, "登录域名引用无效。")
                host_url = host.strip().lower()
                if "://" not in host_url:
                    host_url = "https://" + host_url
                require(valid_web_url(host_url), "登录域名引用无效。")
                parsed = urllib.parse.urlsplit(host_url)
                require(" " not in parsed.hostname and parsed.port is None and parsed.path in ("", "/")
                        and not parsed.query and not parsed.fragment, "登录域名范围无效。")
            account_ids.add(aid)
            local_ids.add(aid)
            if account["hasPassword"]:
                password_ids.append(aid)
        require(site.get("defaultAccount") is None or site["defaultAccount"] in local_ids, "默认账号引用缺失。")
    seen, tile_ids, folders = set(), set(), 0
    for tile in tiles:
        require(isinstance(tile, dict) and isinstance(tile.get("id"), str) and tile["id"] not in tile_ids, "图标编号无效。")
        tile_ids.add(tile["id"])
        if tile.get("kind") == "site":
            children = [tile["id"]]
        else:
            require(tile.get("kind") == "folder" and tile["id"] not in ids and isinstance(tile.get("name"), str)
                    and tile["name"] and isinstance(tile.get("children"), list) and tile["children"], "文件夹记录无效。")
            folders += 1
            children = tile["children"]
        for child in children:
            require(isinstance(child, str) and child in ids and child not in seen, "布局引用缺失或重复。")
            seen.add(child)
    workspaces = [] if library.get("workspaces") is None else library["workspaces"]
    require(isinstance(workspaces, list) and len(workspaces) <= 100, "工作场景格式无效。")
    workspace_ids = set()
    for workspace in workspaces:
        require(isinstance(workspace, dict) and isinstance(workspace.get("id"), str) and workspace["id"]
                and workspace["id"] not in workspace_ids and isinstance(workspace.get("name"), str)
                and workspace["name"].strip() and len(workspace["name"]) <= 60, "工作场景记录无效。")
        members = workspace.get("siteIDs")
        require(isinstance(members, list) and 1 <= len(members) <= 20 and all(isinstance(x, str) for x in members)
                and len(set(members)) == len(members) and all(x in ids for x in members), "工作场景网站引用无效。")
        workspace_ids.add(workspace["id"])
    return {"sites": len(sites), "folders": folders, "accounts": len(account_ids), "workspaces": len(workspaces)}, password_ids


def preferences():
    run = subprocess.run(["/usr/bin/defaults", "export", APP_ID, "-"], capture_output=True)
    require(run.returncode == 0, "无法完整读取原设置，已停止更新；不能当作空设置。")
    value = plistlib.loads(run.stdout)
    require(isinstance(value, dict), "设置格式无效。")
    return run.stdout, value


def native_hosts(home):
    result = {}
    for name, base in (("Chrome", "Google/Chrome"), ("Edge", "Microsoft Edge")):
        path = home / "Library/Application Support" / base / "NativeMessagingHosts/cn.mendao.bridge.json"
        directory(path.parent)
        if path.exists() or path.is_symlink():
            data = regular_bytes(path)
            host = json.loads(data)
            require(host.get("name") == "cn.mendao.bridge" and host.get("type") == "stdio"
                    and isinstance(host.get("path"), str) and isinstance(host.get("allowed_origins"), list), "本应用浏览器助手登记无效。")
            result[name] = data
        else:
            result[name] = None
    return result


def keychain_metadata(account_ids):
    """Check existence only; no data/attributes are returned and no UI allowed."""
    if not account_ids:
        return {"passwordReferences": 0, "available": 0, "unavailable": 0, "status": "noPasswordReferences"}
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
    ptr = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ptr
    cf.CFDictionaryCreateMutable.argtypes = [ptr, ctypes.c_long, ptr, ptr]
    cf.CFDictionaryCreateMutable.restype = ptr
    cf.CFDictionarySetValue.argtypes = [ptr, ptr, ptr]
    cf.CFRelease.argtypes = [ptr]
    security.SecItemCopyMatching.argtypes = [ptr, ctypes.POINTER(ptr)]
    security.SecItemCopyMatching.restype = ctypes.c_int32
    const = lambda name: ptr.in_dll(security, name).value
    service = cf.CFStringCreateWithCString(None, KEYCHAIN_SERVICE.encode(), 0x08000100)
    available, statuses = 0, []
    try:
        for aid in account_ids:
            query = cf.CFDictionaryCreateMutable(None, 0, None, None)
            account = cf.CFStringCreateWithCString(None, aid.encode(), 0x08000100)
            result = ptr()
            try:
                for key, value in (("kSecClass", const("kSecClassGenericPassword")), ("kSecAttrService", service),
                                   ("kSecAttrAccount", account), ("kSecUseAuthenticationUI", const("kSecUseAuthenticationUIFail"))):
                    cf.CFDictionarySetValue(query, const(key), value)
                code = security.SecItemCopyMatching(query, ctypes.byref(result))
                available += code == 0
                statuses.append(code)
            finally:
                if result.value:
                    cf.CFRelease(result)
                cf.CFRelease(query)
                cf.CFRelease(account)
    finally:
        cf.CFRelease(service)
    return {"passwordReferences": len(account_ids), "available": available, "unavailable": len(account_ids) - available,
            "status": "existenceOnlyNoInteraction", "statusCodes": sorted(set(statuses))}


def app_info(path):
    directory(path)
    info = plistlib.loads(regular_bytes(path / "Contents/Info.plist"))
    require(info.get("CFBundleIdentifier") == APP_ID and info.get("CFBundleExecutable") == "MenDao", "同名程序标识不符，已停止替换。")
    return info


def snapshot(home=Path.home(), backup_root=BACKUPS, keychain=True):
    files, dirs = file_tree(home / "Library/Application Support/MenDao")
    require("library.json" in files, "原网站库缺失，不能新建空库代替。")
    counts, account_ids = validate_library(files["library.json"])
    for path, data in files.items():
        if path.startswith("Snapshots/") and path.endswith(".json"):
            value = json.loads(data)
            require(isinstance(value, dict) and isinstance(value.get("metadata"), dict) and isinstance(value.get("library"), dict), "恢复快照损坏，已停止更新。")
            snapshot_counts, _ = validate_library(json.dumps(value["library"]).encode())
            metadata = value["metadata"]
            require(isinstance(metadata.get("id"), str) and str(uuid.UUID(metadata["id"])).lower() == metadata["id"].lower()
                    and path == "Snapshots/" + metadata["id"] + ".json"
                    and isinstance(metadata.get("createdAt"), (int, float)) and math.isfinite(metadata["createdAt"]) and metadata["createdAt"] > 0
                    and isinstance(metadata.get("reason"), str) and len(metadata["reason"]) <= 100
                    and metadata.get("siteCount") == snapshot_counts["sites"] and metadata.get("folderCount") == snapshot_counts["folders"],
                    "恢复快照编号或统计损坏，已停止更新。")
    pref_bytes, _ = preferences()
    hosts = native_hosts(home)
    directory(backup_root)
    backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(backup_root, 0o700)
    destination = backup_root / ("升级-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + str(uuid.uuid4()) + ".noindex")
    destination.mkdir(mode=0o700)
    for name in dirs:
        (destination / "MenDao" / name).mkdir(parents=True, exist_ok=True, mode=0o700)
    for name, data in files.items():
        private_write(destination / "MenDao" / name, data)
    private_write(destination / "preferences.plist", pref_bytes)
    for name, data in hosts.items():
        if data is not None:
            private_write(destination / "NativeMessagingHosts" / (name + ".json"), data)
    state = {"format": 1, "appID": APP_ID, "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "phase": "backedUp", "files": {name: digest(data) for name, data in files.items()}, "directories": dirs,
             "preferencesSHA256": digest(pref_bytes), "nativeHosts": {name: digest(data) if data is not None else None for name, data in hosts.items()},
             "counts": counts, "snapshots": sum(x.startswith("Snapshots/") and x.endswith(".json") for x in files),
             "keychain": keychain_metadata(account_ids) if keychain else {"status": "fixture"}, "oldApplications": []}
    private_write(destination / "state.json", json.dumps(state, ensure_ascii=False, indent=2).encode())
    verify(destination, home, backup_root, keychain=keychain)
    return destination


def load_state(backup, backup_root=BACKUPS):
    directory(backup_root)
    directory(backup)
    require(backup.parent == backup_root and backup.name.startswith("升级-"), "只允许处理本项目拥有的升级备份。")
    state = json.loads(regular_bytes(backup / "state.json"))
    require(state.get("format") == 1 and state.get("appID") == APP_ID, "升级备份标识不符。")
    require(state.get("phase") in ("backedUp", "replacing", "installed", "acceptanceFailed", "rollingBack", "rolledBack", "finalized"),
            "升级备份阶段无效或过新。")
    names = state.get("oldApplications")
    require(isinstance(names, list) and all(name in APP_NAMES for name in names)
            and len(names) == len(set(names)), "旧程序暂存清单无效。")
    if "rollbackApplications" in state:
        require(isinstance(state["rollbackApplications"], dict)
                and set(state["rollbackApplications"]) == set(names), "旧程序恢复收据无效。")
    if "failedApplicationPath" in state:
        require(state["failedApplicationPath"] == "FailedApplication.noindex/搞门户.app", "失败程序暂存路径无效。")
    if state["phase"] == "rollingBack":
        transaction = state.get("rollbackTransaction")
        require(isinstance(transaction, dict) and transaction.get("format") == 1
                and transaction.get("fromPhase") in ("replacing", "installed", "acceptanceFailed", "finalized")
                and isinstance(transaction.get("oldApplications"), dict)
                and set(transaction["oldApplications"]) == set(names)
                and type(transaction.get("retireCurrent")) is bool,
                "回滚事务收据缺失或无效；保留当前程序和备份。")
    return state


def update_state(backup, state):
    temp = backup / (".state-" + str(uuid.uuid4()))
    private_write(temp, json.dumps(state, ensure_ascii=False, indent=2).encode())
    os.replace(temp, backup / "state.json")
    sync_directory(backup)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def only_icon_cache_changed(original, current):
    first, second = json.loads(original), json.loads(current)
    fields = ("icon", "iconSource", "iconRevision", "iconSourcePixels", "iconCheckedAt")
    if not isinstance(first.get("sites"), list) or not isinstance(second.get("sites"), list) or len(first["sites"]) != len(second["sites"]):
        return False
    for old, new in zip(first["sites"], second["sites"]):
        if old.get("iconSource") == "custom" or new.get("iconSource") == "custom":
            if old != new:
                return False
        else:
            for field in fields:
                old.pop(field, None)
                new.pop(field, None)
    return first == second


def verify(backup, home=Path.home(), backup_root=BACKUPS, allowed_preferences=(), keychain=True, allow_icon_cache_updates=False):
    state = load_state(backup, backup_root)
    saved, saved_dirs = file_tree(backup / "MenDao")
    require({name: digest(data) for name, data in saved.items()} == state["files"] and saved_dirs == state["directories"], "安全备份已损坏，已停止更新。")
    files, dirs = file_tree(home / "Library/Application Support/MenDao")
    changed = [name for name, value in state["files"].items() if name not in files or digest(files[name]) != value]
    icon_only = (changed == ["library.json"] and "library.json" in files and
                 allow_icon_cache_updates and only_icon_cache_changed(saved["library.json"], files["library.json"]))
    require((not changed or icon_only)
            and set(state["directories"]).issubset(dirs), "原资料/附件内容改变或缺失，保留备份并停止验收。")
    counts, account_ids = validate_library(files["library.json"])
    require(counts == state["counts"], "资料数量或引用发生变化，已停止验收。")
    original_preferences = regular_bytes(backup / "preferences.plist")
    require(digest(original_preferences) == state["preferencesSHA256"], "设置备份校验失败。")
    _, current = preferences()
    original = plistlib.loads(original_preferences)
    require(all(key in current and current[key] == value for key, value in original.items() if key not in allowed_preferences),
            "已有设置发生变化；请检查允许变更的具体设置后验收。")
    hosts = native_hosts(home)
    for name, expected in state["nativeHosts"].items():
        if expected is not None:
            saved_host = regular_bytes(backup / "NativeMessagingHosts" / (name + ".json"))
            require(digest(saved_host) == expected and hosts[name] is not None, "助手绑定备份或当前登记缺失。")
            old, new = json.loads(saved_host), json.loads(hosts[name])
            for obj in (old, new):
                if obj.get("path") == "/Applications/门道.app/Contents/MacOS/MenDaoBridge":
                    obj["path"] = "/Applications/搞门户.app/Contents/MacOS/MenDaoBridge"
            require(old == new, "浏览器助手权限或绑定发生变化，已停止验收。")
    check = keychain_metadata(account_ids) if keychain else {"status": "fixture"}
    require(check == state["keychain"], "钥匙串属性可用性发生变化；未读取/覆盖任何密码。")
    state["dataVerification"] = {"originalFileHashesUnchanged": not changed, "onlyNonCustomIconCacheChanged": bool(icon_only),
                                 "libraryContentAndBindingsPreserved": True, "allowedPreferenceKeys": list(allowed_preferences)}
    return state


def stop_owned_processes():
    """Terminate only executables actually located in this app's install paths."""
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    owned = set()
    for name in APP_NAMES:
        root = APPLICATIONS / name
        if root.exists():
            app_info(root)
            for binary in ("MenDao", "MenDaoBridge"):
                owned.add(str(root / "Contents/MacOS" / binary))
    run = subprocess.run(["/bin/ps", "-axo", "pid="], capture_output=True, check=True)
    pids = []
    for line in run.stdout.splitlines():
        pid = int(line.strip())
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(pid, buffer, len(buffer)) > 0 and os.fsdecode(buffer.value) in owned:
            os.kill(pid, signal.SIGTERM)
            pids.append(pid)
    deadline = time.monotonic() + 5
    for pid in pids:
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("旧程序尚未退出，停止替换；没有强制结束或删除资料。")


def run_checked(arguments):
    subprocess.run(arguments, check=True)


def application_record(path):
    info = app_info(path)
    require(isinstance(info.get("CFBundleShortVersionString"), str)
            and isinstance(info.get("CFBundleVersion"), str), "程序版本信息无效。")
    run_checked(["/usr/bin/codesign", "--verify", "--strict", str(path)])
    files, dirs = file_tree(path)
    return {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "files": {name: digest(data) for name, data in files.items()}, "directories": dirs}


def rollback(backup, no_open=False, checkpoint=None):
    state = load_state(backup)
    require(state["phase"] in ("replacing", "installed", "acceptanceFailed", "finalized", "rollingBack"), "此备份没有待回滚的安装。")
    old_names = state["oldApplications"]
    require(old_names and set(old_names).issubset(APP_NAMES) and len(old_names) == len(set(old_names)), "旧程序记录无效。")
    current = APPLICATIONS / "搞门户.app"
    failed_container = backup / "FailedApplication.noindex"
    failed = failed_container / "搞门户.app"
    if state["phase"] != "rollingBack":
        finalized = state["phase"] == "finalized"
        if finalized:
            require(isinstance(state.get("rollbackApplications"), dict), "此旧收据没有保留可核验的程序回滚副本。")
            current_info = app_info(current)
            require(current_info.get("CFBundleShortVersionString") == state.get("newVersion")
                    and current_info.get("CFBundleVersion") == state.get("newBuild"), "当前安装已变化，不能回滚这份已验收记录。")
        records = {}
        for name in old_names:
            previous = backup / "PreviousApplications" / name
            original = APPLICATIONS / name
            if previous.exists():
                candidate = previous
            else:
                # Only the pre-rename phase may still have an old App at its
                # install path. Never infer an old App from a finalized new one.
                require(state["phase"] == "replacing", "旧程序回滚副本缺失，保留当前程序并停止回滚。")
                candidate = original
                info = app_info(candidate)
                require((info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
                        != (state.get("newVersion"), state.get("newBuild")), "旧程序身份不明确，不能把当前新版当作旧版。")
            records[name] = application_record(candidate)
            if finalized:
                require(records[name] == state["rollbackApplications"].get(name), "旧程序内容与验收恢复收据不符，停止回滚。")
        retire_current = current.exists() and ("搞门户.app" not in old_names
                          or (backup / "PreviousApplications/搞门户.app").exists())
        retired_record = None
        if retire_current:
            retired_record = application_record(current)
            require((retired_record["version"], retired_record["build"])
                    == (state.get("newVersion"), state.get("newBuild")), "当前安装已变化，不能暂存未知版本。")
            require(not failed_container.exists() and not failed_container.is_symlink(), "已存在失败程序副本，停止重复回滚。")
        # Commit and fsync the complete recovery plan before either App moves.
        state["rollbackTransaction"] = {"format": 1, "fromPhase": state["phase"],
                                        "oldApplications": records, "retireCurrent": retire_current,
                                        "retiredApplication": retired_record}
        if retire_current:
            state["failedApplicationPath"] = "FailedApplication.noindex/搞门户.app"
        state["phase"] = "rollingBack"
        update_state(backup, state)

    transaction = state["rollbackTransaction"]
    records = transaction["oldApplications"]
    retire_current = transaction["retireCurrent"]
    retired_record = transaction.get("retiredApplication")
    require((retire_current and isinstance(retired_record, dict)
             and state.get("failedApplicationPath") == "FailedApplication.noindex/搞门户.app")
            or (not retire_current and retired_record is None), "回滚事务中的新版程序收据无效。")
    # A fresh process accepts either the still-backed-up old App or the exact old
    # App already restored by an interrupted attempt, never merely a bundle ID.
    for name in old_names:
        previous = backup / "PreviousApplications" / name
        original = APPLICATIONS / name
        if previous.exists():
            require(application_record(previous) == records.get(name), "旧程序回滚副本与事务摘要不符。")
        else:
            require(original.exists() and application_record(original) == records.get(name), "回滚事务中的旧程序缺失或已变化。")
    if retire_current:
        if failed.exists():
            require(application_record(failed) == retired_record, "已暂存的新版程序与回滚事务不符。")
            if current.exists():
                require("搞门户.app" in records and application_record(current) == records["搞门户.app"],
                        "当前程序不是该事务已恢复的旧版本。")
        else:
            require(current.exists() and application_record(current) == retired_record,
                    "回滚事务缺少可核验的新版程序。")
            if failed_container.exists() or failed_container.is_symlink():
                directory(failed_container)
                require(not any(failed_container.iterdir()), "回滚暂存容器内容不明确。")
    stop_owned_processes()
    if retire_current and not failed.exists():
        if not failed_container.exists():
            failed_container.mkdir(mode=0o700)
            sync_directory(backup)
        require(current.stat().st_dev == failed_container.stat().st_dev, "无法原子暂存失败程序，保留当前程序。")
        require(application_record(current) == retired_record, "等待退出期间当前程序已变化，保留该程序并停止回滚。")
        os.rename(current, failed)
        sync_directory(APPLICATIONS)
        sync_directory(failed_container)
        if checkpoint:
            checkpoint("afterCurrentRetired")
    for name in old_names:
        source = backup / "PreviousApplications" / name
        destination = APPLICATIONS / name
        if destination.exists():
            require(application_record(destination) == records.get(name), "回滚目的地与旧程序摘要不符，停止覆盖。")
        else:
            require(source.exists() and application_record(source) == records.get(name), "回滚源程序缺失或已变化。")
            os.rename(source, destination)
            sync_directory(source.parent)
            sync_directory(APPLICATIONS)
            if checkpoint:
                checkpoint("afterOldRestored")
    state["phase"] = "rolledBack"
    update_state(backup, state)
    # Never overwrite user data automatically: preserve both current files and
    # the verified snapshot if application acceptance failed.
    if not no_open and old_names:
        verify(backup)
        run_checked(["/usr/bin/open", str(APPLICATIONS / old_names[0])])


def finalize(backup, allowed_preferences=(), allow_icon_cache_updates=False):
    state = load_state(backup)
    require(state["phase"] == "installed", "没有待验收的新版本。")
    require(state["oldApplications"], "缺少旧程序备份清单，不能完成验收。")
    info = app_info(APPLICATIONS / "搞门户.app")
    require(info["CFBundleShortVersionString"] == state["newVersion"] and info["CFBundleVersion"] == state["newBuild"], "安装版本与待验收记录不符。")
    run_checked(["/usr/bin/codesign", "--verify", "--strict", str(APPLICATIONS / "搞门户.app")])
    checked = verify(backup, allowed_preferences=allowed_preferences, allow_icon_cache_updates=allow_icon_cache_updates)
    # Acceptance retires the old installation, but preserves a verified program
    # backup. Never rename a historical receipt/container merely to hide its App.
    records = {}
    for name in state["oldApplications"]:
        old = backup / "PreviousApplications" / name
        require(has_noindex_container(old.parent), "旧程序备份缺少 .noindex 保护；请先核对恢复路径，不能删除回滚副本。")
        records[name] = application_record(old)
    state["phase"] = "finalized"
    state["rollbackApplications"] = records
    state["dataVerification"] = checked["dataVerification"]
    state["acceptedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    update_state(backup, state)


def install(no_open=False, home=None):
    home = Path.home() if home is None else home
    version = (ROOT / "VERSION").read_text().strip()
    package = ROOT / "Release" / ("GaoMenHu-" + version + ".dmg")
    checksum = regular_bytes(package.with_suffix(".dmg.sha256")).decode().split()
    require(len(checksum) == 2 and checksum[0] == digest(regular_bytes(package)) and checksum[1] == package.name, "安装包 SHA256 校验失败。")
    directory(APPLICATIONS)
    old_names = []
    for name in APP_NAMES:
        old = APPLICATIONS / name
        if old.exists() or old.is_symlink():
            app_info(old)
            run_checked(["/usr/bin/codesign", "--verify", "--strict", str(old)])
            old_names.append(name)
    require(old_names, "未找到可安全替换的旧搞门户程序，停止升级。")
    if BACKUPS.exists():
        directory(BACKUPS)
        for path in BACKUPS.iterdir():
            if path.is_dir() and path.name.startswith("升级-"):
                previous = load_state(path)
                require(previous.get("phase") not in ("replacing", "installed", "acceptanceFailed", "rollingBack"), "已有升级待验收或回滚，请先处理现有安全备份。")
    with tempfile.TemporaryDirectory(prefix="mendao-install-", suffix=".noindex", dir="/private/tmp") as mount, \
            tempfile.TemporaryDirectory(prefix=".GaoMenHu-install-", suffix=".noindex", dir=APPLICATIONS) as staging:
        backup = None
        staged = Path(staging) / "搞门户.app"
        mounted, replaced = False, False
        try:
            run_checked(["/usr/bin/hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", mount, str(package)])
            mounted = True
            source = Path(mount) / "搞门户.app"
            info = app_info(source)
            require(info["CFBundleShortVersionString"] == version and info["CFBundleVersion"] == version.replace(".", ""), "安装包版本或构建号不符。")
            require(not (source / "Contents/Resources/UI.js").exists(), "不能安装隔离测试程序。")
            run_checked(["/usr/bin/codesign", "--verify", "--strict", str(source)])
            run_checked(["/usr/bin/ditto", str(source), str(staged)])
            app_info(staged)
            run_checked(["/usr/bin/codesign", "--verify", "--strict", str(staged)])
            files, _ = file_tree(home / "Library/Application Support/MenDao")
            require("library.json" in files, "原网站库缺失，停止升级。")
            validate_library(files["library.json"])
            preferences()
            native_hosts(home)
            stop_owned_processes()
            backup = snapshot()
            previous = backup / "PreviousApplications"
            previous.mkdir(mode=0o700)
            # Atomic renames preserve the exact old application. Refuse a
            # cross-volume backup instead of copy/delete losing rollback safety.
            require(all((APPLICATIONS / name).stat().st_dev == previous.stat().st_dev for name in old_names),
                    "旧程序与备份不在同一文件系统，无法安全暂存；停止替换。")
            state = load_state(backup)
            state.update(phase="replacing", oldApplications=old_names, newVersion=version, newBuild=info["CFBundleVersion"], packageSHA256=checksum[0])
            update_state(backup, state)
            replaced = True
            for name in old_names:
                os.rename(APPLICATIONS / name, previous / name)
            os.rename(staged, APPLICATIONS / "搞门户.app")
            run_checked(["/usr/bin/codesign", "--verify", "--strict", str(APPLICATIONS / "搞门户.app")])
            verify(backup)
            state["phase"] = "installed"
            update_state(backup, state)
            if not no_open:
                run_checked(["/usr/bin/open", str(APPLICATIONS / "搞门户.app")])
            print("已安装搞门户 V" + version + "；旧程序保留至主要业务验收。")
            print("BACKUP=" + str(backup))
        except Exception:
            if replaced and backup is not None:
                rollback(backup, no_open=True)
            raise
        finally:
            # The unique private .noindex TemporaryDirectory also removes a
            # partial ditto result that has not yet acquired an Info.plist.
            if mounted:
                run_checked(["/usr/bin/hdiutil", "detach", "-quiet", mount])


def self_test():
    """Isolated filesystem/state-machine tests; no real apps, settings or UI."""
    global preferences, APPLICATIONS, BACKUPS, ROOT, load_state, run_checked, stop_owned_processes, verify, snapshot
    import copy
    import socket
    checks = 0

    def ok(condition):
        nonlocal checks
        assert condition
        checks += 1

    def rejects(call):
        nonlocal checks
        try:
            call()
        except (RuntimeError, OSError, ValueError, TypeError, KeyError):
            checks += 1
        else:
            raise AssertionError("unsafe fixture accepted")

    site = {"id": "site-1", "name": "Example", "url": "https://example.org", "color": "#000000", "icon": None,
            "allowedBrowsers": ["edge"], "defaultBrowser": "edge", "accounts": [], "profiles": {"edge": "fixture-profile"}}
    library = {"schema": 1, "sites": [site], "tiles": [{"id": "site-1", "kind": "site"}], "appearance": "system"}
    encoded = json.dumps(library).encode()
    ok(validate_library(encoded)[0] == {"sites": 1, "folders": 0, "accounts": 0, "workspaces": 0})
    for mutation in (lambda x: x.update(schema=2), lambda x: x.update(workspaces={}),
                     lambda x: x["sites"][0].update(defaultBrowser="chrome"),
                     lambda x: x["sites"][0].update(allowedBrowsers=[]),
                     lambda x: x["sites"][0].update(defaultAccount="missing"),
                     lambda x: x["sites"][0].update(profiles=[]),
                     lambda x: x["tiles"].append({"id": "missing", "kind": "site"})):
        invalid = copy.deepcopy(library)
        mutation(invalid)
        rejects(lambda: validate_library(json.dumps(invalid).encode()))
    changed = copy.deepcopy(library)
    changed["sites"][0].update(iconCheckedAt=123, iconSource="remote", icon="data:image/png;base64,fixture")
    ok(only_icon_cache_changed(encoded, json.dumps(changed).encode()))
    changed["sites"][0]["profiles"]["edge"] = "different-profile"
    ok(not only_icon_cache_changed(encoded, json.dumps(changed).encode()))
    changed = copy.deepcopy(library)
    changed["sites"][0].update(iconSource="custom", icon="changed")
    ok(not only_icon_cache_changed(encoded, json.dumps(changed).encode()))
    with tempfile.TemporaryDirectory(prefix="mendao-upgrade-", dir="/private/tmp") as temp:
        # Even fixture bundles acquire the product bundle ID only after their
        # non-indexed parent has been created.
        outer = Path(temp).resolve()
        root = outer / "Fixtures.noindex"
        root.mkdir(mode=0o700)
        ok(validate_build_destination(root / "Target.app") == root / "Target.app")
        rejects(lambda: validate_build_destination(outer / "Unindexed.app"))
        rejects(lambda: validate_build_destination(Path("relative.noindex/Target.app")))
        rejects(lambda: validate_build_destination(root / "WrongExtension"))
        (root / "Existing.app").mkdir()
        rejects(lambda: validate_build_destination(root / "Existing.app"))
        (root / "Alias.app").symlink_to(root / "Missing.app")
        rejects(lambda: validate_build_destination(root / "Alias.app"))
        (outer / "Plain").mkdir()
        (outer / "Pretend.noindex").symlink_to(outer / "Plain", target_is_directory=True)
        rejects(lambda: validate_build_destination(outer / "Pretend.noindex/Target.app"))
        (outer / "Not.noindex-extra").mkdir()
        rejects(lambda: validate_build_destination(outer / "Not.noindex-extra/Target.app"))
        home = root / "h"
        data = home / "Library/Application Support/MenDao"
        data.mkdir(parents=True, mode=0o700)
        private_write(data / "library.json", encoded)
        private_write(data / "Attachments/fixture.txt", b"private fixture\n")
        prefs = {"Geometry": "old", "Usage": b"private fixture"}
        preferences = lambda: (plistlib.dumps(prefs), copy.deepcopy(prefs))
        backup_root = root / "Backups"
        sock = socket.socket(socket.AF_UNIX)
        sock.bind(str(data / "bridge.sock"))
        try:
            backup = snapshot(home, backup_root, keychain=False)
            state = verify(backup, home, backup_root, keychain=False)
            ok(backup.name.endswith(".noindex") and state["format"] == 1)
            ok(has_noindex_container(backup / "PreviousApplications"))
            # Legacy format-1 names and their relative paths remain readable;
            # this only renames an owned fixture, never a real receipt.
            receipt_before_rename = load_state(backup, backup_root)
            legacy = backup.with_name(backup.name.removesuffix(".noindex"))
            backup.rename(legacy)
            ok(load_state(legacy, backup_root) == receipt_before_rename)
            legacy.rename(backup)
            ok(state["dataVerification"]["originalFileHashesUnchanged"])
            ok("bridge.sock" not in state["files"])
            ok((backup.stat().st_mode & 0o777) == 0o700)
            ok(((backup / "MenDao/library.json").stat().st_mode & 0o777) == 0o600)
            private_write(data / "Exchange/new.txt", b"new operation")
            ok(verify(backup, home, backup_root, keychain=False)["counts"] == state["counts"])
            prefs["Geometry"] = "new"
            rejects(lambda: verify(backup, home, backup_root, keychain=False))
            ok(verify(backup, home, backup_root, ("Geometry",), keychain=False)["dataVerification"]["allowedPreferenceKeys"] == ["Geometry"])
            prefs["Geometry"] = "old"
            saved = (data / "Attachments/fixture.txt").read_bytes()
            (data / "Attachments/fixture.txt").unlink()
            rejects(lambda: verify(backup, home, backup_root, keychain=False))
            private_write(data / "Attachments/fixture.txt", saved + b"changed")
            rejects(lambda: verify(backup, home, backup_root, keychain=False))
            (data / "Attachments/fixture.txt").write_bytes(saved)
            changed = copy.deepcopy(library)
            changed["sites"][0]["iconCheckedAt"] = 123
            (data / "library.json").write_bytes(json.dumps(changed).encode())
            rejects(lambda: verify(backup, home, backup_root, keychain=False))
            result = verify(backup, home, backup_root, keychain=False, allow_icon_cache_updates=True)
            ok(not result["dataVerification"]["originalFileHashesUnchanged"] and result["dataVerification"]["onlyNonCustomIconCacheChanged"])
            changed["sites"][0]["url"] = "https://changed.example.org"
            (data / "library.json").write_bytes(json.dumps(changed).encode())
            rejects(lambda: verify(backup, home, backup_root, keychain=False, allow_icon_cache_updates=True))
            (data / "library.json").write_bytes(encoded)
            os.link(data / "library.json", data / "hard-link")
            rejects(lambda: file_tree(data))
            (data / "hard-link").unlink()
            (data / "symlink").symlink_to(data / "library.json")
            rejects(lambda: file_tree(data))
            (data / "symlink").unlink()
            alias = root / "alias"
            alias.symlink_to(home)
            rejects(lambda: file_tree(alias / "Library/Application Support/MenDao"))
            rejects(lambda: file_tree(root / "missing"))
            (backup / "MenDao/Attachments/fixture.txt").write_bytes(b"corrupt backup")
            rejects(lambda: verify(backup, home, backup_root, keychain=False))
            (backup / "MenDao/Attachments/fixture.txt").write_bytes(saved)
        finally:
            sock.close()
        # Simulate application rollback/finalization with only fixture bundles.
        # Signature checks and process handling are stubs, not live acceptance.
        APPLICATIONS = root / "Applications"
        APPLICATIONS.mkdir()
        real_load, real_verify, real_snapshot = load_state, verify, snapshot
        load_state = lambda path, _root=None: real_load(path, backup_root)

        def fixture_verify(path, fixture_home=home, fixture_backup_root=backup_root,
                           allowed_preferences=(), keychain=False, allow_icon_cache_updates=False):
            assert fixture_home == home and fixture_backup_root == backup_root and not keychain
            return real_verify(path, home, backup_root, allowed_preferences,
                               keychain=False, allow_icon_cache_updates=allow_icon_cache_updates)

        verify = fixture_verify
        commands, stops = [], []
        run_checked = lambda arguments: commands.append(arguments)
        stop_owned_processes = lambda: stops.append(True)

        def fake_app(path, version):
            assert has_noindex_container(path.parent)
            private_write(path / "Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": APP_ID, "CFBundleExecutable": "MenDao",
                                                                       "CFBundleShortVersionString": version, "CFBundleVersion": version.replace(".", "")}))
            private_write(path / "Contents/MacOS/MenDao", b"non-executable fixture " + version.encode())

        def remove_fixture_app(path):
            app_info(path)
            assert has_noindex_container(path.parent)
            shutil.rmtree(path)

        def swap_fixture_version(path, version):
            info_path = path / "Contents/Info.plist"
            value = plistlib.loads(info_path.read_bytes())
            value.update(CFBundleShortVersionString=version, CFBundleVersion=version.replace(".", ""))
            info_path.write_bytes(plistlib.dumps(value))

        def upgrade_fixture(phase="installed", old_in_backup=True, current_version="1.14"):
            if (APPLICATIONS / "搞门户.app").exists():
                remove_fixture_app(APPLICATIONS / "搞门户.app")
            path = real_snapshot(home, backup_root, keychain=False)
            previous = path / "PreviousApplications"
            previous.mkdir()
            if old_in_backup:
                fake_app(previous / "搞门户.app", "1.13")
            if current_version is not None:
                fake_app(APPLICATIONS / "搞门户.app", current_version)
            value = load_state(path)
            value.update(phase=phase, oldApplications=["搞门户.app"], newVersion="1.14", newBuild="114")
            update_state(path, value)
            return path

        previous = backup / "PreviousApplications"
        previous.mkdir()
        fake_app(previous / "搞门户.app", "1.13")
        fake_app(APPLICATIONS / "搞门户.app", "1.14")
        state = load_state(backup)
        state.update(phase="installed", oldApplications=["搞门户.app"], newVersion="1.14", newBuild="114")
        update_state(backup, state)
        rollback(backup, no_open=True)
        ok(app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.13")
        failed = backup / load_state(backup)["failedApplicationPath"]
        ok(app_info(failed)["CFBundleShortVersionString"] == "1.14")
        ok(has_noindex_container(failed.parent))
        ok((data / "library.json").read_bytes() == encoded)
        rejects(lambda: rollback(backup, no_open=True))

        accepted = upgrade_fixture()
        original_program = application_record(accepted / "PreviousApplications/搞门户.app")
        finalize(accepted)
        accepted_state = load_state(accepted)
        ok(accepted_state["phase"] == "finalized")
        ok(accepted_state["rollbackApplications"] == {"搞门户.app": original_program})
        ok((accepted / "PreviousApplications/搞门户.app").is_dir() and (accepted / "MenDao/library.json").exists())
        ok(app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.14")
        ok(any(cmd[-1] == str(accepted / "PreviousApplications/搞门户.app") and cmd[:3] == ["/usr/bin/codesign", "--verify", "--strict"] for cmd in commands))

        old_app = accepted / "PreviousApplications/搞门户.app"
        held = accepted / "Held.noindex"
        held.mkdir()
        old_app.rename(held / "搞门户.app")
        stop_count = len(stops)
        rejects(lambda: rollback(accepted, no_open=True))
        ok(len(stops) == stop_count and app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.14")
        (held / "搞门户.app").rename(old_app)
        executable = old_app / "Contents/MacOS/MenDao"
        saved_executable = executable.read_bytes()
        executable.write_bytes(saved_executable + b"tampered")
        rejects(lambda: rollback(accepted, no_open=True))
        ok(len(stops) == stop_count)
        executable.write_bytes(saved_executable)
        swap_fixture_version(APPLICATIONS / "搞门户.app", "1.15")
        rejects(lambda: rollback(accepted, no_open=True))
        ok(len(stops) == stop_count and old_app.is_dir())
        swap_fixture_version(APPLICATIONS / "搞门户.app", "1.14")
        prior_runner = run_checked

        def reject_old_signature(arguments):
            if arguments[-1] == str(old_app):
                raise RuntimeError("fixture signature rejected")
            prior_runner(arguments)

        run_checked = reject_old_signature
        rejects(lambda: rollback(accepted, no_open=True))
        ok(len(stops) == stop_count)
        run_checked = prior_runner

        # The process-stop wait is an external interaction boundary: a user or a
        # separate installer may replace the canonical App while we wait.
        prior_stop = stop_owned_processes

        def replace_during_stop():
            prior_stop()
            remove_fixture_app(APPLICATIONS / "搞门户.app")
            fake_app(APPLICATIONS / "搞门户.app", "1.15")

        stop_owned_processes = replace_during_stop
        rejects(lambda: rollback(accepted, no_open=True))
        ok(app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.15"
           and not (accepted / "FailedApplication.noindex/搞门户.app").exists()
           and application_record(old_app) == original_program
           and load_state(accepted)["phase"] == "rollingBack"
           and (data / "library.json").read_bytes() == encoded)
        stop_owned_processes = prior_stop
        remove_fixture_app(APPLICATIONS / "搞门户.app")
        fake_app(APPLICATIONS / "搞门户.app", "1.14")
        rollback(accepted, no_open=True)
        ok(load_state(accepted)["phase"] == "rolledBack")
        ok(app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.13")
        ok(app_info(accepted / load_state(accepted)["failedApplicationPath"])["CFBundleShortVersionString"] == "1.14")
        ok((data / "library.json").read_bytes() == encoded)

        # Simulate a process dying at each App-rename boundary. The resumer is a
        # genuinely new Python process with fresh module globals, reading only
        # the durable transaction receipt and these isolated fixture bundles.
        class FixtureCrash(BaseException):
            pass

        fresh_process = r'''
import json
import os
from pathlib import Path
import runpy
import sys
module = runpy.run_path(sys.argv[1], run_name="gaomenhu_fresh_recovery_fixture")
scope = module["rollback"].__globals__
applications, backup_root, backup, fixture_root = map(Path, sys.argv[2:])
assert fixture_root.name == "Fixtures.noindex" and fixture_root.is_dir()
assert applications.is_relative_to(fixture_root) and backup.is_relative_to(fixture_root)
real_load = scope["load_state"]
scope["APPLICATIONS"] = applications
scope["load_state"] = lambda path: real_load(path, backup_root)
signatures, renames = [], []
def signature_stub(arguments):
    assert arguments[:3] == ["/usr/bin/codesign", "--verify", "--strict"] and len(arguments) == 4
    assert Path(arguments[-1]).is_relative_to(fixture_root)
    signatures.append(arguments[-1])
scope["run_checked"] = signature_stub
scope["stop_owned_processes"] = lambda: None
def forbidden_private_access(*args, **kwargs):
    raise AssertionError("fresh recovery process accessed private preferences, hosts, keychain, or snapshot")
for name in ("preferences", "native_hosts", "keychain_metadata", "snapshot"):
    scope[name] = forbidden_private_access
before = scope["load_state"](backup)
assert before["phase"] == "rollingBack" and before["rollbackTransaction"]["fromPhase"] == "finalized"
real_rename = os.rename
def fixture_rename(source, destination):
    assert Path(source).is_relative_to(fixture_root) and Path(destination).is_relative_to(fixture_root)
    renames.append([str(source), str(destination)])
    return real_rename(source, destination)
os.rename = fixture_rename
try:
    module["rollback"](backup, no_open=True)
finally:
    os.rename = real_rename
after = scope["load_state"](backup)
assert after["phase"] == "rolledBack" and signatures
print(json.dumps({"reloadedPhase": before["phase"], "finalPhase": after["phase"],
                  "appRenameCount": len(renames), "signatureChecks": len(signatures)}))
'''
        for point in ("afterCurrentRetired", "afterOldRestored"):
            interrupted = upgrade_fixture()
            finalize(interrupted)
            expected_old = load_state(interrupted)["rollbackApplications"]["搞门户.app"]

            def crash_at_boundary(name):
                if name == point:
                    raise FixtureCrash()

            try:
                rollback(interrupted, no_open=True, checkpoint=crash_at_boundary)
            except FixtureCrash:
                pass
            else:
                raise AssertionError("fixture did not interrupt the requested atomic point")
            pending = load_state(interrupted)
            ok(pending["phase"] == "rollingBack")
            ok(pending["rollbackTransaction"]["oldApplications"] == {"搞门户.app": expected_old})
            ok((interrupted / "FailedApplication.noindex/搞门户.app").is_dir())
            if point == "afterCurrentRetired":
                ok(not (APPLICATIONS / "搞门户.app").exists())
                ok((interrupted / "PreviousApplications/搞门户.app").is_dir())
            else:
                ok(application_record(APPLICATIONS / "搞门户.app") == expected_old)
                ok(not (interrupted / "PreviousApplications/搞门户.app").exists())
            child = subprocess.run([sys.executable, "-B", "-c", fresh_process, str(Path(__file__).resolve()),
                                    str(APPLICATIONS), str(backup_root), str(interrupted), str(root)],
                                   capture_output=True, text=True)
            require(child.returncode == 0, "隔离新进程回滚重入检查失败：" + child.stderr)
            resumed = json.loads(child.stdout)
            ok(resumed["reloadedPhase"] == "rollingBack" and resumed["finalPhase"] == "rolledBack")
            ok(resumed["appRenameCount"] == (1 if point == "afterCurrentRetired" else 0))
            ok(application_record(APPLICATIONS / "搞门户.app") == expected_old)
            ok(load_state(interrupted)["phase"] == "rolledBack")
            ok((data / "library.json").read_bytes() == encoded)

        # Receipts produced before rollback retention have no authenticated old
        # program after finalization. Do not invent one from the current App.
        historical = upgrade_fixture(old_in_backup=False)
        historical_state = load_state(historical)
        historical_state["phase"] = "finalized"
        update_state(historical, historical_state)
        rejects(lambda: rollback(historical, no_open=True))
        ok(app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.14")
        missing = upgrade_fixture(old_in_backup=False)
        rejects(lambda: rollback(missing, no_open=True))
        ok(app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.14")

        # Both interruption points around the old-program rename remain
        # recoverable, while a missing old backup plus an installed new App fails.
        before_rename = upgrade_fixture(phase="replacing", old_in_backup=False, current_version="1.13")
        rollback(before_rename, no_open=True)
        ok(load_state(before_rename)["phase"] == "rolledBack")
        ok(not (before_rename / "FailedApplication.noindex").exists())
        after_rename = upgrade_fixture(phase="replacing", current_version=None)
        rollback(after_rename, no_open=True)
        ok(app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.13")
        ambiguous = upgrade_fixture(phase="replacing", old_in_backup=False)
        rejects(lambda: rollback(ambiguous, no_open=True))
        ok(load_state(ambiguous)["phase"] == "replacing")

        # Test the actual installer orchestration with owned non-executable App
        # fixtures. No hdiutil, codesign, process signal, or open call is executed.
        # Existing independently prepared pending fixtures are closed for this
        # orchestration test only, without touching their data or program copies.
        for path in (missing, ambiguous):
            value = load_state(path)
            value["phase"] = "backedUp"
            update_state(path, value)
        ROOT = root / "Project"
        ROOT.mkdir()
        private_write(ROOT / "VERSION", b"1.14\n")
        package = ROOT / "Release/GaoMenHu-1.14.dmg"
        private_write(package, b"not a real disk image")
        private_write(package.with_suffix(".dmg.sha256"), (digest(package.read_bytes()) + "  " + package.name + "\n").encode())
        BACKUPS = backup_root
        snapshot = lambda: real_snapshot(home, backup_root, keychain=False)
        mount_paths, stage_paths = [], []
        fault = {"point": None, "fired": False}
        original_rename = os.rename

        def fixture_command(arguments):
            commands.append(arguments)
            if arguments[:2] == ["/usr/bin/hdiutil", "attach"]:
                mount = Path(arguments[arguments.index("-mountpoint") + 1])
                assert mount.is_dir() and mount.name.endswith(".noindex")
                mount_paths.append(mount)
                fake_app(mount / "搞门户.app", "1.14")
            elif arguments[0] == "/usr/bin/ditto":
                source, target = map(Path, arguments[1:])
                assert target.parent.is_dir() and target.parent.name.endswith(".noindex")
                assert has_noindex_container(source.parent) and has_noindex_container(target.parent)
                stage_paths.append(target.parent)
                if fault["point"] == "partial-ditto":
                    (target / "Contents").mkdir(parents=True)
                    fault["fired"] = True
                    raise RuntimeError("fixture partial copy")
                shutil.copytree(source, target)
            elif arguments[:2] == ["/usr/bin/hdiutil", "detach"]:
                mount = Path(arguments[-1])
                remove_fixture_app(mount / "搞门户.app")
            elif arguments[0] == "/usr/bin/codesign":
                if fault["point"] == "installed-signature" and not fault["fired"]:
                    target = Path(arguments[-1])
                    if target == APPLICATIONS / "搞门户.app" and app_info(target)["CFBundleShortVersionString"] == "1.14":
                        fault["fired"] = True
                        raise RuntimeError("fixture post-replace signature failure")
            else:
                raise AssertionError("unexpected external command in fixture")

        def fixture_rename(source, destination):
            if fault["point"] == "new-rename" and not fault["fired"] and Path(source).parent in stage_paths:
                fault["fired"] = True
                raise OSError("fixture interrupted new-program rename")
            return original_rename(source, destination)

        run_checked = fixture_command
        os.rename = fixture_rename
        try:
            for point in ("partial-ditto", "new-rename", "installed-signature", None):
                remove_fixture_app(APPLICATIONS / "搞门户.app")
                fake_app(APPLICATIONS / "搞门户.app", "1.13")
                fault.update(point=point, fired=False)
                old_backups = set(backup_root.iterdir())
                if point is not None:
                    rejects(lambda: install(no_open=True, home=home))
                    ok(fault["fired"])
                    ok(app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.13")
                else:
                    install(no_open=True, home=home)
                    ok(app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.14")
                new_backups = set(backup_root.iterdir()) - old_backups
                if point == "partial-ditto":
                    ok(not new_backups)
                else:
                    ok(len(new_backups) == 1)
                    latest = new_backups.pop()
                    ok(latest.name.endswith(".noindex"))
                    ok(load_state(latest)["phase"] == ("installed" if point is None else "rolledBack"))
                    ok((latest / "MenDao/library.json").read_bytes() == encoded)
                    if point is None:
                        finalize(latest)
                        ok((latest / "PreviousApplications/搞门户.app").is_dir())
                ok(all(not p.exists() for p in stage_paths + mount_paths))
                ok((data / "library.json").read_bytes() == encoded)
        finally:
            os.rename = original_rename
    print("Upgrade safety: " + str(checks) + " isolated checks passed; no real apps or private data changed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("backup", "verify", "install", "self-test"))
    parser.add_argument("--no-open", action="store_true")
    parser.add_argument("--finalize", type=Path)
    parser.add_argument("--rollback", type=Path)
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--allow-preference-key", action="append", default=[])
    parser.add_argument("--allow-icon-cache-updates", action="store_true")
    args = parser.parse_args()
    require(not (args.finalize and args.rollback), "不能同时验收和回滚。")
    if args.command == "self-test":
        self_test()
    elif args.command == "backup":
        require(not args.finalize and not args.rollback, "备份命令参数无效。")
        destination = snapshot()
        print("已完整备份并核验资料、设置、快照与助手绑定；未导出密码。")
        print("BACKUP=" + str(destination))
    elif args.command == "verify":
        require(args.backup is not None, "请指定 --backup。")
        state = verify(args.backup, allowed_preferences=args.allow_preference_key, allow_icon_cache_updates=args.allow_icon_cache_updates)
        print(json.dumps({"verified": True, "counts": state["counts"], "snapshots": state["snapshots"], "keychain": state["keychain"],
                          "dataVerification": state["dataVerification"]}, ensure_ascii=False))
    elif args.finalize:
        finalize(args.finalize, args.allow_preference_key, args.allow_icon_cache_updates)
        print("升级验收完成；旧程序已退役，完整资料与可核验的程序回滚备份保留在 .noindex 容器。")
    elif args.rollback:
        rollback(args.rollback, args.no_open)
        print("已恢复旧程序；当前资料与安全备份均保留。")
    else:
        install(args.no_open)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # OS/JSON exceptions can include private names or paths. Do not echo them.
        if isinstance(error, RuntimeError):
            print(str(error), file=sys.stderr)
        else:
            print("安全升级操作未完成（" + type(error).__name__ + "）；保留已有程序、资料与安全备份。", file=sys.stderr)
        sys.exit(1)
