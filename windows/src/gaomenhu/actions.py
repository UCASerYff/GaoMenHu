"""GaoAction V1 与搞门户动作规划。portal.* 不接受附件，参数里不能带密码。"""

import base64
import hashlib
import json
import os
import re
import stat
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import APP_ID
from .errors import AppError
from .models import BROWSER_IDS, checked_url, normalized_host, origin_of, strip_query_and_fragment, valid_web_url

MAX_MANIFEST_BYTES = 1_048_576
MAX_TTL_SECONDS = 120
MAX_PAYLOAD_BYTES = 2 * 1024 ** 3
ERROR_RE = re.compile(r"[a-z0-9_]{1,80}")
HASH_RE = re.compile(r"[a-fA-F0-9]{64}")
UUID_RE = re.compile(r"[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}")
DEVICE_NAMES = {"CON", "PRN", "AUX", "NUL"} | {f"{group}{number}" for group in ("COM", "LPT") for number in "123456789¹²³"}
ACTION_RE = re.compile(r"^[a-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$")
BUNDLE_RE = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z$")
PORTAL_ACTIONS = {
    "portal.openSite",
    "portal.openWorkspace",
    "portal.focusSearch",
    "portal.proposeSite",
    "portal.prepareDownload",
}
REQUEST_KEYS = {
    "schemaVersion", "kind", "requestID", "sourceBundleID", "targetBundleID", "action",
    "createdAt", "expiresAt", "nonce", "items", "references", "parameters",
}
RESULT_KEYS = REQUEST_KEYS | {"inReplyTo", "status", "errorCode", "provenance"}
SECRET_KEYS = {"password", "secret", "token", "cookie", "authorization"}


def _parse_date(value):
    if not isinstance(value, str) or not DATE_RE.match(value):
        return None
    try:
        if "." in value:
            value = re.sub(r"(\.\d{6})\d+Z$", r"\1Z", value)
            return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _valid_bundle(value):
    return isinstance(value, str) and len(value) <= 255 and BUNDLE_RE.fullmatch(value) is not None


def manifest_uuid(value):
    if not isinstance(value, str) or not UUID_RE.fullmatch(value):
        raise AppError("交接标识无效。", "invalidIdentity")
    return value.lower()


def strict_json(data):
    def object_pairs(pairs):
        result = dict(pairs)
        if len(result) != len(pairs):
            raise ValueError("duplicate member")
        return result

    def reject_constant(_):
        raise ValueError("non-JSON number")

    return json.loads(data, object_pairs_hook=object_pairs, parse_constant=reject_constant)


def payload_components(path):
    if not isinstance(path, str) or not path or len(path.encode()) > 4096 or path.startswith("/") or "\\" in path or "\0" in path:
        raise AppError("附件相对路径无效", "invalidPath")
    parts = path.split("/")
    if parts and parts[0] == "payload":
        parts = parts[1:]
    if not parts or len(parts) > 32:
        raise AppError("附件相对路径越界", "invalidPath")
    for part in parts:
        if not part or part in (".", "..") or len(part.encode()) > 255:
            raise AppError("附件相对路径越界", "invalidPath")
        if (part.endswith((" ", ".")) or part.split(".", 1)[0].upper() in DEVICE_NAMES
                or any(ord(char) < 32 or ord(char) == 127 or char in '<>:"|?*' for char in part)):
            raise AppError("附件相对路径越界", "invalidPath")
    return parts


def _reject_secrets(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).lower() in SECRET_KEYS:
                raise AppError("交接参数不能携带密码或令牌。", "invalid_parameters")
            _reject_secrets(child)
    elif isinstance(value, list):
        for child in value:
            _reject_secrets(child)


