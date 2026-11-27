"""GaoAction V1 与搞门户动作规划。portal.* 不接受附件，参数里不能带密码。"""

import base64
import json
import os
import re
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import APP_ID
from .errors import AppError
from .models import BROWSER_IDS, checked_url, normalized_host, origin_of, strip_query_and_fragment, valid_web_url

MAX_MANIFEST_BYTES = 1_048_576
MAX_TTL_SECONDS = 120
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
            return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _valid_bundle(value):
    return isinstance(value, str) and len(value.encode()) <= 255 and BUNDLE_RE.match(value) is not None


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
        if any(ord(char) < 32 or ord(char) == 127 for char in part):
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
            manifest = json.loads(data.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
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
    try:
        uuid.UUID(str(manifest.get("requestID")))
    except (ValueError, TypeError, AttributeError) as exc:
        raise AppError("请求或目标应用标识无效", "invalidIdentity") from exc
    if not _valid_bundle(manifest.get("sourceBundleID")) or manifest.get("targetBundleID") != target_bundle_id:
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
    paths = set()
    for item in items:
        if not isinstance(item, dict) or set(item) != {"id", "relativePath", "uti", "byteCount", "sha256"}:
            raise AppError("文件项目字段无效", "unknownItemField")
        normalized = "/".join(payload_components(item["relativePath"]))
        if normalized in paths:
            raise AppError("交接文件路径重复", "duplicatePath")
        paths.add(normalized)
    if action.startswith("portal.") and (items or references):
        raise AppError("网站动作不接受文件或原件引用", "unexpectedPayload")
    if action.startswith("portal.") or action == "downloads.prepare":
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


def read_package(directory: Path, now=None):
    directory = Path(directory)
    if directory.suffix.lower() != ".gaoaction" or not directory.is_dir():
        raise AppError("请选择 .gaoaction 交接包", "invalidPackage")
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise AppError("无法安全读取交接文件", "unreadable")
    data = manifest_path.read_bytes()
    manifest = validate_manifest(data, now=now)
    payload = directory / "payload"
    if manifest.get("items"):
        if not payload.is_dir():
            raise AppError("交接目录不可读或包含链接", "unsafeDirectory")
        for item in manifest["items"]:
            relative = Path(*payload_components(item["relativePath"]))
            target = payload / relative
            if not target.is_file() or target.is_symlink():
                raise AppError("无法安全读取交接文件", "unreadable")
            resolved = target.resolve()
            if payload.resolve() not in resolved.parents:
                raise AppError("附件相对路径越界", "invalidPath")
    return manifest
