"""合并、恢复、收藏导入、批量整理。不搬动密码，外来账号一律视为没有密码。"""

import json
import uuid
from pathlib import Path

from .errors import AppError
from .models import bookmark_url_key, new_id, valid_web_url, validate_library, visible_site_ids

MAX_BOOKMARK_BYTES = 20_000_000
MAX_BOOKMARK_NODES = 10_000
MAX_BOOKMARK_DEPTH = 30


def merge_library(imported, current):
    return _combine(imported, current, restoring=False)


def restore_library(imported, current):
    return _combine(imported, current, restoring=True)


def _combine(imported, current, restoring):
    imported = validate_library(imported)
    current = validate_library(current)
    result_sites = [dict(site, accounts=[dict(account) for account in site["accounts"]], profiles=dict(site["profiles"])) for site in current["sites"]]
    by_url = {}
    for site in current["sites"]:
        key = bookmark_url_key(site["url"])
        if key and key not in by_url:
            by_url[key] = site["id"]
    used_site_ids = {site["id"] for site in current["sites"]}
    site_map = {}
    added_ids = set()
    restored_ids = set()
    reserved = set()
    current_by_id = {site["id"]: site for site in current["sites"]}
    for incoming in imported["sites"]:
        key = bookmark_url_key(incoming["url"])
        local = current_by_id.get(incoming["id"])
        if local and bookmark_url_key(local["url"]) == key:
            reserved.add(local["id"])
    for original in imported["sites"]:
        key = bookmark_url_key(original["url"])
        existing_id = None
        if restoring:
            local = current_by_id.get(original["id"])
            if local and bookmark_url_key(local["url"]) == key:
                existing_id = local["id"]
            else:
                for site in result_sites:
                    if bookmark_url_key(site["url"]) == key and site["id"] not in restored_ids and site["id"] not in reserved:
                        existing_id = site["id"]
                        break
        else:
            existing_id = by_url.get(key)
        if existing_id is not None:
            site_map[original["id"]] = existing_id
            index = next(i for i, site in enumerate(result_sites) if site["id"] == existing_id)
            if restoring and existing_id not in restored_ids:
                restored_ids.add(existing_id)
                local = result_sites[index]
                site = dict(original)
                site["id"] = existing_id
                accounts, id_map = _restored_accounts(original["accounts"], local["accounts"])
                site["accounts"] = accounts
                original_default = original.get("defaultAccount")
                site["defaultAccount"] = id_map.get(original_default) or local.get("defaultAccount") or (accounts[0]["id"] if accounts else None)
                if site.get("defaultAccount") is None:
                    site.pop("defaultAccount", None)
                site["profiles"] = dict(local["profiles"])
                result_sites[index] = site
            else:
                accounts, _id_map = _restored_accounts(original["accounts"], result_sites[index]["accounts"])
                result_sites[index]["accounts"] = accounts
            continue
        site = dict(original)
        site["id"] = str(uuid.uuid4())
        while site["id"] in used_site_ids:
            site["id"] = str(uuid.uuid4())
        used_site_ids.add(site["id"])
        original_default = original.get("defaultAccount")
        mapped_accounts = []
        default_id = None
        for account in original["accounts"]:
            copy = dict(account)
            copy["id"] = str(uuid.uuid4())
            copy["hasPassword"] = False
            if account["id"] == original_default:
                default_id = copy["id"]
            mapped_accounts.append(copy)
        site["accounts"] = mapped_accounts
        if default_id:
            site["defaultAccount"] = default_id
        else:
            site.pop("defaultAccount", None)
        site["profiles"] = {}
        result_sites.append(site)
        site_map[original["id"]] = site["id"]
        by_url[key] = site["id"]
        added_ids.add(site["id"])
        restored_ids.add(site["id"])

    seen = set() if restoring else set(visible_site_ids(current["tiles"]))
    used_tile_ids = {site["id"] for site in result_sites}
    if not restoring:
        used_tile_ids.update(tile["id"] for tile in current["tiles"])
    mapped_tiles = []
    for tile in imported["tiles"]:
        source_ids = tile["children"] if tile["kind"] == "folder" else [tile["id"]]
        children = []
        for source_id in source_ids:
            mapped = site_map.get(source_id)
            if not mapped:
                continue
            if not restoring and mapped not in added_ids:
                continue
            if mapped in seen:
                continue
            seen.add(mapped)
            children.append(mapped)
        if not children:
            continue
        if tile["kind"] == "site":
            mapped_tiles.append({"id": children[0], "kind": "site"})
        else:
            folder_id = tile["id"]
            if folder_id in used_tile_ids:
                folder_id = str(uuid.uuid4())
            used_tile_ids.add(folder_id)
            mapped_tiles.append({"id": folder_id, "kind": "folder", "name": tile.get("name") or "文件夹", "children": children})
    library = {
        "schema": 1,
        "sites": result_sites,
        "tiles": mapped_tiles if restoring else list(current["tiles"]) + mapped_tiles,
        "appearance": imported["appearance"] if restoring else current["appearance"],
    }
    if restoring:
        if imported.get("layoutDensity"):
            library["layoutDensity"] = imported["layoutDensity"]
        if imported.get("iconSize"):
            library["iconSize"] = imported["iconSize"]
    else:
        if current.get("layoutDensity"):
            library["layoutDensity"] = current["layoutDensity"]
        if current.get("iconSize"):
            library["iconSize"] = current["iconSize"]
    workspaces = [] if restoring else [dict(item) for item in (current.get("workspaces") or [])]
    workspace_ids = {item["id"] for item in workspaces}
    for original in imported.get("workspaces") or []:
        unique = []
        seen_ws = set()
        for site_id in original["siteIDs"]:
            mapped = site_map.get(site_id)
            if mapped and mapped not in seen_ws:
                seen_ws.add(mapped)
                unique.append(mapped)
        if not unique:
            continue
        if not restoring and any(item["name"] == original["name"] and item["siteIDs"] == unique for item in workspaces):
            continue
        workspace_id = original["id"]
        if workspace_id in workspace_ids:
            workspace_id = str(uuid.uuid4())
        workspace_ids.add(workspace_id)
        workspaces.append({"id": workspace_id, "name": original["name"], "siteIDs": unique})
    if workspaces:
        library["workspaces"] = workspaces
    return validate_library(library)