def validate_parameters(action, parameters, item_count=0, reference_count=0):
    if item_count or reference_count:
        raise AppError("交接参数无效或包含未支持的字段。", "invalid_parameters")
    if not isinstance(parameters, dict):
        raise AppError("交接参数无效或包含未支持的字段。", "invalid_parameters")
    _reject_secrets(parameters)
    keys = set(parameters)
    if action == "portal.openSite":
        _keys(keys, {"siteID"}, {"browserID"})
        _string(parameters, "siteID", 256, False)
        if "browserID" in parameters:
            _string(parameters, "browserID", 64, False)
    elif action == "portal.openWorkspace":
        _keys(keys, {"workspaceID"}, set())
        _string(parameters, "workspaceID", 256, False)
    elif action == "portal.focusSearch":
        _keys(keys, set(), {"query"})
        if "query" in parameters:
            _string(parameters, "query", 4096, True)
    elif action == "portal.proposeSite":
        _keys(keys, {"url"}, {"title"})
        checked_url(_string(parameters, "url", 8191, False))
        if "title" in parameters:
            _string(parameters, "title", 256, True)
    elif action == "portal.prepareDownload":
        _keys(keys, {"urls"}, set())
        urls = parameters.get("urls")
        if not isinstance(urls, list) or not urls or len(urls) > 32 or any(not isinstance(item, str) for item in urls):
            raise AppError("交接参数无效或包含未支持的字段。", "invalid_parameters")
        for url in urls:
            checked_url(url)
    elif action == "downloads.prepare":
        _keys(keys, {"urls"}, {"mediaType"})
        urls = parameters.get("urls")
        if not isinstance(urls, list) or not urls or len(urls) > 32:
            raise AppError("交接参数无效或包含未支持的字段。", "invalid_parameters")
        for url in urls:
            checked_url(url)
        if "mediaType" in parameters and parameters["mediaType"] != "file":
            raise AppError("只接受文件下载。", "unsupported_media_type")
    else:
        raise AppError("搞门户尚不支持这个交接动作。", "unsupported_action")


def _keys(actual, required, optional):
    if not required.issubset(actual) or not actual.issubset(required | optional):
        raise AppError("交接参数无效或包含未支持的字段。", "invalid_parameters")


def _string(parameters, key, maximum, allow_empty):
    value = parameters.get(key)
    if not isinstance(value, str) or len(value) > maximum or "\0" in value:
        raise AppError("交接参数无效或包含未支持的字段。", "invalid_parameters")
    if not allow_empty and not value.strip():
        raise AppError("交接参数无效或包含未支持的字段。", "invalid_parameters")
    return value


def validate_manifest(data, target_bundle_id=APP_ID, now=None):
    if isinstance(data, (bytes, bytearray)):
        if not data or len(data) > MAX_MANIFEST_BYTES:
            raise AppError("交接清单超出 1 MiB 限制", "manifestTooLarge")
        try:
            manifest = strict_json(data.decode("utf-8"))
        except (UnicodeError, ValueError, RecursionError) as exc:
            raise AppError("交接清单不是有效 JSON", "invalidJSON") from exc
    else:
        manifest = data
    if not isinstance(manifest, dict):
        raise AppError("交接清单必须是对象", "invalidManifest")
    kind = manifest.get("kind")
    if kind not in ("request", "result"):
        raise AppError("不支持的交接类型", "invalidKind")
    expected = RESULT_KEYS if kind == "result" else REQUEST_KEYS
    if set(manifest) != expected:
        raise AppError("交接清单含缺失或不支持的字段", "unknownField")
    if manifest.get("schemaVersion") != 1 or isinstance(manifest.get("schemaVersion"), bool):
        raise AppError("不支持的 GaoAction 版本", "unsupportedSchema")
    manifest_uuid(manifest.get("requestID"))
    if not _valid_bundle(manifest.get("sourceBundleID")) or not _valid_bundle(manifest.get("targetBundleID")) or manifest.get("targetBundleID") != target_bundle_id:
        raise AppError("请求或目标应用标识无效", "invalidIdentity")
    action = manifest.get("action")
    if not isinstance(action, str) or len(action.encode()) > 128 or not ACTION_RE.match(action):
        raise AppError("不支持的动作", "unknownAction")
    created = _parse_date(manifest.get("createdAt"))
    expires = _parse_date(manifest.get("expiresAt"))
    if created is None or expires is None or expires <= created or (expires - created).total_seconds() > MAX_TTL_SECONDS:
        raise AppError("交接有效期必须在 120 秒以内", "invalidTTL")
    now = now or datetime.now(timezone.utc)
    if now < created:
        raise AppError("交接请求尚未生效", "futureRequest")
    if now >= expires:
        raise AppError("交接请求已过期，请重新发送", "expired")
    try:
        nonce = base64.b64decode(manifest.get("nonce") or "", validate=True)
    except Exception as exc:
        raise AppError("交接随机数无效", "invalidNonce") from exc
    if len(nonce) != 32 or base64.b64encode(nonce).decode() != manifest["nonce"]:
        raise AppError("交接随机数无效", "invalidNonce")
    items = manifest.get("items")
    references = manifest.get("references")
    parameters = manifest.get("parameters")
    if not isinstance(items, list) or not isinstance(references, list) or not isinstance(parameters, dict):
        raise AppError("交接项目或参数格式无效", "invalidManifest")
    if len(items) + len(references) > 256:
        raise AppError("交接项目超过 256 项，请分批选择", "tooManyItems")
    if kind == "result":
        manifest_uuid(manifest.get("inReplyTo"))
        if manifest["status"] not in ("pending", "completed", "partial", "failed", "cancelled", "unsupported"):
            raise AppError("交接结果状态无效。", "invalidResult")
        error = manifest["errorCode"]
        if error is not None and (not isinstance(error, str) or not ERROR_RE.fullmatch(error)):
            raise AppError("交接结果错误编号无效。", "invalidResult")
        if not isinstance(manifest["provenance"], dict):
            raise AppError("交接结果来源字段无效。", "invalidResult")
    paths = set()
    item_ids = set()
    total = 0
    for item in items:
        if not isinstance(item, dict) or set(item) != {"id", "relativePath", "uti", "byteCount", "sha256"}:
            raise AppError("文件项目字段无效", "unknownItemField")
        item_id = item["id"]
        if (not isinstance(item_id, str) or not 1 <= len(item_id) <= 256 or not isinstance(item["uti"], str)
                or not 1 <= len(item["uti"]) <= 256 or type(item["byteCount"]) is not int or item["byteCount"] < 0
                or not isinstance(item["sha256"], str) or not HASH_RE.fullmatch(item["sha256"])):
            raise AppError("交接文件项目无效。", "invalidItem")
        normalized = "/".join(payload_components(item["relativePath"])).casefold()
        if normalized in paths or item_id.casefold() in item_ids:
            raise AppError("附件相对路径重复", "duplicatePath")
        paths.add(normalized)
        item_ids.add(item_id.casefold())
        total += item["byteCount"]
    if total > MAX_PAYLOAD_BYTES:
        raise AppError("交接文件超过 2 GiB，请分批选择。", "payloadTooLarge")
    if action.startswith("portal.") and (items or references or (kind == "result" and parameters)):
        raise AppError("网站动作不接受文件或原件引用", "unexpectedPayload")
    if kind == "request" and (action.startswith("portal.") or action == "downloads.prepare"):
        validate_parameters(action, parameters, len(items), len(references))
    return manifest


