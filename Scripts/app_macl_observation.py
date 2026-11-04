"""Pure validation of one explicitly pinned new-App root MACL observation.

This module does not read a path, resolve a bookmark, grant access, change an
attribute, append a journal event or finalize an installation. The installer
binds the approved fact to its real immutable chain and fresh data snapshot.
"""
import base64
import binascii
import copy
import hashlib
import json
import math
from pathlib import PurePosixPath
import re


MAX_AUTHORITY_BYTES = 64 * 1024
MACL_KEY = base64.b64encode(b"com.apple.macl").decode("ascii")
OPERATION = "new-formal-root-macl-observation.v1"
FIELDS = {
    "format", "operation", "appID", "version", "build", "object", "formalPath",
    "upgradeBackup", "upgradeStateSHA256", "applicationSafetyAnchorSHA256",
    "applicationSafetyHeadSHA256", "currentDataBackup", "currentDataBackupStateSHA256",
    "beforeRecordSHA256", "afterRecordSHA256", "maclBase64", "maclSHA256", "maclBytes",
}
HASH_FIELDS = {
    "upgradeStateSHA256", "applicationSafetyAnchorSHA256", "applicationSafetyHeadSHA256",
    "currentDataBackupStateSHA256", "beforeRecordSHA256", "afterRecordSHA256", "maclSHA256",
}


def _require(value, message="新版程序根 MACL 观察依据不符，保留原件并停止验收。"):
    if not value:
        raise RuntimeError(message)


def _sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def _path(value):
    if not isinstance(value, str):
        return False
    try:
        return (value.startswith("/") and not value.startswith("//")
                and len(value.encode("utf-8")) <= 16384
                and not any(ord(character) < 32 for character in value)
                and not any(part in (".", "..") for part in value.split("/"))
                and str(PurePosixPath(value)) == value)
    except UnicodeError:
        return False


def _canonical(value):
    # Match backup_verify._app_json, while refusing non-JSON values. Canonical
    # bytes also distinguish boolean true from integer 1 in every unknown field.
    try:
        return json.dumps(value, sort_keys=True, ensure_ascii=True,
                          separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (ValueError, TypeError, UnicodeError):
        raise RuntimeError("程序身份或观察依据不是完整有效的 JSON。") from None


def _pairs(values):
    result = {}
    for key, value in values:
        _require(key not in result, "MACL 观察依据含重复字段，不能选择性接纳。")
        result[key] = value
    return result


def _json(raw):
    def invalid_constant(_):
        raise RuntimeError("MACL 观察依据含无效数值。")
    def finite_float(value):
        number = float(value)
        _require(math.isfinite(number), "MACL 观察依据含非有限数值。")
        return number
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs,
                          parse_constant=invalid_constant, parse_float=finite_float)
    except (UnicodeError, ValueError, TypeError, RecursionError):
        raise RuntimeError("MACL 观察依据无法严格读取。") from None


def _macl(value):
    _require(isinstance(value, str) and len(value) == 96, "MACL 观察值编码或长度不符。")
    try:
        raw = base64.b64decode(value.encode("ascii"), validate=True)
    except (UnicodeError, ValueError, binascii.Error):
        raise RuntimeError("MACL 观察值不是合法 Base64。") from None
    _require(len(raw) == 72 and base64.b64encode(raw).decode("ascii") == value,
             "MACL 观察值必须为完整的明确 72 字节值。")
    return raw


def _validate_authority(authority):
    _require(isinstance(authority, dict) and set(authority) == FIELDS,
             "MACL 观察依据字段缺失、过多或版本未知。")
    _require(type(authority["format"]) is int and authority["format"] == 1
             and authority["operation"] == OPERATION
             and authority["appID"] == "cn.mendao.launcher" and authority["object"] == "new")
    _require(all(isinstance(authority[key], str) and 0 < len(authority[key]) <= 64
                 for key in ("version", "build")))
    _require(all(_sha(authority[key]) for key in HASH_FIELDS), "MACL 观察依据的摘要字段无效。")
    _require(_path(authority["formalPath"])
             and PurePosixPath(authority["formalPath"]).name == "搞门户.app")
    _require(all(_path(authority[key]) and authority[key].endswith(".noindex")
                 for key in ("upgradeBackup", "currentDataBackup"))
             and authority["upgradeBackup"] != authority["currentDataBackup"],
             "MACL 观察必须绑定不同的原升级备份与独立当前备份。")
    _require(type(authority["maclBytes"]) is int and authority["maclBytes"] == 72)
    observed = _macl(authority["maclBase64"])
    _require(hashlib.sha256(observed).hexdigest() == authority["maclSHA256"], "MACL 完整观察值摘要不符。")
    _require(authority["beforeRecordSHA256"] != authority["afterRecordSHA256"],
             "没有明确新增 MACL 的前后程序身份变化。")


def parse_authority(raw, expectedSHA):
    """Parse only a caller-explicitly pinned private fact; no self-trust pin."""
    _require(type(raw) is bytes and 0 < len(raw) <= MAX_AUTHORITY_BYTES and _sha(expectedSHA),
             "必须提供独立明确的 MACL 观察依据摘要。")
    _require(hashlib.sha256(raw).hexdigest() == expectedSHA, "MACL 观察依据与明确摘要不符。")
    authority = _json(raw)
    _validate_authority(authority)
    return authority


def validate_transition(before, after, authority):
    """Permit exactly the approved root absent-to-value observation, nothing else.

    The full records remain intact. The caller must still prove real formal
    path, immutable anchor/head/state, signed program and fresh snapshot before
    appending an event. This function is not permission to mutate any attribute.
    """
    _validate_authority(authority)
    _require(isinstance(before, dict) and isinstance(after, dict))
    _require(type(before.get("recordFormat")) is int and before["recordFormat"] == 2
             and type(after.get("recordFormat")) is int and after["recordFormat"] == 2)
    _require(all(before.get(key) == after.get(key) == authority[key] for key in ("version", "build")))
    before_bytes, after_bytes = _canonical(before), _canonical(after)
    _require(hashlib.sha256(before_bytes).hexdigest() == authority["beforeRecordSHA256"]
             and hashlib.sha256(after_bytes).hexdigest() == authority["afterRecordSHA256"],
             "前后完整程序身份摘要与明确观察事实不符。")
    try:
        original = before["metadataTree"]["."]["xattrs_b64"]
        observed = after["metadataTree"]["."]["xattrs_b64"]
    except (KeyError, TypeError):
        raise RuntimeError("完整程序身份缺少根扩展属性依据。") from None
    _require(isinstance(original, dict) and isinstance(observed, dict)
             and MACL_KEY not in original and observed.get(MACL_KEY) == authority["maclBase64"],
             "仅允许新版根节点从缺失变为已明确绑定的 MACL 值。")
    comparison = copy.deepcopy(after)
    del comparison["metadataTree"]["."]["xattrs_b64"][MACL_KEY]
    _require(_canonical(comparison) == before_bytes,
             "MACL 观察不能掩盖其他程序内容、身份、权限或元数据变化。")
