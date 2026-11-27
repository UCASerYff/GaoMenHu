"""网站资料 schema 1。未知字段在读入时丢弃，与 Mac 版 Codable 行为一致。"""

import json
import uuid
from urllib.parse import urlsplit, urlunsplit

from .errors import AppError

SCHEMA = 1
MAX_SITES = 5000
MAX_TILES = 5000
MAX_ACCOUNTS = 100
MAX_WORKSPACES = 100
MAX_LIBRARY_BYTES = 30_000_000
BROWSER_IDS = ("chrome", "edge", "safari", "firefox")
BROWSERS = (
    {"id": "chrome", "name": "Chrome", "supportsFill": True},
    {"id": "edge", "name": "Edge", "supportsFill": True},
    {"id": "safari", "name": "Safari", "supportsFill": False},
    {"id": "firefox", "name": "Firefox", "supportsFill": False},
)
SEED_SITES = (
    ("Claude", "https://claude.ai", "#D97757"),
    ("ChatGPT", "https://chatgpt.com", "#248977"),
    ("Gemini", "https://gemini.google.com", "#537CE6"),
    ("GitHub", "https://github.com", "#35384B"),
    ("哔哩哔哩", "https://www.bilibili.com", "#ED83A7"),
    ("飞书", "https://www.feishu.cn", "#3F79EA"),
)


def browser_by_id(browser_id):
    for browser in BROWSERS:
        if browser["id"] == browser_id:
            return browser
    return None


def valid_web_url(value):
    if not isinstance(value, str) or not value or len(value) >= 8192:
        return False
    if any(ord(ch) < 32 for ch in value):
        return False
    try:
        parts = urlsplit(value)
    except ValueError:
        return False
    if parts.scheme.lower() not in ("http", "https") or not parts.hostname:
        return False
    return not (parts.username or parts.password)


def normalized_host(value):
    if not isinstance(value, str):
        return None
    text = value.strip().lower()
    if not text or "*" in text or " " in text:
        return None
    source = text if "://" in text else "https://" + text
    if not valid_web_url(source):
        return None
    parts = urlsplit(source)
    try:
        if parts.port is not None:
            return None
    except ValueError:
        return None
    if parts.path not in ("", "/") or parts.query or parts.fragment:
        return None
    host = parts.hostname.lower()
    if "*" in host or " " in host or "\\" in host:
        return None
    return host


def origin_of(value):
    if not valid_web_url(value):
        return None
    parts = urlsplit(value)
    scheme = parts.scheme.lower()
    host = parts.hostname.lower()
    port = parts.port
    if port is None or (scheme == "https" and port == 443) or (scheme == "http" and port == 80):
        suffix = ""
    else:
        suffix = ":" + str(port)
    return f"{scheme}://{host}{suffix}"


def bookmark_url_key(value):
    if not valid_web_url(value):
        return None
    parts = urlsplit(value)
    scheme = parts.scheme.lower()
    host = (parts.hostname or "").lower()
    port = parts.port
    if (scheme == "https" and port == 443) or (scheme == "http" and port == 80):
        port = None
    netloc = host if port is None else f"{host}:{port}"
    path = parts.path or "/"
    return urlunsplit((scheme, netloc, path, parts.query, parts.fragment))


def checked_url(value):
    if not isinstance(value, str) or not value or len(value) >= 8192:
        raise AppError("仅接受不含账号密码的完整 HTTP 或 HTTPS 网址。", "invalid_url")
    if any(ch.isspace() or ord(ch) < 32 for ch in value):
        raise AppError("仅接受不含账号密码的完整 HTTP 或 HTTPS 网址。", "invalid_url")
    if not _valid_percent_escapes(value):
        raise AppError("仅接受不含账号密码的完整 HTTP 或 HTTPS 网址。", "invalid_url")
    parts = urlsplit(value)
    host = parts.hostname or ""
    if "*" in host or "\\" in host or parts.username or parts.password:
        raise AppError("仅接受不含账号密码的完整 HTTP 或 HTTPS 网址。", "invalid_url")
    if not valid_web_url(value):
        raise AppError("仅接受不含账号密码的完整 HTTP 或 HTTPS 网址。", "invalid_url")
    return value


def _valid_percent_escapes(value):
    data = value.encode("utf-8", "surrogateescape")
    index = 0
    while index < len(data):
        if data[index] == 37:
            if index + 2 >= len(data):
                return False
            if not all(chr(data[index + offset]).lower() in "0123456789abcdef" for offset in (1, 2)):
                return False
        index += 1
    return True


def strip_query_and_fragment(value):
    raw = checked_url(value)
    parts = urlsplit(raw)
    review = bool(parts.query or parts.fragment)
    bare = urlunsplit((parts.scheme, parts.netloc, parts.path or "/", "", ""))
    return {"url": raw, "withoutQueryAndFragment": bare, "requiresPrivacyReview": review}