def plan(action, parameters, library, installed, connected, item_count=0, reference_count=0):
    validate_parameters(action, parameters, item_count, reference_count)
    if action == "portal.openSite":
        site = _unique_site(parameters["siteID"], library)
        if site is None:
            raise AppError("交接引用的网站不存在，请重新选择。", "site_not_found")
        return {"type": "openSite", "launch": site_launch(site, parameters.get("browserID"), installed, connected)}
    if action == "portal.openWorkspace":
        matches = [item for item in library.get("workspaces") or [] if item["id"] == parameters["workspaceID"]]
        if len(matches) != 1:
            raise AppError("交接引用的工作场景不存在或已变化。", "workspace_not_found")
        group = matches[0]
        launches = []
        for site_id in group["siteIDs"]:
            site = _unique_site(site_id, library)
            if site is None:
                raise AppError("交接引用的工作场景不存在或已变化。", "workspace_not_found")
            launches.append(site_launch(site, None, installed, connected))
        return {"type": "openWorkspace", "workspaceID": group["id"], "sites": launches}
    if action == "portal.focusSearch":
        return {"type": "focusSearch", "query": parameters.get("query") or ""}
    if action == "portal.proposeSite":
        return {"type": "proposeSite", "url": parameters["url"], "title": parameters.get("title")}
    if action == "portal.prepareDownload":
        return {"type": "prepareDownload", "urls": [strip_query_and_fragment(url) for url in parameters["urls"]]}
    raise AppError("搞门户尚不支持这个交接动作。", "unsupported_action")


