"""网站密码和邮件凭据。

Windows 使用当前用户的 DPAPI，相当于钥匙串的「仅本机解锁后可用」。
其他系统上的开发测试使用目录外的本机密钥文件，不写入 library.json。
"""

import base64
import ctypes
import hashlib
import hmac
import json
import os
import threading
import uuid
from contextlib import contextmanager
from pathlib import Path

from . import MAIL_CREDENTIAL_SERVICE, PASSWORD_SERVICE
from .errors import AppError


def protect(data: bytes) -> bytes:
    if os.name == "nt":
        return b"DPAPI" + _dpapi(data, protect=True)
    return _local_protect(data)


def unprotect(data: bytes) -> bytes:
    if data.startswith(b"DPAPI"):
        if os.name != "nt":
            raise AppError("这份凭据使用 Windows DPAPI 加密，不能在当前系统读取。")
        return _dpapi(data[5:], protect=False)
    if data.startswith(b"GMH1"):
        return _local_unprotect(data)
    raise AppError("凭据格式无法识别。")


def _dpapi(data: bytes, protect: bool) -> bytes:
    class DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", ctypes.c_uint32), ("pbData", ctypes.POINTER(ctypes.c_byte))]

    crypt32 = ctypes.windll.crypt32
    kernel32 = ctypes.windll.kernel32
    kernel32.LocalFree.argtypes = (ctypes.c_void_p,)
    kernel32.LocalFree.restype = ctypes.c_void_p
    buffer = ctypes.create_string_buffer(data, len(data))
    blob_in = DATA_BLOB(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_byte)))
    blob_out = DATA_BLOB()
    function = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    description = ctypes.c_wchar_p("GaoMenHu")
    if protect:
        ok = function(ctypes.byref(blob_in), description, None, None, None, 1, ctypes.byref(blob_out))
    else:
        ok = function(ctypes.byref(blob_in), None, None, None, None, 1, ctypes.byref(blob_out))
    if not ok:
        raise AppError("无法使用 Windows 数据保护接口保存凭据。")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


def _key_path(directory: Path) -> Path:
    return directory.parent / (directory.name + ".vault.key")


def _local_key(directory: Path) -> bytes:
    path = _key_path(directory)
    if path.exists():
        key = path.read_bytes()
        if len(key) == 32:
            return key
    path.parent.mkdir(parents=True, exist_ok=True)
    key = os.urandom(32)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    fd = os.open(str(path), flags, 0o600)
    try:
        os.write(fd, key)
        os.fsync(fd)
    finally:
        os.close(fd)
    return key


def _local_protect(data: bytes) -> bytes:
    # 密钥路径在调用方通过 Vault 注入。这里只定义格式；Vault 负责取密钥。
    raise AppError("内部加密入口使用错误。")


def _local_unprotect(data: bytes) -> bytes:
    raise AppError("内部加密入口使用错误。")


def seal(data: bytes, key: bytes) -> bytes:
    nonce = os.urandom(16)
    stream = _stream(key, nonce, len(data))
    body = bytes(left ^ right for left, right in zip(data, stream))
    mac = hmac.new(key, nonce + body, hashlib.sha256).digest()
    return b"GMH1" + nonce + mac + body


def open_seal(data: bytes, key: bytes) -> bytes:
    if not data.startswith(b"GMH1") or len(data) < 4 + 16 + 32:
        raise AppError("凭据格式无法识别。")
    nonce = data[4:20]
    mac = data[20:52]
    body = data[52:]
    expected = hmac.new(key, nonce + body, hashlib.sha256).digest()
    if not hmac.compare_digest(mac, expected):
        raise AppError("凭据校验失败。")
    stream = _stream(key, nonce, len(body))
    return bytes(left ^ right for left, right in zip(body, stream))


def _stream(key, nonce, length):
    output = bytearray()
    counter = 0
    while len(output) < length:
        output.extend(hmac.new(key, nonce + counter.to_bytes(4, "big"), hashlib.sha256).digest())
        counter += 1
    return bytes(output[:length])


class Vault:
    def __init__(self, directory: Path, filename, service):
        self.directory = Path(directory)
        self.path = self.directory / filename
        self.service = service
        self.cache = None
        self.unlocked_until = 0
        self._mutex = threading.RLock()

    @contextmanager
    def maintain_lock_state(self, now):
        with self._mutex:
            was_unlocked = self.is_unlocked(now)
            try:
                yield
            finally:
                if not was_unlocked:
                    self.lock()

    def unlock(self, now):
        with self._mutex:
            self.cache = self._read()
            self.unlocked_until = now + 300
        return True

    def lock(self):
        with self._mutex:
            self.cache = None
            self.unlocked_until = 0

    def is_unlocked(self, now):
        with self._mutex:
            if self.cache is None or now > self.unlocked_until:
                self.lock()
                return False
            return True

    def save(self, account_id, secret, now):
        if not isinstance(secret, str) or not secret:
            raise AppError("密码不可用，请重新输入。")
        with self._mutex:
            if not self.is_unlocked(now):
                self.unlock(now)
            items = {**self.cache, account_id: secret}
            self._write(items)
            self.cache = items

    def read(self, account_id, now):
        with self._mutex:
            if not self.is_unlocked(now):
                raise AppError("账号库已锁定，请回到搞门户解锁。")
            secret = self.cache.get(account_id, "")
            if not secret:
                raise AppError("密码不可用，请在搞门户中重新保存该账号密码。")
            return secret

    def remove(self, account_id, now):
        with self._mutex:
            if not self.is_unlocked(now):
                self.unlock(now)
            items = self.cache.copy()
            previous = items.pop(account_id, None)
            self._write(items)
            self.cache = items
            return previous

    def _read(self):
        if not self.path.exists():
            return {}
        raw = self.path.read_bytes()
        if os.name == "nt" and raw.startswith(b"DPAPI"):
            payload = unprotect(raw)
        else:
            payload = open_seal(raw, _local_key(self.directory))
        document = json.loads(payload.decode("utf-8"))
        if document.get("service") != self.service or not isinstance(document.get("items"), dict):
            raise AppError("凭据服务不匹配。")
        return {key: value for key, value in document["items"].items() if isinstance(key, str) and isinstance(value, str)}

    def _write(self, items):
        self.directory.mkdir(parents=True, exist_ok=True)
        payload = json.dumps({"service": self.service, "items": items}, ensure_ascii=False, sort_keys=True).encode("utf-8")
        if os.name == "nt":
            blob = protect(payload)
        else:
            blob = seal(payload, _local_key(self.directory))
        temporary = self.path.with_name(self.path.name + f".tmp-{uuid.uuid4().hex}")
        with open(temporary, "wb") as handle:
            handle.write(blob)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, self.path)


def site_vault(directory: Path) -> Vault:
    return Vault(directory, "credentials.bin", PASSWORD_SERVICE)


def mail_vault(directory: Path) -> Vault:
    return Vault(directory, "mail-credentials.bin", MAIL_CREDENTIAL_SERVICE)
