"""Chromium Native Messaging and the per-data-directory local rendezvous."""

import ctypes
import json
import os
import struct
import sys
import urllib.request
import uuid
from pathlib import Path

from . import EXTENSION_ID, NATIVE_HOST_NAME
from .browsers import BROWSER_HELPERS

EXTENSION_ORIGIN = f"chrome-extension://{EXTENSION_ID}/"
FRAME_LIMIT = 1_048_576


def browser_from_ancestors():
    if os.name != "nt":
        return None
    from ctypes import wintypes

    class ProcessEntry(ctypes.Structure):
        _fields_ = [
            ("size", wintypes.DWORD), ("usage", wintypes.DWORD), ("pid", wintypes.DWORD),
            ("heap", ctypes.c_size_t), ("module", wintypes.DWORD), ("threads", wintypes.DWORD),
            ("parent", wintypes.DWORD), ("priority", wintypes.LONG), ("flags", wintypes.DWORD),
            ("name", wintypes.WCHAR * 260),
        ]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    snapshot = kernel.CreateToolhelp32Snapshot
    snapshot.argtypes = (wintypes.DWORD, wintypes.DWORD)
    snapshot.restype = wintypes.HANDLE
    handle = snapshot(2, 0)
    if not handle or handle == ctypes.c_void_p(-1).value:
        return None
    first, next_process = kernel.Process32FirstW, kernel.Process32NextW
    for function in (first, next_process):
        function.argtypes = (wintypes.HANDLE, ctypes.POINTER(ProcessEntry))
        function.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    processes = {}
    entry = ProcessEntry()
    entry.size = ctypes.sizeof(entry)
    try:
        found = first(handle, ctypes.byref(entry))
        while found:
            processes[entry.pid] = entry.parent, entry.name.casefold()
            found = next_process(handle, ctypes.byref(entry))
    finally:
        kernel.CloseHandle(handle)

    browsers = {filename: browser for browser, filename in BROWSER_HELPERS.items()}
    pid = os.getpid()
    for _ in range(12):
        pid, name = processes.get(pid, (0, ""))
        if name in browsers:
            return browsers[name]
        if not pid:
            break
    return None


def rendezvous_path(data_dir):
    data_dir = Path(data_dir)
    return data_dir.with_name(data_dir.name + ".native.json")


def publish_host(data_dir, port, token):
    path = rendezvous_path(data_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex)
    try:
        temporary.write_text(json.dumps({"port": port, "token": token}), encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def exchange(data_dir, endpoint, payload):
    info = json.loads(rendezvous_path(data_dir).read_text(encoding="utf-8"))
    port, token = info["port"], info["token"]
    if type(port) is not int or not 0 < port < 65536 or not isinstance(token, str) or not token:
        raise ValueError("Invalid portal rendezvous")
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{endpoint}", data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "X-Gao-Host": token}, method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=4) as response:
        return json.load(response)


def read_message():
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        return None
    length = struct.unpack("<I", header)[0]
    if not 0 < length <= FRAME_LIMIT:
        return None
    body = sys.stdin.buffer.read(length)
    if len(body) < length:
        return None
    message = json.loads(body.decode("utf-8"))
    if not isinstance(message, dict):
        raise ValueError("Native message must be an object")
    return message


def write_message(payload):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    if len(body) > FRAME_LIMIT:
        body = json.dumps({"ok": False, "rid": payload.get("rid"), "error": "助手响应过大，请从搞门户中完成这项操作。"}, ensure_ascii=False).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(body)))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def run_native_host(data_dir, browser):
    if browser not in BROWSER_HELPERS or sys.stdin is None or sys.stdout is None:
        return 1
    if os.name == "nt":
        import msvcrt
        for stream in (sys.stdin, sys.stdout):
            msvcrt.setmode(stream.fileno(), os.O_BINARY)
    try:
        while (message := read_message()) is not None:
            try:
                response = exchange(data_dir, "/api/native", {
                    "message": message, "browser": browser, "extension": EXTENSION_ID,
                })
            except (OSError, ValueError, KeyError):
                response = {"ok": False, "error": "搞门户没有在运行，请打开搞门户后重试。"}
            rid = message.get("rid")
            response["rid"] = rid if isinstance(rid, str) and len(rid) <= 128 else None
            write_message(response)
    except (OSError, ValueError):
        return 1
    return 0


def native_manifest(executable):
    return {
        "name": NATIVE_HOST_NAME, "description": "搞门户浏览器助手",
        "path": str(Path(executable).resolve()), "type": "stdio",
        "allowed_origins": [EXTENSION_ORIGIN],
    }