def site_launch(site, requested, installed, connected, account_id=None):
    if not site["allowedBrowsers"] or any(item not in BROWSER_IDS for item in site["allowedBrowsers"]):
        raise AppError("网站的浏览器、账号或登录范围配置无效，请先在搞门户检查。", "invalid_site_configuration")
    if site["defaultBrowser"] not in site["allowedBrowsers"] or not valid_web_url(site["url"]):
        raise AppError("网站的浏览器、账号或登录范围配置无效，请先在搞门户检查。", "invalid_site_configuration")
    accounts = site.get("accounts") or []
    if site.get("defaultAccount") and sum(1 for account in accounts if account["id"] == site["defaultAccount"]) != 1:
        raise AppError("网站的浏览器、账号或登录范围配置无效，请先在搞门户检查。", "invalid_site_configuration")
    if any(normalized_host(host) is None for account in accounts for host in account.get("loginHosts") or []):
        raise AppError("网站的浏览器、账号或登录范围配置无效，请先在搞门户检查。", "invalid_site_configuration")
    browser_id = requested or site["defaultBrowser"]
    if browser_id not in BROWSER_IDS or browser_id not in site["allowedBrowsers"]:
        raise AppError("指定浏览器不在这个网站的允许列表中。", "browser_not_allowed")
    if browser_id not in set(installed):
        raise AppError("指定或默认浏览器未安装，不能改用其他浏览器。", "browser_unavailable")
    profile = (site.get("profiles") or {}).get(browser_id) or None
    connected_profiles = set((connected or {}).get(browser_id) or [])
    if profile and profile not in connected_profiles:
        raise AppError("指定浏览器资料尚未连接，请先打开该资料的搞门户助手。", "profile_unavailable")
    if not profile and len(connected_profiles) > 1:
        raise AppError("已连接多个浏览器资料，请先在搞门户绑定需要使用的资料。", "profile_ambiguous")
    selected = next((account for account in accounts if account["id"] == (account_id or site.get("defaultAccount"))), None)
    if account_id and not selected:
        raise AppError("指定账号不存在，请重新选择。", "account_unavailable")
    if selected and selected.get("hasPassword"):
        if origin_of(site["url"]) is None or not origin_of(site["url"]).startswith("https://"):
            raise AppError("账号填充仅支持准确的 HTTPS 网站与登录域名，请先检查账号配置。", "insecure_login_scope")
        for host in selected.get("loginHosts") or []:
            if "://" in host and not host.lower().startswith("https://"):
                raise AppError("账号填充仅支持准确的 HTTPS 网站与登录域名，请先检查账号配置。", "insecure_login_scope")
    return {
        "siteID": site["id"],
        "browserID": browser_id,
        "profileID": profile or (next(iter(connected_profiles)) if len(connected_profiles) == 1 else None),
        "accountID": selected["id"] if selected else None,
        "requiresAuthentication": bool(selected and selected.get("hasPassword")),
    }


def _unique_site(site_id, library):
    matches = [site for site in library.get("sites") or [] if site["id"] == site_id]
    return matches[0] if len(matches) == 1 else None


def export_site_catalog(library, authorized_ids):
    ids = {site["id"] for site in library["sites"]}
    if len(ids) != len(library["sites"]) or not set(authorized_ids).issubset(ids):
        raise AppError("交接引用的网站不存在，请重新选择。", "site_not_found")
    return {
        "schemaVersion": 1,
        "sites": [{"siteID": site["id"], "displayName": site["name"]} for site in library["sites"] if site["id"] in set(authorized_ids)],
    }


def export_workspace_catalog(library, authorized_ids):
    groups = library.get("workspaces") or []
    ids = {item["id"] for item in groups}
    if not set(authorized_ids).issubset(ids):
        raise AppError("交接引用的工作场景不存在或已变化。", "workspace_not_found")
    return {
        "schemaVersion": 1,
        "workspaces": [{"workspaceID": item["id"], "displayName": item["name"]} for item in groups if item["id"] in set(authorized_ids)],
    }


def make_request(action, parameters, source=APP_ID, target=APP_ID, now=None):
    validate_parameters(action, parameters)
    now = now or datetime.now(timezone.utc)
    expires = now + timedelta(seconds=120)
    manifest = {
        "schemaVersion": 1,
        "kind": "request",
        "requestID": str(uuid.uuid4()),
        "sourceBundleID": source,
        "targetBundleID": target,
        "action": action,
        "createdAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAt": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "nonce": base64.b64encode(os.urandom(32)).decode(),
        "items": [],
        "references": [],
        "parameters": parameters,
    }
    return manifest