def redacted_download_url(value):
    parts = urlsplit(value)
    host = parts.hostname or ""
    port = parts.port
    netloc = host if not port else f"{host}:{port}"
    return urlunsplit((parts.scheme, netloc, parts.path or "/", "", ""))


def _text(value, limit, label):
    if not isinstance(value, str):
        raise AppError(label)
    stripped = value.strip()
    if not stripped or len(stripped) > limit:
        raise AppError(label)
    return stripped


def validate_account(account, seen_ids):
    if not isinstance(account, dict):
        raise AppError("账号或登录域名配置无效。")
    if "password" in account or "secret" in account or "token" in account:
        raise AppError("密码不能写入网站资料。")
    account_id = account.get("id")
    if not isinstance(account_id, str) or not account_id or account_id in seen_ids:
        raise AppError("账号或登录域名配置无效。")
    seen_ids.add(account_id)
    hosts = account.get("loginHosts", [])
    if not isinstance(hosts, list) or any(normalized_host(host) is None for host in hosts):
        raise AppError("账号或登录域名配置无效。")
    if not isinstance(account.get("label", ""), str) or not isinstance(account.get("username", ""), str):
        raise AppError("账号或登录域名配置无效。")
    if not isinstance(account.get("hasPassword"), bool):
        raise AppError("账号或登录域名配置无效。")
    return {
        "id": account_id,
        "label": account.get("label", ""),
        "username": account.get("username", ""),
        "loginHosts": list(hosts),
        "hasPassword": account["hasPassword"],
    }