def _restored_accounts(imported, local):
    result = []
    id_map = {}
    retained = set()
    for account in imported:
        current = next((item for item in local if item["id"] == account["id"]), None)
        if current is None:
            current = next((item for item in local if not item["hasPassword"] and item["username"] == account["username"] and item["label"] == account["label"] and item["loginHosts"] == account["loginHosts"]), None)
        if current is not None:
            if current["id"] not in retained:
                retained.add(current["id"])
                result.append(dict(current))
            id_map[account["id"]] = current["id"]
        else:
            copy = dict(account)
            copy["id"] = str(uuid.uuid4())
            copy["hasPassword"] = False
            result.append(copy)
            id_map[account["id"]] = copy["id"]
    for account in local:
        if account["id"] not in retained:
            result.append(dict(account))
    return result, id_map


def remove_from_tiles(site_id, tiles):
    result = []
    for tile in tiles:
        if tile["kind"] == "site":
            if tile["id"] != site_id:
                result.append(tile)
        else:
            children = [child for child in tile.get("children") or [] if child != site_id]
            if children:
                result.append({"id": tile["id"], "kind": "folder", "name": tile.get("name") or "文件夹", "children": children})
    return result


def organization_state(library):
    browsers = {site["id"]: {"allowed": list(site["allowedBrowsers"]), "standard": site["defaultBrowser"]} for site in library["sites"]}
    return {"tiles": library["tiles"], "browsers": browsers}


def apply_organization(library, state):
    library = validate_library(library)
    library["tiles"] = state["tiles"]
    for site in library["sites"]:
        choice = state["browsers"].get(site["id"])
        if choice:
            site["allowedBrowsers"] = list(choice["allowed"])
            site["defaultBrowser"] = choice["standard"]
    return validate_library(library)