def filesystem_entry(path, *, directory=False):
    info = path.lstat()
    mode = stat.S_ISDIR if directory else stat.S_ISREG
    if (not mode(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
            or (not directory and info.st_nlink != 1)):
        raise AppError("交接包包含链接或无效文件。", "unsafeDirectory")
    return info


def package_manifest(directory, now=None, target_bundle_id=APP_ID):
    if not isinstance(directory, (str, os.PathLike)):
        raise AppError("请选择 .gaoaction 交接包。", "invalidPackage")
    directory = Path(directory).absolute()
    if directory.suffix.lower() != ".gaoaction" or ".." in directory.parts or (os.name == "nt" and not re.fullmatch(r"[A-Za-z]:", directory.drive)):
        raise AppError("请选择 .gaoaction 交接包。", "invalidPackage")
    try:
        for parent in (*reversed(directory.parents), directory):
            filesystem_entry(parent, directory=True)
        path = directory / "manifest.json"
        before = filesystem_entry(path)
        if not 0 < before.st_size <= MAX_MANIFEST_BYTES:
            raise AppError("交接清单超出 1 MiB 限制。", "manifestTooLarge")
        with path.open("rb") as source:
            opened = os.fstat(source.fileno())
            data = source.read(MAX_MANIFEST_BYTES + 1)
            after = os.fstat(source.fileno())
        if _file_identity(before) != _file_identity(opened) or _file_identity(opened) != _file_identity(after):
            raise AppError("交接清单已变化。", "package_changed")
        return validate_manifest(data, target_bundle_id, now), data
    except OSError as exc:
        raise AppError("无法安全读取交接包。", "unreadable") from exc


def verify_payload(directory, manifest, copy_to=None):
    directory = Path(directory).absolute()
    payload = directory / "payload"
    declared = {tuple(payload_components(item["relativePath"])): item for item in manifest["items"]}
    required_directories = {relative[:i] for relative in declared for i in range(1, len(relative))}
    try:
        expected_entries = {"manifest.json", "payload"}
        entries = {entry.name for entry in directory.iterdir()}
        if entries != expected_entries and (entries != {"manifest.json"} or declared):
            raise AppError("交接包包含未声明的目录项目。", "unexpectedFile")
        if "payload" not in entries:
            return
        for parent in (*reversed(payload.parents), payload):
            filesystem_entry(parent, directory=True)
        remaining = set(declared)
        stack = [(payload, ())]
        while stack:
            folder, current = stack.pop()
            for entry in folder.iterdir():
                relative = current + (entry.name,)
                if relative in required_directories:
                    filesystem_entry(entry, directory=True)
                    stack.append((entry, relative))
                elif relative in remaining:
                    target = copy_to.joinpath("payload", *relative) if copy_to else None
                    if target:
                        target.parent.mkdir(parents=True, exist_ok=True)
                    _verify_file(entry, declared[relative], target)
                    remaining.remove(relative)
                else:
                    raise AppError("交接包包含未声明的附件。", "unexpectedFile")
        if remaining:
            raise AppError("交接包缺少附件。", "unreadable")
    except OSError as exc:
        raise AppError("无法安全读取交接附件。", "unreadable") from exc


def _file_identity(info):
    return info.st_dev, info.st_ino, info.st_nlink, info.st_size, info.st_mtime_ns


def _verify_file(path, item, copy_to):
    before = filesystem_entry(path)
    if before.st_size != item["byteCount"]:
        raise AppError("交接附件长度与清单不符。", "sizeMismatch")
    digest = hashlib.sha256()
    count = 0
    from contextlib import nullcontext
    with path.open("rb") as source, (copy_to.open("xb") if copy_to else nullcontext()) as target:
        opened = os.fstat(source.fileno())
        if _file_identity(before) != _file_identity(opened):
            raise AppError("交接附件已变化。", "package_changed")
        while chunk := source.read(1024 * 1024):
            count += len(chunk)
            if count > item["byteCount"]:
                raise AppError("交接附件长度与清单不符。", "sizeMismatch")
            digest.update(chunk)
            if target:
                target.write(chunk)
        if target:
            target.flush()
            os.fsync(target.fileno())
        after = os.fstat(source.fileno())
        if _file_identity(before) != _file_identity(after) or count != item["byteCount"] or digest.hexdigest() != item["sha256"].lower():
            raise AppError("交接附件摘要与清单不符。", "hashMismatch")


def read_package(directory: Path, now=None, target_bundle_id=APP_ID):
    manifest, _ = package_manifest(directory, now, target_bundle_id)
    verify_payload(directory, manifest)
    return manifest
