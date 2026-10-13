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
    destination = backup_root / ("升级-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + str(uuid.uuid4()))
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
    names = state.get("oldApplications")
    require(isinstance(names, list) and all(name in APP_NAMES for name in names)
            and len(names) == len(set(names)), "旧程序暂存清单无效。")
    return state


def update_state(backup, state):
    temp = backup / (".state-" + str(uuid.uuid4()))
    private_write(temp, json.dumps(state, ensure_ascii=False, indent=2).encode())
    os.replace(temp, backup / "state.json")


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


def rollback(backup, no_open=False):
    state = load_state(backup)
    require(state["phase"] in ("replacing", "installed", "acceptanceFailed"), "此备份没有待回滚的安装。")
    old_names = state["oldApplications"]
    require(set(old_names).issubset(APP_NAMES) and len(old_names) == len(set(old_names)), "旧程序记录无效。")
    for name in old_names:
        previous = backup / "PreviousApplications" / name
        original = APPLICATIONS / name
        candidate = previous if previous.exists() else original
        app_info(candidate)
        run_checked(["/usr/bin/codesign", "--verify", "--strict", str(candidate)])
    stop_owned_processes()
    current = APPLICATIONS / "搞门户.app"
    # A crash during the first rename may leave the original at its old path.
    # It is only the new version if its saved previous copy already exists.
    if current.exists() and ("搞门户.app" not in old_names or (backup / "PreviousApplications/搞门户.app").exists()):
        app_info(current)
        failed = backup / "FailedApplication.app"
        require(not failed.exists(), "已存在失败程序副本，停止重复回滚。")
        shutil.move(str(current), failed)
    for name in old_names:
        source = backup / "PreviousApplications" / name
        destination = APPLICATIONS / name
        if source.exists():
            require(not destination.exists(), "回滚目的地已存在，已停止覆盖。")
            os.rename(source, destination)
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
    info = app_info(APPLICATIONS / "搞门户.app")
    require(info["CFBundleShortVersionString"] == state["newVersion"] and info["CFBundleVersion"] == state["newBuild"], "安装版本与待验收记录不符。")
    run_checked(["/usr/bin/codesign", "--verify", "--strict", str(APPLICATIONS / "搞门户.app")])
    checked = verify(backup, allowed_preferences=allowed_preferences, allow_icon_cache_updates=allow_icon_cache_updates)
    # Explicit finalize is the operator's acceptance after real business/UI QA.
    for name in state["oldApplications"]:
        old = backup / "PreviousApplications" / name
        app_info(old)
        shutil.rmtree(old)
    (backup / "PreviousApplications").rmdir()
    state["phase"] = "finalized"
    state["dataVerification"] = checked["dataVerification"]
    state["acceptedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    update_state(backup, state)


def install(no_open=False):
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
                require(previous.get("phase") not in ("replacing", "installed", "acceptanceFailed"), "已有升级待验收或回滚，请先处理现有安全备份。")
    with tempfile.TemporaryDirectory(prefix="mendao-install-", dir="/private/tmp") as mount:
        backup = None
        staged = APPLICATIONS / (".GaoMenHu-install-" + str(uuid.uuid4()) + ".app")
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
            files, _ = file_tree(Path.home() / "Library/Application Support/MenDao")
            require("library.json" in files, "原网站库缺失，停止升级。")
            validate_library(files["library.json"])
            preferences()
            native_hosts(Path.home())
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
            if staged.exists():
                app_info(staged)
                shutil.rmtree(staged)
            if mounted:
                run_checked(["/usr/bin/hdiutil", "detach", "-quiet", mount])


def self_test():
    """Isolated filesystem/state-machine tests; no real apps, settings or UI."""
    global preferences, APPLICATIONS, BACKUPS, load_state, run_checked, stop_owned_processes, verify
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
        root = Path(temp).resolve()
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
        real_load, real_verify = load_state, verify
        load_state = lambda path, _root=None: real_load(path, backup_root)
        verify = lambda path, **kw: real_verify(path, home, backup_root, keychain=False, **kw)
        run_checked = lambda arguments: None
        stop_owned_processes = lambda: None

        def fake_app(path, version):
            private_write(path / "Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": APP_ID, "CFBundleExecutable": "MenDao",
                                                                       "CFBundleShortVersionString": version, "CFBundleVersion": version.replace(".", "")}))

        previous = backup / "PreviousApplications"
        previous.mkdir()
        fake_app(previous / "搞门户.app", "1.13")
        fake_app(APPLICATIONS / "搞门户.app", "1.14")
        state = load_state(backup)
        state.update(phase="installed", oldApplications=["搞门户.app"], newVersion="1.14", newBuild="114")
        update_state(backup, state)
        rollback(backup, no_open=True)
        ok(app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.13")
        ok(app_info(backup / "FailedApplication.app")["CFBundleShortVersionString"] == "1.14")
        ok((data / "library.json").read_bytes() == encoded)
        rejects(lambda: rollback(backup, no_open=True))
        shutil.rmtree(APPLICATIONS / "搞门户.app")
        fake_app(previous / "搞门户.app", "1.13")
        fake_app(APPLICATIONS / "搞门户.app", "1.14")
        state.update(phase="installed")
        update_state(backup, state)
        finalize(backup)
        ok(load_state(backup)["phase"] == "finalized")
        ok(not previous.exists() and (backup / "MenDao/library.json").exists())
        ok(app_info(APPLICATIONS / "搞门户.app")["CFBundleShortVersionString"] == "1.14")
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
        print("升级验收完成；已删除旧程序副本，资料安全备份保留。")
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