def validate_site(site, seen_accounts):
    if not isinstance(site, dict):
        raise AppError("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
    site_id = site.get("id")
    if not isinstance(site_id, str) or not site_id:
        raise AppError("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
    name = site.get("name")
    if not isinstance(name, str) or not name.strip() or len(name) > 100:
        raise AppError("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
    aliases = site.get("aliases")
    if aliases is not None and (not isinstance(aliases, str) or len(aliases) > 500):
        raise AppError("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
    if not valid_web_url(site.get("url", "")):
        raise AppError("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
    allowed = site.get("allowedBrowsers")
    if not isinstance(allowed, list) or not allowed or any(item not in BROWSER_IDS for item in allowed):
        raise AppError("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
    if site.get("defaultBrowser") not in allowed:
        raise AppError("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
    accounts = site.get("accounts", [])
    if not isinstance(accounts, list) or len(accounts) > MAX_ACCOUNTS:
        raise AppError("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
    clean_accounts = [validate_account(account, seen_accounts) for account in accounts]
    default_account = site.get("defaultAccount")
    if default_account is not None and default_account not in {account["id"] for account in clean_accounts}:
        raise AppError("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
    profiles = site.get("profiles", {})
    if not isinstance(profiles, dict) or any(not isinstance(key, str) or not isinstance(val, str) for key, val in profiles.items()):
        raise AppError("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
    icon_source = site.get("iconSource")
    if icon_source not in (None, "website", "custom"):
        raise AppError("网站配置无效：请填写名称、网址，并选择至少一个浏览器。")
    cleaned = {
        "id": site_id,
        "name": name,
        "url": site["url"],
        "color": site.get("color") if isinstance(site.get("color"), str) else "#537CE6",
        "allowedBrowsers": list(allowed),
        "defaultBrowser": site["defaultBrowser"],
        "accounts": clean_accounts,
        "profiles": dict(profiles),
    }
    for key in ("icon", "defaultAccount", "iconSource", "iconRevision", "iconSourcePixels", "iconCheckedAt", "aliases"):
        if site.get(key) is not None:
            cleaned[key] = site[key]
    return cleaned


def validate_library(library):
    if not isinstance(library, dict):
        raise AppError("数据格式不受支持。")
    if library.get("schema") != SCHEMA:
        raise AppError("数据格式不受支持。")
    sites = library.get("sites")
    tiles = library.get("tiles")
    if not isinstance(sites, list) or not isinstance(tiles, list):
        raise AppError("数据格式不受支持。")
    if len(sites) > MAX_SITES or len(tiles) > MAX_TILES:
        raise AppError("数据格式不受支持。")
    density = library.get("layoutDensity")
    icon_size = library.get("iconSize")
    if density not in (None, "compact", "comfortable"):
        raise AppError("启动台布局设置无效。")
    if icon_size not in (None, 60, 76, 92):
        raise AppError("启动台布局设置无效。")
    appearance = library.get("appearance", "system")
    if appearance not in ("system", "light", "dark"):
        raise AppError("启动台布局设置无效。")
    seen_accounts = set()
    clean_sites = []
    site_ids = []
    for site in sites:
        clean = validate_site(site, seen_accounts)
        if clean["id"] in site_ids:
            raise AppError("网站编号重复。")
        site_ids.append(clean["id"])
        clean_sites.append(clean)
    id_set = set(site_ids)
    seen_children = set()
    tile_ids = set()
    clean_tiles = []
    for tile in tiles:
        if not isinstance(tile, dict):
            raise AppError("图标类型无效。")
        tile_id = tile.get("id")
        kind = tile.get("kind")
        if not isinstance(tile_id, str) or not tile_id or tile_id in tile_ids:
            raise AppError("图标编号重复。")
        tile_ids.add(tile_id)
        if kind == "site":
            if tile_id not in id_set or tile_id in seen_children:
                raise AppError("网站排列重复。")
            seen_children.add(tile_id)
            clean_tiles.append({"id": tile_id, "kind": "site"})
        elif kind == "folder":
            name = tile.get("name")
            children = tile.get("children")
            if tile_id in id_set or not isinstance(name, str) or not name or not isinstance(children, list) or not children:
                raise AppError("文件夹配置无效。")
            for child in children:
                if child not in id_set or child in seen_children:
                    raise AppError("文件夹内的网站排列重复。")
                seen_children.add(child)
            clean_tiles.append({"id": tile_id, "kind": "folder", "name": name, "children": list(children)})
        else:
            raise AppError("图标类型无效。")
    workspaces = library.get("workspaces")
    clean_workspaces = None
    if workspaces is not None:
        if not isinstance(workspaces, list) or len(workspaces) > MAX_WORKSPACES:
            raise AppError("工作场景不能超过 100 个。")
        clean_workspaces = []
        seen_ws = set()
        for workspace in workspaces:
            if not isinstance(workspace, dict):
                raise AppError("工作场景配置无效：每组请选择 1 至 20 个网站。")
            ws_id = workspace.get("id")
            name = workspace.get("name")
            site_list = workspace.get("siteIDs")
            if not isinstance(ws_id, str) or not ws_id or ws_id in seen_ws:
                raise AppError("工作场景配置无效：每组请选择 1 至 20 个网站。")
            if not isinstance(name, str) or not name.strip() or len(name) > 60:
                raise AppError("工作场景配置无效：每组请选择 1 至 20 个网站。")
            if not isinstance(site_list, list) or not site_list or len(site_list) > 20 or len(set(site_list)) != len(site_list):
                raise AppError("工作场景配置无效：每组请选择 1 至 20 个网站。")
            if any(item not in id_set for item in site_list):
                raise AppError("工作场景配置无效：每组请选择 1 至 20 个网站。")
            seen_ws.add(ws_id)
            clean_workspaces.append({"id": ws_id, "name": name.strip(), "siteIDs": list(site_list)})
        if not clean_workspaces:
            clean_workspaces = None
    result = {
        "schema": SCHEMA,
        "sites": clean_sites,
        "tiles": clean_tiles,
        "appearance": appearance,
    }
    if density is not None:
        result["layoutDensity"] = density
    if icon_size is not None:
        result["iconSize"] = icon_size
    if clean_workspaces is not None:
        result["workspaces"] = clean_workspaces
    return result


def encode_library(library):
    cleaned = validate_library(library)
    data = json.dumps(cleaned, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    if len(data) > MAX_LIBRARY_BYTES:
        raise AppError("资料过大：单个文件最多 30 MB。")
    return data


def decode_library(data):
    if not isinstance(data, (bytes, bytearray)) or len(data) > MAX_LIBRARY_BYTES:
        raise AppError("数据格式不受支持。")
    try:
        raw = json.loads(data.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise AppError("数据格式不受支持。") from exc
    return validate_library(raw)


def initial_library(browsers):
    choices = [item for item in browsers if item in BROWSER_IDS]
    if not choices:
        choices = ["chrome", "edge", "firefox"]
    standard = "chrome" if "chrome" in choices else choices[0]
    sites = []
    for index, (name, url, color) in enumerate(SEED_SITES):
        allowed = ["chrome"] if name == "Claude" and "chrome" in choices else list(choices)
        default = standard if standard in allowed else allowed[0]
        sites.append({
            "id": f"seed-{index}",
            "name": name,
            "url": url,
            "color": color,
            "allowedBrowsers": allowed,
            "defaultBrowser": default,
            "accounts": [],
            "profiles": {},
        })
    tiles = [{"id": site["id"], "kind": "site"} for site in sites]
    return validate_library({"schema": SCHEMA, "sites": sites, "tiles": tiles, "appearance": "system"})


def new_id():
    return str(uuid.uuid4())


def visible_site_ids(tiles):
    result = []
    for tile in tiles:
        if tile.get("kind") == "site":
            result.append(tile["id"])
        elif tile.get("kind") == "folder":
            result.extend(tile.get("children") or [])
    return result


def public_library(library):
    """State sent to the page. Passwords are never present; hasPassword stays."""
    return validate_library(library)