class OrganizationHistory:
    def __init__(self):
        self.entries = []

    def push(self, before, after):
        if before == after:
            return
        self.entries.append({"before": before, "after": after})
        if len(self.entries) > 30:
            self.entries.pop(0)

    def undo(self, library):
        if not self.entries:
            raise AppError("没有可以撤销的整理操作。")
        edit = self.entries[-1]
        if organization_state(library) != edit["after"]:
            self.entries.clear()
            raise AppError("网站数据已发生其他变化，请撤销最近的其他整理或手动调整排列。")
        self.entries.pop()
        return apply_organization(library, edit["before"])


def batch_edit(library, site_ids, operation, browser=None, folder_id=None, folder_name=None):
    library = validate_library(library)
    if not site_ids or len(site_ids) != len(set(site_ids)):
        raise AppError("请先选择网站。")
    visible = set(visible_site_ids(library["tiles"]))
    if not set(site_ids).issubset(visible):
        raise AppError("选中的网站已变化，请重新选择。")
    tiles = list(library["tiles"])
    sites = [dict(site) for site in library["sites"]]
    if operation == "remove":
        for site_id in site_ids:
            tiles = remove_from_tiles(site_id, tiles)
    elif operation == "browser":
        if browser not in ("chrome", "edge", "safari", "firefox"):
            raise AppError("请选择有效浏览器。")
        chosen = [site for site in sites if site["id"] in set(site_ids)]
        if not all(browser in site["allowedBrowsers"] for site in chosen):
            raise AppError("这个浏览器未被所有选中网站允许，请先分别修改网站的允许浏览器。")
        for site in sites:
            if site["id"] in set(site_ids):
                site["defaultBrowser"] = browser
    elif operation == "move":
        target = None
        if folder_id:
            target = next((tile for tile in tiles if tile["kind"] == "folder" and tile["id"] == folder_id), None)
            if target is None:
                raise AppError("目标文件夹不存在。")
            target = {"id": target["id"], "kind": "folder", "name": target.get("name"), "children": list(target.get("children") or [])}
        elif folder_name and folder_name.strip():
            name = folder_name.strip()
            if len(name) > 60:
                raise AppError("文件夹名称最多 60 个字。")
            target = {"id": new_id(), "kind": "folder", "name": name, "children": []}
        ordered = [site_id for site_id in visible_site_ids(tiles) if site_id in set(site_ids)]
        for site_id in site_ids:
            tiles = remove_from_tiles(site_id, tiles)
        if target is not None:
            target["children"] = [child for child in target["children"] if child not in set(site_ids)] + ordered
            index = next((i for i, tile in enumerate(tiles) if tile["id"] == target["id"]), None)
            if index is None:
                tiles.append(target)
            else:
                tiles[index] = target
        else:
            tiles.extend({"id": site_id, "kind": "site"} for site_id in ordered)
    else:
        raise AppError("不支持这个批量操作。")
    updated = dict(library)
    updated["sites"] = sites
    updated["tiles"] = tiles
    return validate_library(updated)


def browser_roots(home: Path):
    local = home / "AppData" / "Local"
    return {
        "chrome": local / "Google" / "Chrome" / "User Data",
        "edge": local / "Microsoft" / "Edge" / "User Data",
    }


def bookmark_sources(home: Path):
    result = []
    for browser_id, root in browser_roots(home).items():
        if not root.is_dir():
            continue
        names = {}
        local_state = root / "Local State"
        if local_state.is_file() and local_state.stat().st_size <= MAX_BOOKMARK_BYTES:
            try:
                state = json.loads(local_state.read_text(encoding="utf-8"))
                cache = ((state.get("profile") or {}).get("info_cache") or {})
                if isinstance(cache, dict):
                    for key, value in cache.items():
                        if isinstance(value, dict) and isinstance(value.get("name"), str):
                            names[key] = value["name"]
            except (OSError, json.JSONDecodeError):
                names = {}
        profiles = sorted(path.name for path in root.iterdir() if path.is_dir())
        for profile in profiles:
            if profile != "Default" and not profile.startswith("Profile "):
                continue
            if not (root / profile / "Bookmarks").is_file():
                continue
            label = "Edge" if browser_id == "edge" else "Chrome"
            result.append({
                "id": browser_id + ":" + profile,
                "browserID": browser_id,
                "profile": profile,
                "name": label + " · " + names.get(profile, profile),
            })
    return result


