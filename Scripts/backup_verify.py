#!/usr/bin/env python3
"""Verified private snapshots and reversible two-phase upgrades.

No password value is requested. Browser profiles are never traversed. Backups
live in the project's git-ignored 用户数据备份 directory, never in release assets.
"""
import argparse
import base64
import copy
import contextlib
import fcntl
import functools
import ctypes
import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
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
        require(isinstance(transaction, dict) and transaction.get("format") in (1, 2)
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


def accepted_account_additions(original, current, site_ids, allow_icon_cache_updates=False):
    """Recognize only explicit, append-only account additions on existing sites.

    This does not authorize new data on its own. Finalization also requires an
    independently verified snapshot of every current file and keychain reference.
    """
    first, second = json.loads(original), json.loads(current)
    old_counts, _ = validate_library(original)
    new_counts, _ = validate_library(current)
    selected = set(site_ids)
    require(selected and len(selected) == len(site_ids)
            and selected.issubset({site["id"] for site in first["sites"]}),
            "请明确指定原来已存在且实际新增账号的网站。")
    require(len(first["sites"]) == len(second["sites"]), "网站数量改变，不能按新增账号验收。")
    additions = 0
    for old, new in zip(first["sites"], second["sites"]):
        require(old["id"] == new["id"], "网站或顺序改变，不能按新增账号验收。")
        if old["id"] not in selected:
            continue
        previous = old["accounts"]
        current_accounts = new["accounts"]
        require(len(current_accounts) > len(previous) and current_accounts[:len(previous)] == previous,
                "仅允许在指定网站追加账号，原账号不得修改、删除或重排。")
        added = current_accounts[len(previous):]
        additions += len(added)
        old_default, new_default = old.get("defaultAccount"), new.get("defaultAccount")
        require((old_default is not None and new_default == old_default)
                or (old_default is None and new_default in [account["id"] for account in added]),
                "默认账号的改变不属于此次明确新增。")
        new["accounts"] = previous
        if "defaultAccount" in old:
            new["defaultAccount"] = old["defaultAccount"]
        else:
            new.pop("defaultAccount", None)
    same = (only_icon_cache_changed(json.dumps(first).encode(), json.dumps(second).encode())
            if allow_icon_cache_updates else first == second)
    require(same and additions > 0
            and new_counts == {**old_counts, "accounts": old_counts["accounts"] + additions},
            "存在新增账号以外的资料变更，保留备份并停止验收。")
    return additions


def verify(backup, home=Path.home(), backup_root=BACKUPS, allowed_preferences=(), keychain=True,
           allow_icon_cache_updates=False, _accepted_account_sites=(), _accepted_download_grant_id=None):
    state = load_state(backup, backup_root)
    saved, saved_dirs = file_tree(backup / "MenDao")
    require({name: digest(data) for name, data in saved.items()} == state["files"] and saved_dirs == state["directories"], "安全备份已损坏，已停止更新。")
    files, dirs = file_tree(home / "Library/Application Support/MenDao")
    changed = [name for name, value in state["files"].items() if name not in files or digest(files[name]) != value]
    library_changed = "library.json" in changed
    icon_only = (library_changed and "library.json" in files and
                 allow_icon_cache_updates and only_icon_cache_changed(saved["library.json"], files["library.json"]))
    added_accounts = 0
    if _accepted_account_sites:
        require(library_changed, "没有指定的新增账号变化，已停止验收。")
        added_accounts = accepted_account_additions(saved["library.json"], files["library.json"],
                                                    _accepted_account_sites, allow_icon_cache_updates)
    permitted = {"library.json"} if icon_only or added_accounts else set()
    download_acceptance = None
    if _accepted_download_grant_id is not None:
        names = {"DownloadCenter/downloads.json", "DownloadCenter/downloads.previous.json"}
        require(names.issubset(files) and names.issubset(saved)
                and bool(names.intersection(changed)), "下载原库、当前库或上一快照缺失，不能按目录重授权验收。")
        spec = importlib.util.spec_from_file_location("portal_download_acceptance", Path(__file__).resolve().with_name("download_acceptance.py"))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        download_acceptance = module.accepted_download_reauthorization(
            saved["DownloadCenter/downloads.json"], files["DownloadCenter/downloads.json"],
            files["DownloadCenter/downloads.previous.json"], _accepted_download_grant_id)
        permitted.update(names)
        require(set(saved) == set(files) and saved_dirs == dirs,
                "下载定向验收要求全部当前文件和目录清单保留，不接纳新任务、附件或缺失资料。")
    require(set(changed).issubset(permitted)
            and set(state["directories"]).issubset(dirs), "原资料/附件内容改变或缺失，保留备份并停止验收。")
    counts, account_ids = validate_library(files["library.json"])
    require(counts == {**state["counts"], "accounts": state["counts"]["accounts"] + added_accounts},
            "资料数量或引用发生变化，已停止验收。")
    if added_accounts:
        # Existing credentials remain checked against the original receipt;
        # all current references were separately checked by the fresh snapshot.
        old_counts, account_ids = validate_library(saved["library.json"])
        require(old_counts == state["counts"], "原资料数量与原备份收据不符。")
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
    if added_accounts:
        state["dataVerification"]["explicitlyAcceptedNewAccounts"] = added_accounts
    if download_acceptance is not None:
        state["dataVerification"]["explicitlyAcceptedDownloadReauthorization"] = download_acceptance
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


# Application originals have a separate, append-only identity/move journal.
# Data snapshots are never used to repair an unproven program identity.
APP_METADATA_FORMAT = 2
APP_XATTR_OPTIONS = 0x20  # Darwin XATTR_SHOWCOMPRESSION
APP_ACL_TYPE = 0x100     # ACL_TYPE_EXTENDED, a public Darwin ACL API
APP_RENAME_EXCL = 0x4
APP_META_LIMIT = 16 * 1024 * 1024
APP_PROVENANCE = base64.b64encode(b"com.apple.provenance").decode("ascii")
APP_LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


_PROGRAM_MAINTENANCE = None


@contextlib.contextmanager
def _program_maintenance_lock():
    global _PROGRAM_MAINTENANCE
    key = str(BACKUPS)
    if _PROGRAM_MAINTENANCE is not None:
        require(_PROGRAM_MAINTENANCE["path"] == key and _PROGRAM_MAINTENANCE["pid"] == os.getpid(),
                "不能跨恢复根或进程复用程序维护锁。")
        yield
        return
    directory(BACKUPS)
    BACKUPS.mkdir(mode=0o700, parents=True, exist_ok=True)
    attributes = BACKUPS.lstat()
    require(attributes.st_uid == os.getuid() and stat.S_IMODE(attributes.st_mode) == 0o700,
            "程序维护根的所有者或权限不符；没有自动改属性。")
    fd = os.open(BACKUPS / ".program-maintenance.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) == 0o600, "程序维护锁不是本人的安全普通文件。")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("已有本App程序维护进行中；没有抢锁或改动程序。")
        current = (BACKUPS / ".program-maintenance.lock").lstat()
        require((current.st_dev, current.st_ino) == (before.st_dev, before.st_ino), "程序维护锁被替换。")
        _PROGRAM_MAINTENANCE = {"path": key, "pid": os.getpid(), "fd": fd}
        try:
            yield
        finally:
            _PROGRAM_MAINTENANCE = None
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def _program_guard(function):
    @functools.wraps(function)
    def guarded(*args, **kwargs):
        with _program_maintenance_lock():
            return function(*args, **kwargs)
    return guarded


def _app_libc():
    require(sys.platform == "darwin", "完整App元数据核验仅支持macOS；没有降级为字节比较。")
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    ptr, size, ssize = ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ssize_t
    lib.flistxattr.argtypes = [ctypes.c_int, ptr, size, ctypes.c_int]
    lib.flistxattr.restype = ssize
    lib.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ptr, size, ctypes.c_uint32, ctypes.c_int]
    lib.fgetxattr.restype = ssize
    lib.filesec_init.argtypes = []
    lib.filesec_init.restype = ptr
    lib.filesec_free.argtypes = [ptr]
    lib.filesec_free.restype = None
    lib.fstatx_np.argtypes = [ctypes.c_int, ptr, ptr]
    lib.fstatx_np.restype = ctypes.c_int
    lib.filesec_query_property.argtypes = [ptr, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
    lib.filesec_query_property.restype = ctypes.c_int
    lib.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    lib.acl_get_fd_np.restype = ptr
    lib.acl_size.argtypes = [ptr]
    lib.acl_size.restype = ssize
    lib.acl_copy_ext.argtypes = [ptr, ptr, ssize]
    lib.acl_copy_ext.restype = ssize
    lib.acl_to_text.argtypes = [ptr, ctypes.POINTER(ssize)]
    lib.acl_to_text.restype = ptr
    lib.acl_free.argtypes = [ptr]
    lib.acl_free.restype = ctypes.c_int
    lib.renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    lib.renameatx_np.restype = ctypes.c_int
    return lib


def _app_b64(value):
    return base64.b64encode(value).decode("ascii")


def _app_json(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(",", ":")).encode()


def _app_dir_fd(path):
    path = Path(path)
    require(path.is_absolute() and all(x not in (".", "..", "") for x in path.parts[1:]), "App路径必须为明确的绝对物理路径。")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def _app_stat(value):
    return {"dev": value.st_dev, "ino": value.st_ino, "uid": value.st_uid,
            "gid": value.st_gid, "mode": value.st_mode, "flags": value.st_flags,
            "mtime_ns": value.st_mtime_ns, "size": value.st_size, "nlink": value.st_nlink}


def _app_xattrs(lib, fd):
    def names():
        count = lib.flistxattr(fd, None, 0, APP_XATTR_OPTIONS)
        require(0 <= count <= APP_META_LIMIT, "无法完整读取App扩展属性名称；未当作空值。")
        buf = ctypes.create_string_buffer(max(count, 1))
        actual = lib.flistxattr(fd, buf, count, APP_XATTR_OPTIONS)
        require(actual == count, "读取App扩展属性期间清单变化，已停止。")
        raw = buf.raw[:count]
        require(not raw or raw.endswith(b"\0"), "App扩展属性清单无效。")
        result = raw[:-1].split(b"\0") if raw else []
        require(all(result) and len(result) == len(set(result)) if result else True, "App扩展属性名称重复或无效。")
        return sorted(result)
    before = names()
    result, total = {}, 0
    for name in before:
        count = lib.fgetxattr(fd, name, None, 0, 0, APP_XATTR_OPTIONS)
        require(0 <= count <= APP_META_LIMIT, "App扩展属性不可读或超预算；没有忽略该属性。")
        total += count
        require(total <= 4 * APP_META_LIMIT, "App扩展属性总量超预算；没有截断。")
        buf = ctypes.create_string_buffer(max(count, 1))
        actual = lib.fgetxattr(fd, name, buf, count, 0, APP_XATTR_OPTIONS)
        require(actual == count, "读取App扩展属性期间值变化，已停止。")
        result[_app_b64(name)] = _app_b64(buf.raw[:count])
    require(names() == before, "读取App扩展属性期间名称变化，已停止。")
    return result


def _app_acl(lib, fd):
    # acl_get_fd_np may return NULL/ENOENT for an existing object without an
    # extended ACL. Never infer absence from errno: obtain an explicit positive
    # filesec property-absence result from fstatx_np on the same held descriptor.
    security = lib.filesec_init()
    require(bool(security), "无法初始化完整ACL读取。")
    try:
        native_stat = (ctypes.c_uint64 * 128)()  # aligned storage, larger than Darwin stat ABI
        require(lib.fstatx_np(fd, native_stat, security) == 0, "无法完整读取App文件安全信息。")
        present = ctypes.c_int(-1)
        require(lib.filesec_query_property(security, 5, ctypes.byref(present)) == 0
                and present.value >= 0, "无法证明App ACL是否存在。")  # FILESEC_ACL; nonzero is present
        if present.value == 0:
            return {"present": False, "external_b64": None, "text_b64": None,
                    "absenceProof": "fstatx_np/filesec_query_property(FILESEC_ACL)"}
    finally:
        lib.filesec_free(security)
    acl = lib.acl_get_fd_np(fd, APP_ACL_TYPE)
    require(bool(acl), "无法读取App完整ACL；没有把错误当作无ACL。")
    text = None
    try:
        count = lib.acl_size(acl)
        require(0 <= count <= APP_META_LIMIT, "App ACL大小无效。")
        buf = ctypes.create_string_buffer(max(count, 1))
        actual = lib.acl_copy_ext(buf, acl, count)
        require(0 <= actual <= count, "无法读取App ACL外部表示。")
        length = ctypes.c_ssize_t()
        text = lib.acl_to_text(acl, ctypes.byref(length))
        require(bool(text) and 0 <= length.value <= APP_META_LIMIT, "无法读取App ACL文本。")
        return {"present": True, "external_b64": _app_b64(buf.raw[:actual]),
                "text_b64": _app_b64(ctypes.string_at(text, length.value))}
    finally:
        if text:
            lib.acl_free(text)
        lib.acl_free(acl)


def _application_tree(path):
    path = Path(path)
    parent = _app_dir_fd(path.parent)
    root_fd = -1
    lib = _app_libc()
    nodes, files, dirs, total = {}, {}, [], 0
    info_bytes = None
    try:
        root_fd = os.open(path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        root_identity = os.fstat(root_fd)
        def visit(fd, relative):
            nonlocal total, info_bytes
            require(len(nodes) < 65536, "App库存超出安全预算；没有截断。")
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) or stat.S_ISDIR(before.st_mode), "App含未知文件类型，已停止。")
            if stat.S_ISREG(before.st_mode):
                require(before.st_nlink == 1 and 0 <= before.st_size <= MAX_FILE_BYTES, "App文件为硬链接或超预算。")
            attrs = _app_xattrs(lib, fd)
            acl = _app_acl(lib, fd)
            node = {**_app_stat(before), "xattrs_b64": attrs, "acl": acl}
            if stat.S_ISDIR(before.st_mode):
                names = sorted(os.listdir(fd))
                for name in names:
                    require(name not in (".", "..") and "/" not in name, "App文件名无效。")
                    child_at = os.stat(name, dir_fd=fd, follow_symlinks=False)
                    require(stat.S_ISREG(child_at.st_mode) or stat.S_ISDIR(child_at.st_mode), "App含链接或特殊文件，已停止。")
                    child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                    try:
                        opened = os.fstat(child)
                        require((opened.st_dev, opened.st_ino) == (child_at.st_dev, child_at.st_ino), "App节点在打开时被替换。")
                        key = name if relative == "." else relative + "/" + name
                        if stat.S_ISDIR(opened.st_mode):
                            dirs.append(key)
                        visit(child, key)
                        current = os.stat(name, dir_fd=fd, follow_symlinks=False)
                        require((current.st_dev, current.st_ino) == (opened.st_dev, opened.st_ino), "App节点路径在读取期间被替换。")
                    finally:
                        os.close(child)
                require(sorted(os.listdir(fd)) == names, "App目录在读取期间改变。")
            else:
                sha, count, saved = hashlib.sha256(), 0, []
                while True:
                    chunk = os.read(fd, 1024 * 1024)
                    if not chunk:
                        break
                    count += len(chunk)
                    total += len(chunk)
                    require(count <= before.st_size and total <= MAX_TOTAL_BYTES, "App内容超出安全预算。")
                    sha.update(chunk)
                    if relative == "Contents/Info.plist":
                        require(count <= 2 * 1024 * 1024, "App Info超预算。")
                        saved.append(chunk)
                require(count == before.st_size, "App内容在读取期间改变。")
                files[relative] = sha.hexdigest()
                if relative == "Contents/Info.plist":
                    info_bytes = b"".join(saved)
            after = os.fstat(fd)
            require(_app_stat(before) == _app_stat(after) and before.st_ctime_ns == after.st_ctime_ns
                    and _app_xattrs(lib, fd) == attrs and _app_acl(lib, fd) == acl,
                    "App身份、内容、权限、ACL或扩展属性在采样期间变化。")
            nodes[relative] = node
        visit(root_fd, ".")
        current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        require((current.st_dev, current.st_ino) == (root_identity.st_dev, root_identity.st_ino), "App根路径被替换。")
        reopened = _app_dir_fd(path.parent)
        try:
            require((os.fstat(reopened).st_dev, os.fstat(reopened).st_ino) == (os.fstat(parent).st_dev, os.fstat(parent).st_ino), "App父路径被替换。")
        finally:
            os.close(reopened)
        info = plistlib.loads(info_bytes or b"")
        require(info.get("CFBundleIdentifier") == APP_ID and info.get("CFBundleExecutable") == "MenDao"
                and isinstance(info.get("CFBundleShortVersionString"), str) and isinstance(info.get("CFBundleVersion"), str), "App标识或版本不符。")
        return {"recordFormat": APP_METADATA_FORMAT, "version": info["CFBundleShortVersionString"],
                "build": info["CFBundleVersion"], "files": files, "directories": sorted(dirs), "metadataTree": nodes}
    finally:
        if root_fd >= 0:
            os.close(root_fd)
        os.close(parent)


def application_record(path):
    before = _application_tree(path)
    run_checked(["/usr/bin/codesign", "--verify", "--strict", str(path)])
    require(_application_tree(path) == before, "签名核验期间App原件或元数据变化，已停止。")
    return before


def _application_move_delta(before, after, native_observed):
    require(before.get("recordFormat") == APP_METADATA_FORMAT and after.get("recordFormat") == APP_METADATA_FORMAT,
            "旧字节收据没有完整原件身份，保留程序并停止；没有静默升级历史收据。")
    if before == after:
        return None
    require(native_observed, "搬移后记录未封存且元数据有差异；保留现场，须维护核验。")
    expected = copy.deepcopy(before)
    first = expected["metadataTree"]["."]["xattrs_b64"]
    second = after["metadataTree"]["."]["xattrs_b64"]
    old, new = first.get(APP_PROVENANCE), second.get(APP_PROVENANCE)
    require(old != new, "App搬移出现provenance以外差异，保留原件停止。")
    if APP_PROVENANCE in second:
        first[APP_PROVENANCE] = new
    else:
        first.pop(APP_PROVENANCE, None)
    require(expected == after, "App搬移出现身份、内容、权限、ACL或其他属性差异，已停止。")
    return {"name": "com.apple.provenance", "before_b64": old, "after_b64": new,
            "observedOnlyAcrossThisNativeRename": True}


def _application_allowed_paths(backup, genesis, key):
    if key.startswith("old:"):
        name = key[4:]
        require(name in APP_NAMES, "程序身份名称不属于本App。")
        return {str(APPLICATIONS / name), str(backup / "PreviousApplications" / name)}
    require(key == "new", "程序身份键无效。")
    initial = Path(genesis["objects"]["new"]["path"])
    require(initial.name == "搞门户.app" and initial.parent.parent == APPLICATIONS
            and initial.parent.name.startswith(".GaoMenHu-install-") and initial.parent.name.endswith(".noindex"), "新版暂存指针无效。")
    return {str(initial), str(APPLICATIONS / "搞门户.app"), str(backup / "FailedApplication.noindex/搞门户.app")}


def _app_macl_module():
    spec = importlib.util.spec_from_file_location("portal_app_macl_observation", Path(__file__).resolve().with_name("app_macl_observation.py"))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def _observation_bytes(value, maximum):
    require(isinstance(value, str) and len(value) <= ((maximum + 2) // 3) * 4, "观察事件编码或预算无效。")
    try:
        raw = base64.b64decode(value.encode("ascii"), validate=True)
    except (ValueError, UnicodeError):
        raise RuntimeError("观察事件编码不完整。") from None
    require(0 < len(raw) <= maximum and base64.b64encode(raw).decode("ascii") == value, "观察事件编码不规范。")
    return raw


def _bind_app_macl_authority(authority, backup, before_state, before_object, anchor, head, count):
    require(authority["appID"] == APP_ID and authority["object"] == "new"
            and authority["formalPath"] == str(APPLICATIONS / "搞门户.app") == before_object["path"]
            and authority["upgradeBackup"] == str(backup)
            and authority["version"] == before_state.get("newVersion") == before_object["record"]["version"] == "1.17"
            and authority["build"] == before_state.get("newBuild") == before_object["record"]["build"] == "117"
            and before_state.get("appID") == APP_ID and before_state.get("phase") == "installed",
            "观察只适用于本轮已安装新版正式原件，未放宽其他对象。")
    require(before_state.get("applicationSafety") == {"format": 1, "directory": "ApplicationSafety",
            "anchorSHA256": anchor, "headSHA256": head, "count": count}
            and type(before_state["applicationSafety"]["count"]) is int
            and authority["applicationSafetyAnchorSHA256"] == anchor
            and authority["applicationSafetyHeadSHA256"] == head,
            "观察未绑定原程序链的精确锚点、头或数量。")


def _replay_app_macl_observation(event, backup, genesis, objects, hashes, number):
    require(set(event) == {"format", "previous", "at", "kind", "object", "path", "authorityBase64",
                           "authoritySHA256", "beforeStateBase64", "after"}
            and event["object"] == "new" and event["path"] == objects["new"]["path"], "观察事件对象或字段无效。")
    module = _app_macl_module()
    raw = _observation_bytes(event["authorityBase64"], module.MAX_AUTHORITY_BYTES)
    authority = module.parse_authority(raw, event["authoritySHA256"])
    state_raw = _observation_bytes(event["beforeStateBase64"], 16 * 1024 * 1024)
    require(digest(state_raw) == authority["upgradeStateSHA256"], "观察前原升级state摘要不符。")
    before_state = module._json(state_raw)
    names = before_state.get("oldApplications") if isinstance(before_state, dict) else None
    require(isinstance(names, list) and names and len(names) == len(set(names)) and all(name in APP_NAMES for name in names)
            and {"old:" + name for name in before_state["oldApplications"]} | {"new"} == set(genesis["objects"]),
            "观察前原件集合不符。")
    _bind_app_macl_authority(authority, backup, before_state, objects["new"], hashes[0], hashes[number - 1], number)
    module.validate_transition(objects["new"]["record"], event["after"], authority)
    objects["new"] = {"path": event["path"], "record": event["after"]}


def application_authority(backup):
    """Replay immutable exclusive records; a stale state head may only be a valid prefix."""
    backup = Path(backup)
    state = load_state(backup)
    pointer = state.get("applicationSafety")
    require(isinstance(pointer, dict) and pointer.get("format") == 1
            and pointer.get("directory") == "ApplicationSafety", "此备份缺少完整程序身份链，保留原件；不能凭旧字节收据搬移。")
    folder = backup / "ApplicationSafety"
    directory(folder)
    attributes = folder.lstat()
    require(attributes.st_uid == os.getuid() and stat.S_IMODE(attributes.st_mode) == 0o700,
            "程序身份链目录所有者或权限改变。")
    backup_attributes = backup.lstat()
    require(backup_attributes.st_uid == os.getuid() and stat.S_IMODE(backup_attributes.st_mode) == 0o700,
            "程序恢复容器所有者或权限改变。")
    events, hashes = [], []
    previous = None
    paths = sorted(folder.iterdir())
    require(len(paths) <= 128, "程序身份链数量超出安全预算。")
    for number, path in enumerate(paths):
        attributes = path.lstat()
        require(stat.S_ISREG(attributes.st_mode) and attributes.st_uid == os.getuid()
                and stat.S_IMODE(attributes.st_mode) == 0o600 and attributes.st_size <= 128 * 1024 * 1024,
                "程序身份链文件所有者、权限、类型或预算不符。")
        raw = regular_bytes(path)
        sha = digest(raw)
        require(path.name == ("%06d-" % number) + sha + ".json", "程序身份链文件名或摘要改变。")
        event = json.loads(raw)
        require(event.get("format") == 1 and event.get("previous") == previous, "程序身份链断裂。")
        events.append(event); hashes.append(sha); previous = sha
    require(events and hashes[0] == pointer.get("anchorSHA256"), "程序身份链锚点不符。")
    count = pointer.get("count")
    require(type(count) is int and 1 <= count <= len(events) and hashes[count - 1] == pointer.get("headSHA256"), "程序身份链指针不符。")
    genesis = events[0]
    require(genesis.get("kind") == "bind" and genesis.get("backup") == str(backup)
            and genesis.get("appID") == APP_ID and set(genesis.get("objects", {})) == {"old:" + n for n in state["oldApplications"]} | {"new"}, "程序初始恢复指针无效。")
    objects = copy.deepcopy(genesis["objects"])
    for key, item in objects.items():
        require(item["path"] in _application_allowed_paths(backup, genesis, key)
                and item["record"].get("recordFormat") == APP_METADATA_FORMAT, "程序原件身份不完整。")
    pending = None
    observation_seen = False
    for number, event in enumerate(events[1:], 1):
        kind = event.get("kind")
        if kind == "move-intent":
            key = event.get("object")
            require(pending is None and key in objects and event.get("from") == objects[key]["path"]
                    and event.get("before") == objects[key]["record"]
                    and event.get("to") in _application_allowed_paths(backup, genesis, key)
                    and event["to"] != event["from"] and isinstance(event.get("moveID"), str), "程序搬移意图不符。")
            pending = event
        elif kind in ("move-complete", "move-cancelled"):
            require(pending is not None and event.get("moveID") == pending["moveID"], "程序搬移完成记录不匹配。")
            if kind == "move-complete":
                delta = _application_move_delta(pending["before"], event["after"], event.get("nativeRenameObserved") is True)
                require(delta == event.get("provenanceDelta"), "程序provenance差异记录不符。")
                objects[pending["object"]] = {"path": pending["to"], "record": event["after"]}
            else:
                require(event.get("record") == pending["before"], "程序搬移取消记录不符。")
            pending = None
        elif kind == "app-root-macl-observed":
            require(pending is None and not observation_seen, "不能在搬移中或重复加入新版根MACL观察。")
            _replay_app_macl_observation(event, backup, genesis, objects, hashes, number)
            observation_seen = True
        else:
            raise RuntimeError("程序身份链阶段未知；没有跳过记录。")
    return {"state": state, "events": events, "hashes": hashes, "genesis": genesis,
            "objects": objects, "pending": pending}


def _append_application_event(backup, event, checkpoint=None):
    chain = application_authority(backup)
    value = {"format": 1, "previous": chain["hashes"][-1], "at": datetime.datetime.now(datetime.timezone.utc).isoformat(), **event}
    raw = _app_json(value); sha = digest(raw)
    private_write(backup / "ApplicationSafety" / (("%06d-" % len(chain["events"])) + sha + ".json"), raw)
    sync_directory(backup / "ApplicationSafety")
    if checkpoint:
        checkpoint("afterMoveReceipt")
    state = load_state(backup)
    state["applicationSafety"] = {**state["applicationSafety"], "count": len(chain["events"]) + 1, "headSHA256": sha}
    update_state(backup, state)


@_program_guard
def observe_application_macl(backup, authority_path, authority_sha256, current_snapshot, checkpoint=None):
    """Append only an explicitly approved exact observation, never an xattr write."""
    backup, authority_path = Path(backup), Path(authority_path)
    directory(authority_path.parent)
    attributes = authority_path.lstat()
    require(has_noindex_container(authority_path.parent) and stat.S_ISREG(attributes.st_mode)
            and attributes.st_uid == os.getuid() and stat.S_IMODE(attributes.st_mode) == 0o600
            and attributes.st_nlink == 1, "明确观察依据必须在私有不索引位置且完整可读。")
    raw_authority = regular_bytes(authority_path)
    module = _app_macl_module()
    authority = module.parse_authority(raw_authority, authority_sha256)
    require(isinstance(current_snapshot, dict)
            and current_snapshot.get("path") == authority["currentDataBackup"]
            and current_snapshot.get("stateSHA256") == authority["currentDataBackupStateSHA256"],
            "观察未绑定本轮独立完整当前备份。")
    state_raw = regular_bytes(backup / "state.json")
    chain = application_authority(backup)
    require(chain["pending"] is None and chain["state"]["phase"] == "installed", "搬移中或非待验收阶段不能追加观察。")
    require(authority["upgradeBackup"] == str(backup) and authority["formalPath"] == str(APPLICATIONS / "搞门户.app")
            == chain["objects"]["new"]["path"], "观察的新原件不在本轮正式路径。")
    observed = [(index, event) for index, event in enumerate(chain["events"])
                if event["kind"] == "app-root-macl-observed"]
    if observed:
        index, event = observed[0]
        require(len(observed) == 1 and index == len(chain["events"]) - 1
                and event["authoritySHA256"] == authority_sha256
                and _observation_bytes(event["authorityBase64"], module.MAX_AUTHORITY_BYTES) == raw_authority,
                "观察之后已有其他事件或不是同一明确事实，未重复追加或重认领。")
        before_raw = _observation_bytes(event["beforeStateBase64"], 16 * 1024 * 1024)
        before = module._json(before_raw)
        def invariant_state(value):
            return _app_json({key: item for key, item in value.items()
                              if key not in ("applicationSafety", "applicationRegistration")})
        require(invariant_state(chain["state"]) == invariant_state(before), "观察后的原升级依据改变，未重baseline。")
        for item in chain["objects"].values():
            require(_app_json(application_record(Path(item["path"]))) == _app_json(item["record"]),
                    "已有观察不能掩盖后续程序原件漂移。")
        require(regular_bytes(backup / "state.json") == state_raw
                and regular_bytes(authority_path) == raw_authority, "复核期间原状态或观察依据改变。")
        desired = {"format": 1, "directory": "ApplicationSafety", "anchorSHA256": chain["hashes"][0],
                   "headSHA256": chain["hashes"][-1], "count": len(chain["events"])}
        if chain["state"]["applicationSafety"] != desired:
            # A crash after the immutable event but before its mutable pointer
            # permits only this exact old pointer/raw state to advance once.
            require(state_raw == before_raw and chain["state"]["applicationSafety"] == before["applicationSafety"],
                    "中断观察的原指针不匹配，未修补未知状态。")
            repaired = chain["state"]; repaired["applicationSafety"] = desired
            update_state(backup, repaired)
        return {"approvalSHA256": authority_sha256, "eventSHA256": chain["hashes"][-1],
                "applicationSafety": desired, "idempotent": True}
    require(digest(state_raw) == authority["upgradeStateSHA256"]
            and chain["state"]["applicationSafety"]["count"] == len(chain["events"])
            and chain["state"]["applicationSafety"]["headSHA256"] == chain["hashes"][-1],
            "观察前原状态摘要或程序链头改变，未接纳未知漂移。")
    _bind_app_macl_authority(authority, backup, chain["state"], chain["objects"]["new"],
                             chain["hashes"][0], chain["hashes"][-1], len(chain["events"]))
    after = None
    for key, item in chain["objects"].items():
        actual = application_record(Path(item["path"]))
        if key == "new":
            module.validate_transition(item["record"], actual, authority)
            after = actual
        else:
            require(_app_json(actual) == _app_json(item["record"]), "旧原件有漂移，观察不能放宽旧程序身份。")
    # Independent second sampling, with signatures, before the sole append.
    for key, item in chain["objects"].items():
        expected = after if key == "new" else item["record"]
        require(_app_json(application_record(Path(item["path"]))) == _app_json(expected), "追加前程序原件再次变化。")
    require(regular_bytes(backup / "state.json") == state_raw
            and regular_bytes(authority_path) == raw_authority
            and _app_json(application_authority(backup)) == _app_json(chain), "追加前原状态、事实或指针改变。")
    event = {"kind": "app-root-macl-observed", "object": "new", "path": authority["formalPath"],
             "authorityBase64": base64.b64encode(raw_authority).decode("ascii"), "authoritySHA256": authority_sha256,
             "beforeStateBase64": base64.b64encode(state_raw).decode("ascii"), "after": after}
    _append_application_event(backup, event, checkpoint)
    committed = application_authority(backup)
    return {"approvalSHA256": authority_sha256, "eventSHA256": committed["hashes"][-1],
            "applicationSafety": committed["state"]["applicationSafety"], "idempotent": False}


@_program_guard
def bind_application_safety(backup, old_paths, staged):
    state = load_state(backup)
    require("applicationSafety" not in state and set(old_paths) == set(state["oldApplications"])
            and has_noindex_container(backup), "不能重新绑定或覆盖程序原件依据。")
    objects = {}
    for name, path in old_paths.items():
        require(Path(path) == APPLICATIONS / name, "旧原件必须在正式安装路径绑定。")
        objects["old:" + name] = {"path": str(path), "record": application_record(path)}
    staged = Path(staged)
    objects["new"] = {"path": str(staged), "record": application_record(staged)}
    genesis = {"format": 1, "previous": None, "kind": "bind", "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "backup": str(backup), "appID": APP_ID, "objects": objects}
    for key, item in objects.items():
        require(item["path"] in _application_allowed_paths(backup, genesis, key), "程序初始路径不属于本次安装。")
    folder = backup / "ApplicationSafety"
    require(not folder.exists() and not folder.is_symlink(), "程序身份链目录已存在，未覆盖。")
    folder.mkdir(mode=0o700)
    raw = _app_json(genesis); sha = digest(raw)
    private_write(folder / ("000000-" + sha + ".json"), raw); sync_directory(folder)
    state["applicationSafety"] = {"format": 1, "directory": "ApplicationSafety", "anchorSHA256": sha, "headSHA256": sha, "count": 1}
    update_state(backup, state)


@_program_guard
def recover_application_move(backup):
    chain = application_authority(backup)
    pending = chain["pending"]
    if pending is None:
        return chain
    source, target = Path(pending["from"]), Path(pending["to"])
    for path, field in ((source.parent, "sourceParent"), (target.parent, "targetParent")):
        parent_fd = _app_dir_fd(path)
        try:
            value = os.fstat(parent_fd)
            require(pending.get(field) == {"dev": value.st_dev, "ino": value.st_ino},
                    "中断后程序父路径身份改变；未取消、完成或覆盖搬移。")
        finally:
            os.close(parent_fd)
    source_exists, target_exists = os.path.lexists(source), os.path.lexists(target)
    require(source_exists != target_exists, "程序搬移两侧占用或均缺失；未覆盖、删除或猜测原件。")
    if source_exists:
        require(application_record(source) == pending["before"], "尚未搬移的程序身份已改变。")
        _append_application_event(backup, {"kind": "move-cancelled", "moveID": pending["moveID"], "record": pending["before"]})
    else:
        after = application_record(target)
        # A crash before sealing after cannot prove which provenance value the
        # native call produced. Only an exact, no-delta recovery is automatic.
        delta = _application_move_delta(pending["before"], after, False)
        _append_application_event(backup, {"kind": "move-complete", "moveID": pending["moveID"], "after": after,
                                          "nativeRenameObserved": False, "provenanceDelta": delta})
    return application_authority(backup)


@_program_guard
def move_application_original(backup, key, target, checkpoint=None):
    chain = recover_application_move(backup)
    require(key in chain["objects"], "未登记的程序不能搬移。")
    item = chain["objects"][key]; source, target = Path(item["path"]), Path(target)
    require(str(target) in _application_allowed_paths(backup, chain["genesis"], key) and target != source,
            "程序恢复目的地不在精确指针中。")
    require(application_record(source) == item["record"], "程序身份、权限或属性与不可变链不符。")
    require(not os.path.lexists(target), "程序恢复目的地已占用；未覆盖任何对象。")
    source_fd = _app_dir_fd(source.parent); target_fd = -1
    try:
        target_fd = _app_dir_fd(target.parent)
        source_parent, target_parent = os.fstat(source_fd), os.fstat(target_fd)
        require(source_parent.st_dev == target_parent.st_dev == item["record"]["metadataTree"]["."]["dev"], "原件必须同卷搬移；没有复制删除回退。")
        at = os.stat(source.name, dir_fd=source_fd, follow_symlinks=False)
        require((at.st_dev, at.st_ino) == (item["record"]["metadataTree"]["."]["dev"], item["record"]["metadataTree"]["."]["ino"]), "原件路径在搬移前被替换。")
        move_id = str(uuid.uuid4())
        _append_application_event(backup, {"kind": "move-intent", "moveID": move_id, "object": key,
                                          "from": str(source), "to": str(target), "before": item["record"],
                                          "sourceParent": {"dev": source_parent.st_dev, "ino": source_parent.st_ino},
                                          "targetParent": {"dev": target_parent.st_dev, "ino": target_parent.st_ino}})
        if checkpoint:
            checkpoint("afterMoveIntent")
        # No fallback to os.rename: destination creation must never be overwritten.
        lib = _app_libc()
        result = lib.renameatx_np(source_fd, os.fsencode(source.name), target_fd, os.fsencode(target.name), APP_RENAME_EXCL)
        require(result == 0, "排他原件搬移失败；没有覆盖或删除目标，也没有降级复制。")
        os.fsync(source_fd); os.fsync(target_fd)
        if checkpoint:
            checkpoint("afterNativeRename")
        after = application_record(target)
        source_parent_after, target_parent_after = _app_dir_fd(source.parent), _app_dir_fd(target.parent)
        try:
            require((os.fstat(source_parent_after).st_dev, os.fstat(source_parent_after).st_ino) == (source_parent.st_dev, source_parent.st_ino)
                    and (os.fstat(target_parent_after).st_dev, os.fstat(target_parent_after).st_ino) == (target_parent.st_dev, target_parent.st_ino), "搬移期间父路径改变，保留现场。")
        finally:
            os.close(source_parent_after); os.close(target_parent_after)
        require(not os.path.lexists(source), "搬移后来源路径被重新占用；保留两侧停止。")
        delta = _application_move_delta(item["record"], after, True)
        _append_application_event(backup, {"kind": "move-complete", "moveID": move_id, "after": after,
                                          "nativeRenameObserved": True, "provenanceDelta": delta}, checkpoint)
        if checkpoint:
            checkpoint("afterMoveCommitted")
        return after
    finally:
        if target_fd >= 0:
            os.close(target_fd)
        os.close(source_fd)


def verify_application_objects(backup):
    chain = recover_application_move(backup)
    for key, item in chain["objects"].items():
        if key == "new" and Path(item["path"]) == Path(chain["genesis"]["objects"]["new"]["path"]):
            continue  # Disposable never-installed staging copy, not an old original.
        require(application_record(Path(item["path"])) == item["record"], "程序恢复指针的完整原件身份不匹配。")
    return chain


def parse_application_ls_dump(text):
    """Read complete scoped bundle records, never infer ownership from a name."""
    require(isinstance(text, str) and text.strip() and "\0" not in text
            and len(text.encode("utf-8")) <= 128 * 1024 * 1024, "LaunchServices查询为空或格式无效。")
    rows = []
    names = {Path(name).stem for name in APP_NAMES}
    for block in re.split(r"\n-+\r?\n", "\n" + text):
        starts = re.findall(r"^bundle id:[^\r\n]*$", block, re.M)
        if not starts:
            continue
        require(len(starts) == 1, "LaunchServices bundle记录边界不完整。")
        def fields(key):
            return re.findall(r"^" + re.escape(key) + r":[ \t]*([^\r\n]*)$", block, re.M)
        identifiers, raw_paths = fields("identifier"), fields("path")
        paths = [re.sub(r" \(0x[0-9a-fA-F]+\)$", "", value) for value in raw_paths]
        labels = [re.sub(r" \(0x[0-9a-fA-F]+\)$", "", value) for value in fields("bundle id")]
        relevant = (APP_ID in identifiers + fields("codeInfoID") or any(Path(value).name in APP_NAMES for value in paths)
                    or any(value in names for value in fields("name") + fields("displayName") + labels))
        if not relevant:
            continue
        required = {key: fields(key) for key in ("identifier", "path", "codeInfoID", "executable", "class", "inode", "exec inode")}
        require(all(len(value) == 1 and value[0] for value in required.values()), "本App的LaunchServices身份字段缺失或重复。")
        raw = paths[0]
        require(required["identifier"][0] == APP_ID and required["codeInfoID"][0] == APP_ID
                and required["executable"][0] == "Contents/MacOS/MenDao"
                and re.fullmatch(r"kLSBundleClassApplication \(0x[0-9a-fA-F]+\)", required["class"][0])
                and raw.startswith("/") and raw == str(Path(raw)) and Path(raw).name in APP_NAMES
                and not any(part in (".", "..") for part in raw.split("/"))
                and required["inode"][0].isdigit() and required["exec inode"][0].isdigit(),
                "同名或同标识LaunchServices记录不能证明属于本App，未改登记。")
        rows.append({"identifier": APP_ID, "path": raw, "codeInfoID": APP_ID,
                     "executable": required["executable"][0], "class": required["class"][0],
                     "inode": int(required["inode"][0]), "executableInode": int(required["exec inode"][0])})
    return rows


def query_application_registration():
    # A failed/empty user-session query must never mean "nothing registered".
    result = subprocess.run([APP_LSREGISTER, "-dump"], check=True, capture_output=True,
                            text=True, encoding="utf-8", errors="strict")
    return parse_application_ls_dump(result.stdout)


def refresh_application_registration(backup):
    chain = verify_application_objects(backup)
    frozen = _app_json(chain)
    paths = {x["path"] for x in chain["genesis"]["objects"].values()}
    seen = {}
    def remember(raw, record):
        seen.setdefault(raw, []).append(record)
    for item in list(chain["genesis"]["objects"].values()) + list(chain["objects"].values()):
        remember(item["path"], item["record"])
    for event in chain["events"]:
        if event["kind"] == "move-intent":
            paths.update((event["from"], event["to"]))
            remember(event["from"], event["before"])
    formal = {x["path"]: x["record"] for x in chain["objects"].values()
              if Path(x["path"]).parent == APPLICATIONS and Path(x["path"]).name in APP_NAMES}
    require(len(formal) == 1, "没有唯一且已封存的正式程序入口，未改登记。")
    physical = {}
    for raw in paths:
        path = Path(raw)
        if not (path.parent == APPLICATIONS and path.name in APP_NAMES):
            historical_stage = raw == chain["genesis"]["objects"]["new"]["path"]
            require(has_noindex_container(path.parent) or (historical_stage and not os.path.lexists(path.parent)),
                    "只允许注销精确的本App不索引暂存路径。")
        physical[raw] = application_record(path) if os.path.lexists(path) else None
        require(physical[raw] is None or physical[raw] in seen.get(raw, []), "历史程序地址已由未知对象占用，未改登记。")
    def unchanged():
        # Check authority before recovery-capable verification, so a changed
        # pointer cannot cause a new move/recovery as part of a registration.
        require(_app_json(application_authority(backup)) == frozen, "登记期间程序恢复指针或收据改变，停止登记。")
        require(_app_json(verify_application_objects(backup)) == frozen, "登记期间程序原件链改变。")
        for raw, record in physical.items():
            current = application_record(Path(raw)) if os.path.lexists(raw) else None
            require(current == record, "登记期间程序路径或完整元数据改变，停止登记。")
    def records():
        rows = query_application_registration()
        unchanged()
        for row in rows:
            raw = row["path"]
            require(raw in paths, "发现本App未知登记路径，未注销未知对象。")
            require(any(record["metadataTree"]["."]["ino"] == row["inode"]
                        and record["metadataTree"]["Contents/MacOS/MenDao"]["ino"] == row["executableInode"]
                        for record in seen.get(raw, [])), "LaunchServices记录不属于该路径的已封存程序身份。")
        require(any(row["path"] in formal for row in rows), "LaunchServices缺少正式入口的有效正向记录，停止登记。")
        return rows
    rows = records()  # No mutation before a valid, positively anchored query.
    actions, skipped = [], []
    for raw in sorted(paths - set(formal)):
        rows = records()
        if not any(row["path"] == raw for row in rows):
            skipped.append(raw)
            continue  # In particular, a moved/unregistered stage is not -u'd.
        unchanged()
        run_checked([APP_LSREGISTER, "-u", raw])
        unchanged()
        require(not any(row["path"] == raw for row in records()), "精确暂存登记仍存在，保留未完成阶段。")
        actions.append({"action": "unregister", "path": raw})
    for raw, record in formal.items():
        records(); unchanged()
        run_checked([APP_LSREGISTER, "-f", raw])
        unchanged()
        rows = records()
        require(any(row["path"] == raw and row["inode"] == record["metadataTree"]["."]["ino"]
                    and row["executableInode"] == record["metadataTree"]["Contents/MacOS/MenDao"]["ino"] for row in rows),
                "正式程序登记尚未对应已封存的当前原件。")
        actions.append({"action": "register", "path": raw})
    rows = records()
    require({row["path"] for row in rows} == set(formal), "仍有本App非正式登记，保留未完成阶段。")
    state = load_state(backup)
    require(_app_json(application_authority(backup)) == frozen, "完成登记前恢复依据改变。")
    state["applicationRegistration"] = {"at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "exactPaths": sorted(paths),
                                         "actions": actions, "unregisteredPathsSkipped": skipped,
                                         "verifiedRegisteredPaths": sorted({row["path"] for row in rows}),
                                         "requiresUserSessionSpotlightAndLaunchServicesVerification": True}
    update_state(backup, state)

@_program_guard
def rollback(backup, no_open=False, checkpoint=None):
    state = load_state(backup)
    require(state["phase"] in ("replacing", "installed", "acceptanceFailed", "finalized", "rollingBack"), "此备份没有待回滚的安装。")
    old_names = state["oldApplications"]
    require(old_names and set(old_names).issubset(APP_NAMES), "旧程序清单无效。")
    chain = verify_application_objects(backup)
    old = {name: chain["objects"]["old:" + name] for name in old_names}
    for name, item in old.items():
        require(item["path"] in (str(APPLICATIONS / name), str(backup / "PreviousApplications" / name)), "旧原件恢复指针无效。")
    current = APPLICATIONS / "搞门户.app"
    new = chain["objects"]["new"]
    retire_current = new["path"] == str(current)
    if state["phase"] != "rollingBack":
        state["rollbackTransaction"] = {"format": 2, "fromPhase": state["phase"],
                                        "oldApplications": {name: item["record"] for name, item in old.items()},
                                        "retireCurrent": retire_current, "retiredApplication": new["record"] if retire_current else None,
                                        "applicationSafetyAnchor": state["applicationSafety"]["anchorSHA256"]}
        if retire_current:
            state["failedApplicationPath"] = "FailedApplication.noindex/搞门户.app"
        state["phase"] = "rollingBack"; update_state(backup, state)
    else:
        require(state["rollbackTransaction"].get("format") == 2
                and state["rollbackTransaction"].get("applicationSafetyAnchor") == state["applicationSafety"]["anchorSHA256"], "回滚未绑定完整原件链。")
    stop_owned_processes()
    chain = verify_application_objects(backup)
    if chain["objects"]["new"]["path"] == str(current):
        failed_container = backup / "FailedApplication.noindex"
        if not failed_container.exists():
            failed_container.mkdir(mode=0o700); sync_directory(backup)
        require(has_noindex_container(failed_container), "失败程序暂存必须预建不索引容器。")
        move_application_original(backup, "new", failed_container / "搞门户.app")
        if checkpoint:
            checkpoint("afterCurrentRetired")
    for name in old_names:
        item = application_authority(backup)["objects"]["old:" + name]
        if item["path"] != str(APPLICATIONS / name):
            move_application_original(backup, "old:" + name, APPLICATIONS / name)
            if checkpoint:
                checkpoint("afterOldRestored")
    chain = verify_application_objects(backup)
    # Keep rollingBack until exact registration succeeds. A crash/failure here
    # is idempotently resumable and cannot strand a terminal phase.
    refresh_application_registration(backup)
    state = load_state(backup); state["phase"] = "rolledBack"
    state["restoredApplicationPointers"] = {name: chain["objects"]["old:" + name] for name in old_names}
    update_state(backup, state)
    # Program recovery never overwrites current user data or restores old snapshots.
    if not no_open:
        verify(backup)
        run_checked(["/usr/bin/open", str(APPLICATIONS / old_names[0])])

def _download_acceptance_volume(device):
    mount = Path("/System/Volumes/Data")
    fd = _app_dir_fd(mount)
    try:
        before = os.fstat(fd)
        require(before.st_dev == device, "下载重授权不是当前内部Data卷，未接纳设备号变化。")
        result = subprocess.run(["/usr/sbin/diskutil", "info", "-plist", str(mount)],
                                check=True, capture_output=True)
        require(result.stdout and not result.stderr.strip(), "内部卷查询失败或不明确，未接纳重授权。")
        info = plistlib.loads(result.stdout)
        require(info.get("Internal") is True and str(info.get("FilesystemType", "")).lower() == "apfs"
                and info.get("MountPoint") == str(mount), "下载验收仅支持已核验的内部APFS Data卷。")
        volume = str(uuid.UUID(info["VolumeUUID"]))
        after = os.fstat(fd)
        require((before.st_dev, before.st_ino) == (after.st_dev, after.st_ino), "查询期间内部卷身份改变。")
        return volume
    finally:
        os.close(fd)


class DownloadAcceptancePhysical:
    """Read-only, FD-held witness for this completed-download acceptance path."""
    def __init__(self, evidence):
        self.evidence = copy.deepcopy(evidence)
        self.root_fd, self.stage_fd = -1, -1
        self.files = []
        self.stage_missing = False
        try:
            self.root = Path(evidence["directoryPath"])
            self.root_fd = _app_dir_fd(self.root)
            self.root_identity = self.directory_identity(os.fstat(self.root_fd))
            require(self.root_identity[0] == evidence["newDevice"]
                    and self.root_identity[1] == evidence["directoryInode"]
                    and self.root_identity[2] == os.getuid() and self.root_identity[4] & 0o022 == 0,
                    "原下载目录设备、inode、所有者或权限不符。")
            self.stage_name = ".GaoXiaZai-Staging-" + evidence["grantID"].upper()
            associated = evidence["associatedItems"]
            require(associated, "没有可核验的原下载产物，不能按本轮目录重授权验收。")
            for item in associated:
                require(item["state"] == "completed" and item.get("pendingArtifact") is None
                        and isinstance(item.get("artifact"), dict) and isinstance(item["artifact"].get("current"), dict),
                        "此窄验收仅支持已完成且没有中断发布的原下载，未放宽其他状态。")
                artifact = item["artifact"]["current"]
                name = artifact["fileName"]
                require(isinstance(name, str) and name and not name.startswith(".") and len(name.encode()) <= 200
                        and not any(ord(c) < 32 or c in "/\\:" for c in name), "原下载产物名称无效。")
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=self.root_fd)
                try:
                    value = os.fstat(fd)
                    require(stat.S_ISREG(value.st_mode) and value.st_uid == os.getuid() and value.st_nlink == 1
                            and value.st_mode & 0o022 == 0 and value.st_dev == evidence["newDevice"]
                            and value.st_ino == artifact["inode"] and value.st_size == artifact["byteCount"]
                            and value.st_size == item["bytesReceived"], "原下载成品的物理身份、长度或权限不符。")
                    self.files.append((fd, name, self.file_identity(value), artifact["sha256"]))
                except BaseException:
                    os.close(fd)
                    raise
                if item.get("stagingInode") is not None:
                    require(item["stagingInode"] == artifact["inode"] and item["currentStagingDevice"] == evidence["newDevice"],
                            "历史暂存身份不属于原成品。")
                    if self.stage_fd < 0 and not self.stage_missing:
                        try:
                            self.stage_fd = os.open(self.stage_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                                    dir_fd=self.root_fd)
                        except FileNotFoundError:
                            self.stage_missing = True
                        if self.stage_fd >= 0:
                            value = os.fstat(self.stage_fd)
                            self.stage_identity = self.directory_identity(value)
                            require(value.st_uid == os.getuid() and value.st_mode & 0o077 == 0
                                    and value.st_dev == evidence["newDevice"], "历史暂存目录身份不符。")
            self.validate()
        except BaseException:
            self.close()
            raise

    @staticmethod
    def directory_identity(value):
        return (value.st_dev, value.st_ino, value.st_uid, value.st_gid, value.st_mode, value.st_flags)

    @classmethod
    def file_identity(cls, value):
        return cls.directory_identity(value) + (value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)

    def validate(self):
        evidence = self.evidence
        require(str(uuid.UUID(_download_acceptance_volume(evidence["newDevice"]))) == str(uuid.UUID(evidence["volumeUUID"])),
                "原下载卷UUID不符，未接纳重授权。")
        reopened = _app_dir_fd(self.root)
        try:
            require(self.directory_identity(os.fstat(self.root_fd)) == self.root_identity
                    == self.directory_identity(os.fstat(reopened))
                    and os.access(".", os.W_OK | os.X_OK, dir_fd=self.root_fd), "核验期间原下载目录身份或权限改变。")
        finally:
            os.close(reopened)
        for fd, name, identity, expected_hash in self.files:
            require(self.file_identity(os.fstat(fd)) == identity, "原下载文件在验收期间改变。")
            hasher, offset = hashlib.sha256(), 0
            while offset < identity[7]:
                raw = os.pread(fd, min(256 * 1024, identity[7] - offset), offset)
                require(raw, "原下载文件读取中断或长度改变。")
                hasher.update(raw); offset += len(raw)
            require(hasher.hexdigest() == expected_hash.lower()
                    and self.file_identity(os.fstat(fd)) == identity
                    == self.file_identity(os.stat(name, dir_fd=self.root_fd, follow_symlinks=False)),
                    "原下载文件摘要、inode或完整元数据发生变化。")
        # End-of-pass CAS after all file hashes, including missing staging names.
        for fd, name, identity, _ in self.files:
            require(self.file_identity(os.fstat(fd)) == identity
                    == self.file_identity(os.stat(name, dir_fd=self.root_fd, follow_symlinks=False)), "核验后原下载文件变化。")
        if self.stage_missing:
            self.require_absent(self.root_fd, self.stage_name)
        if self.stage_fd >= 0:
            require(self.directory_identity(os.fstat(self.stage_fd)) == self.stage_identity
                    == self.directory_identity(os.stat(self.stage_name, dir_fd=self.root_fd, follow_symlinks=False)),
                    "历史暂存目录在验收期间改变。")
            for item in evidence["associatedItems"]:
                if item.get("stagingInode") is not None:
                    self.require_absent(self.stage_fd, item["stagingName"])
        reopened = _app_dir_fd(self.root)
        try:
            require(self.directory_identity(os.fstat(reopened)) == self.root_identity, "核验后下载目录被替换。")
        finally:
            os.close(reopened)
        require(str(uuid.UUID(_download_acceptance_volume(evidence["newDevice"]))) == str(uuid.UUID(evidence["volumeUUID"])),
                "核验后原下载卷UUID改变。")

    @staticmethod
    def require_absent(parent, name):
        try:
            os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return
        raise RuntimeError("原已完成下载的暂存名称被占用，未接纳重授权。")

    def close(self):
        for fd, _, _, _ in self.files:
            os.close(fd)
        self.files = []
        if self.stage_fd >= 0:
            os.close(self.stage_fd); self.stage_fd = -1
        if self.root_fd >= 0:
            os.close(self.root_fd); self.root_fd = -1


def verify_exact_current_snapshot(backup):
    current = load_state(backup)
    require(current["phase"] == "backedUp" and not current["oldApplications"], "当前资料备份阶段无效。")
    # No exemptions: this snapshot must describe every current file, setting
    # and credential reference, rather than merely preserving an old subset.
    fresh = verify(backup)
    files, dirs = file_tree(Path.home() / "Library/Application Support/MenDao")
    require({name: digest(data) for name, data in files.items()} == current["files"]
            and dirs == current["directories"], "当前完整资料备份与当前文件不一致。")
    _, current_preferences = preferences()
    require(plistlib.loads(regular_bytes(backup / "preferences.plist")) == current_preferences,
            "当前完整资料备份与当前设置不一致。")
    references = fresh["keychain"]
    require(references.get("unavailable") == 0
            and references.get("available") == references.get("passwordReferences"),
            "当前完整备份中有不可用的钥匙串引用，不能完成验收。")
    receipt = regular_bytes(backup / "state.json")
    require(json.loads(receipt) == current, "当前完整备份收据正在变化，已停止验收。")
    return {"path": str(backup), "stateSHA256": digest(receipt), "counts": current["counts"]}


@_program_guard
def finalize(backup, allowed_preferences=(), allow_icon_cache_updates=False,
             accepted_data_backup=None, accepted_account_site_ids=(), accepted_download_grant_id=None,
             accepted_app_macl_authority=None, accepted_app_macl_authority_sha256=None):
    require(bool(accepted_app_macl_authority) == bool(accepted_app_macl_authority_sha256),
            "本次程序根MACL观察必须同时指定私有事实与独立明确摘要。")
    observation = None
    if accepted_app_macl_authority is not None:
        require(accepted_data_backup is not None and accepted_data_backup != backup,
                "程序观察必须先绑定独立完整当前备份。")
        observed_snapshot = verify_exact_current_snapshot(accepted_data_backup)
        # This exact, explicitly approved fact is appended independently before
        # freezing finalization's entry state. Safety remains in the full CAS.
        observation = observe_application_macl(backup, accepted_app_macl_authority,
                                                accepted_app_macl_authority_sha256, observed_snapshot)
    state = load_state(backup)
    def stable_state(value):
        return _app_json({key: item for key, item in value.items()
                          if key != "applicationRegistration"})
    entry_state = stable_state(state)
    require(state["phase"] == "installed", "没有待验收的新版本。")
    require(state["oldApplications"], "缺少旧程序备份清单，不能完成验收。")
    info = app_info(APPLICATIONS / "搞门户.app")
    require(info["CFBundleShortVersionString"] == state["newVersion"] and info["CFBundleVersion"] == state["newBuild"], "安装版本与待验收记录不符。")
    run_checked(["/usr/bin/codesign", "--verify", "--strict", str(APPLICATIONS / "搞门户.app")])
    require(bool(accepted_data_backup) == bool(accepted_account_site_ids or accepted_download_grant_id or accepted_app_macl_authority),
            "定向业务验收必须同时指定独立当前完整备份和确切网站或下载目录编号。")
    acceptance = None
    if accepted_data_backup is not None:
        require(accepted_data_backup != backup, "必须使用独立的当前完整资料备份。")
        acceptance = verify_exact_current_snapshot(accepted_data_backup)
        checked = verify(backup, allowed_preferences=allowed_preferences,
                         allow_icon_cache_updates=allow_icon_cache_updates,
                         _accepted_account_sites=accepted_account_site_ids,
                         _accepted_download_grant_id=accepted_download_grant_id)
        if accepted_account_site_ids:
            acceptance["newAccounts"] = checked["dataVerification"]["explicitlyAcceptedNewAccounts"]
        if observation is not None:
            acceptance["appRootMaclObservation"] = observation
    else:
        checked = verify(backup, allowed_preferences=allowed_preferences, allow_icon_cache_updates=allow_icon_cache_updates)
    physical = None
    try:
        if accepted_download_grant_id is not None:
            evidence = checked["dataVerification"]["explicitlyAcceptedDownloadReauthorization"]
            physical = DownloadAcceptancePhysical(evidence)
            acceptance["downloadReauthorization"] = evidence
        # Acceptance preserves the exact program originals and their receipts.
        chain = verify_application_objects(backup)
        require(stable_state(chain["state"]) == entry_state, "验收期间原升级收据改变，未覆盖旧依据。")
        require(chain["objects"]["new"]["path"] == str(APPLICATIONS / "搞门户.app"), "当前新版未绑定完整身份链。")
        records = {}
        for name in state["oldApplications"]:
            old = backup / "PreviousApplications" / name
            require(has_noindex_container(old.parent) and chain["objects"]["old:" + name]["path"] == str(old),
                    "旧原件恢复指针不符；不能删除或改用副本。")
            records[name] = chain["objects"]["old:" + name]["record"]
        verify_application_objects(backup)
        # Keep installed until registration AND the final snapshot/file CAS
        # succeed. Neither path rewrites the original backed-up data/model.
        refresh_application_registration(backup)
        registered_state = load_state(backup)
        require(stable_state(registered_state) == entry_state
                and isinstance(registered_state.get("applicationRegistration"), dict), "本轮登记收据或原升级依据不符。")
        registration_bytes = _app_json(registered_state["applicationRegistration"])
        if acceptance is not None:
            final_snapshot = verify_exact_current_snapshot(accepted_data_backup)
            require(final_snapshot == {key: acceptance[key] for key in final_snapshot},
                    "验收期间当前完整备份发生变化，已停止验收。")
        if physical is not None:
            physical.validate()
        verified_state = load_state(backup)
        require(stable_state(verified_state) == entry_state
                and verified_state["phase"] == "installed" and verified_state["applicationSafety"] == chain["state"]["applicationSafety"],
                "验收期间程序阶段或原件指针改变，未完成验收。")
        require(_app_json(verified_state.get("applicationRegistration")) == registration_bytes,
                "本轮登记完成后的收据又发生变化，未完成验收。")
        state["applicationSafety"] = verified_state["applicationSafety"]
        state["phase"] = "finalized"
        state["rollbackApplications"] = records
        state["dataVerification"] = checked["dataVerification"]
        if acceptance is not None:
            state["acceptedDataBackup"] = acceptance
        state["acceptedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        state["applicationRegistration"] = verified_state["applicationRegistration"]
        update_state(backup, state)
    finally:
        if physical is not None:
            physical.close()


def _retain_program_stage(path, reason, backup=None):
    # This is a pointer/evidence receipt, not authority to delete its contents.
    # A future maintenance step must inventory and prove the object first.
    destination = (Path(backup) if backup is not None else BACKUPS)
    directory(destination)
    value = {"format": 1, "appID": APP_ID, "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "path": str(path), "reason": reason, "requiresExplicitIdentityReviewBeforeCleanup": True}
    try:
        attributes = path.lstat()
        value["observedContainer"] = _app_stat(attributes)
    except OSError:
        value["observedContainer"] = None
    private_write(destination / ("程序暂存保留-" + str(uuid.uuid4()) + ".json"), _app_json(value))


def _cleanup_empty_program_stage(path, identity, backup=None):
    try:
        observed = path.lstat()
        if not stat.S_ISDIR(observed.st_mode) or (observed.st_dev, observed.st_ino) != identity or any(path.iterdir()):
            _retain_program_stage(path, "nonempty-or-replaced-stage", backup)
            return
        path.rmdir()  # Only this verified empty directory; never recursive cleanup.
    except FileNotFoundError:
        return
    except OSError:
        _retain_program_stage(path, "stage-cleanup-needs-maintenance", backup)


@_program_guard
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
    # Never let TemporaryDirectory recursively delete an identity-mismatched
    # stage during failure unwinding. Nonempty/unproven stages remain noindex.
    mount = tempfile.mkdtemp(prefix="mendao-install-", suffix=".noindex", dir="/private/tmp")
    staging = tempfile.mkdtemp(prefix=".GaoMenHu-install-", suffix=".noindex", dir=APPLICATIONS)
    mount_identity = (Path(mount).stat().st_dev, Path(mount).stat().st_ino)
    staging_identity = (Path(staging).stat().st_dev, Path(staging).stat().st_ino)
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
        bind_application_safety(backup, {name: APPLICATIONS / name for name in old_names}, staged)
        replaced = True
        for name in old_names:
            move_application_original(backup, "old:" + name, previous / name)
        move_application_original(backup, "new", APPLICATIONS / "搞门户.app")
        verify_application_objects(backup)
        run_checked(["/usr/bin/codesign", "--verify", "--strict", str(APPLICATIONS / "搞门户.app")])
        verify(backup)
        state = load_state(backup)
        state["phase"] = "installed"
        update_state(backup, state)
        refresh_application_registration(backup)
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
        try:
            if mounted:
                try:
                    run_checked(["/usr/bin/hdiutil", "detach", "-quiet", mount])
                    mounted = False
                finally:
                    if mounted:
                        _retain_program_stage(Path(mount), "candidate-mount-still-mounted", backup)
        finally:
            _cleanup_empty_program_stage(Path(staging), staging_identity, backup)
            if not mounted:
                _cleanup_empty_program_stage(Path(mount), mount_identity, backup)

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
        # Program move fixtures now live in the narrow native-metadata suite.
        # Legacy byte-only fixtures must not manufacture a new restore authority.
    print("Upgrade data safety: " + str(checks) + " isolated checks passed; no real apps or private data changed.")
    subprocess.run([sys.executable, "-B", str(ROOT / "Tests/ProgramOriginalSafetyTests.py")], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("backup", "verify", "install", "self-test"))
    parser.add_argument("--no-open", action="store_true")
    parser.add_argument("--finalize", type=Path)
    parser.add_argument("--rollback", type=Path)
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--allow-preference-key", action="append", default=[])
    parser.add_argument("--allow-icon-cache-updates", action="store_true")
    parser.add_argument("--accepted-data-backup", type=Path)
    parser.add_argument("--accepted-account-site-id", action="append", default=[])
    parser.add_argument("--accepted-download-grant-id")
    parser.add_argument("--accepted-app-macl-authority", type=Path)
    parser.add_argument("--accepted-app-macl-authority-sha256")
    args = parser.parse_args()
    require(not (args.finalize and args.rollback), "不能同时验收和回滚。")
    require(not (args.accepted_data_backup or args.accepted_account_site_id or args.accepted_download_grant_id
                 or args.accepted_app_macl_authority or args.accepted_app_macl_authority_sha256)
            or (args.command == "install" and args.finalize), "定向业务验收参数仅用于完成现有升级验收。")
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
        finalize(args.finalize, args.allow_preference_key, args.allow_icon_cache_updates,
                 args.accepted_data_backup, args.accepted_account_site_id, args.accepted_download_grant_id,
                 args.accepted_app_macl_authority, args.accepted_app_macl_authority_sha256)
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