def _parse_bookmarks(data):
    try:
        document = json.loads(data)
    except json.JSONDecodeError as exc:
        raise AppError("浏览器收藏格式无效。") from exc
    roots = document.get("roots") if isinstance(document, dict) else None
    if not isinstance(roots, dict):
        raise AppError("浏览器收藏格式无效。")
    count = {"n": 0}
    skipped = {"n": 0}

    def parse(item, node_id, depth):
        count["n"] += 1
        if count["n"] > MAX_BOOKMARK_NODES or depth > MAX_BOOKMARK_DEPTH:
            raise AppError("收藏目录过大或嵌套过深。")
        if not isinstance(item, dict):
            skipped["n"] += 1
            return None
        name = item.get("name") if isinstance(item.get("name"), str) else ""
        if item.get("type") == "url":
            url = item.get("url")
            if not isinstance(url, str) or not valid_web_url(url):
                skipped["n"] += 1
                return None
            return {"id": node_id, "name": name, "url": url, "children": []}
        if item.get("type") == "folder" and isinstance(item.get("children"), list):
            children = []
            for index, child in enumerate(item["children"]):
                node = parse(child, node_id + "/" + str(index), depth + 1)
                if node:
                    children.append(node)
            return {"id": node_id, "name": name, "url": None, "children": children}
        skipped["n"] += 1
        return None

    order = ["bookmark_bar", "other", "synced"] + sorted(key for key in roots if key not in ("bookmark_bar", "other", "synced"))
    nodes = []
    for key in order:
        item = roots.get(key)
        if isinstance(item, dict):
            node = parse(item, key, 0)
            if node:
                nodes.append(node)
    return nodes, skipped["n"]


def _flattened(node):
    result = [node]
    for child in node["children"]:
        result.extend(_flattened(child))
    return result


def _folder_count(node):
    total = 0
    for child in node["children"]:
        if child["url"] is None:
            total += 1
        total += _folder_count(child)
    return total


def read_bookmark_source(home: Path, source_id):
    source = next((item for item in bookmark_sources(home) if item["id"] == source_id), None)
    if source is None:
        raise AppError("找不到该浏览器收藏，请重新选择。")
    path = browser_roots(home)[source["browserID"]] / source["profile"] / "Bookmarks"
    if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_BOOKMARK_BYTES:
        raise AppError("浏览器收藏文件无法安全读取。")
    nodes, skipped = _parse_bookmarks(path.read_bytes())
    return source, nodes, skipped


def preview_bookmarks(home: Path, source_id, library):
    library = validate_library(library)
    source, nodes, skipped = read_bookmark_source(home, source_id)
    known = {bookmark_url_key(site["url"]) for site in library["sites"]}
    known.discard(None)

    def group(node, seen):
        urls = [item["url"] for item in _flattened(node) if item["url"]]
        local = set(seen)
        duplicates = 0
        for url in urls:
            key = bookmark_url_key(url)
            if key in local:
                duplicates += 1
            else:
                local.add(key)
        children = []
        for child in node["children"]:
            if child["url"] is None:
                children.append(group(child, known))
        return {
            "id": node["id"],
            "name": node["name"],
            "siteCount": len(urls),
            "folderCount": _folder_count(node),
            "duplicateCount": duplicates,
            "children": children,
        }

    roots = [group(node, known) for node in nodes]
    return {
        "source": source,
        "roots": roots,
        "siteCount": sum(item["siteCount"] for item in roots),
        "folderCount": sum(item["folderCount"] for item in roots),
        "duplicateCount": sum(item["duplicateCount"] for item in roots),
        "skippedCount": skipped,
    }


def import_bookmarks(home: Path, source_id, root_ids, library):
    library = validate_library(library)
    if not root_ids:
        raise AppError("请选择要导入的收藏目录。")
    source, nodes, _skipped = read_bookmark_source(home, source_id)
    folders = [item["id"] for node in nodes for item in _flattened(node) if item["url"] is None]
    if any(root_id not in folders for root_id in root_ids):
        raise AppError("收藏目录已变化，请重新预览。")
    selected = set(root_ids)
    next_library = validate_library(library)
    seen = {bookmark_url_key(site["url"]) for site in next_library["sites"]}
    seen.discard(None)
    groups = []

    def append(node, path, folder_id, active):
        now = active or node["id"] in selected
        if node["url"]:
            key = bookmark_url_key(node["url"])
            if not now or not key or key in seen:
                return
            seen.add(key)
            site_id = new_id()
            raw_name = node["name"] or (node["url"].split("/")[2] if "://" in node["url"] else "网站")
            site = {
                "id": site_id,
                "name": raw_name[:100] or "网站",
                "url": node["url"],
                "color": "#6F87B3",
                "allowedBrowsers": [source["browserID"]],
                "defaultBrowser": source["browserID"],
                "accounts": [],
                "profiles": {},
            }
            next_library["sites"].append(site)
            name = None if not path else " / ".join(path)[:120]
            if folder_id and any(group["id"] == folder_id for group in groups):
                next(group for group in groups if group["id"] == folder_id)["sites"].append(site_id)
            elif folder_id is None and groups and groups[-1]["id"] is None:
                groups[-1]["sites"].append(site_id)
            else:
                groups.append({"id": folder_id, "name": name, "sites": [site_id]})
            return
        is_root = any(item["id"] == node["id"] for item in nodes)
        next_path = path if is_root else path + [node["name"] or "未命名文件夹"]
        for child in node["children"]:
            append(child, next_path, None if is_root else node["id"], now)

    for root in nodes:
        append(root, [], None, False)
    for group in groups:
        if group["name"]:
            next_library["tiles"].append({"id": new_id(), "kind": "folder", "name": group["name"], "children": group["sites"]})
        else:
            next_library["tiles"].extend({"id": site_id, "kind": "site"} for site_id in group["sites"])
    return validate_library(next_library)


def save_browser_bookmark(library, url, title, browser, profile_id, folder_id=None):
    library = validate_library(library)
    if browser not in ("chrome", "edge"):
        raise AppError("只能从 Chrome 或 Edge 助手收藏。")
    if not valid_web_url(url):
        raise AppError("当前页面不能收藏，请打开普通网页。")
    key = bookmark_url_key(url)
    if folder_id and not any(tile["id"] == folder_id and tile["kind"] == "folder" for tile in library["tiles"]):
        raise AppError("文件夹已变化，请重新选择。")
    existing = next((site for site in library["sites"] if bookmark_url_key(site["url"]) == key), None)
    if existing:
        if existing["id"] not in set(visible_site_ids(library["tiles"])):
            if folder_id:
                for tile in library["tiles"]:
                    if tile["id"] == folder_id:
                        tile["children"].append(existing["id"])
            else:
                library["tiles"].append({"id": existing["id"], "kind": "site"})
            return validate_library(library), "已恢复这个网站入口，原有账号和浏览器设置已保留。"
        return library, f"这个网址已保存在「{existing['name']}」中。"
    name = (title or "").strip()[:100] or urlsplit_host(url)
    site = {
        "id": new_id(),
        "name": name,
        "url": url,
        "color": "#537CE6",
        "allowedBrowsers": [browser],
        "defaultBrowser": browser,
        "accounts": [],
        "profiles": {browser: profile_id},
    }
    library["sites"].append(site)
    if folder_id:
        for tile in library["tiles"]:
            if tile["id"] == folder_id:
                tile["children"].append(site["id"])
    else:
        library["tiles"].append({"id": site["id"], "kind": "site"})
    return validate_library(library), "已收藏。"


def urlsplit_host(url):
    from urllib.parse import urlsplit
    return urlsplit(url).hostname or "新网站"
