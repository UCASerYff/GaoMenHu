"""本机业务入口。网页、测试和浏览器助手都调用这里。"""

import copy
import json
import secrets
import time
import uuid
from pathlib import Path

from . import VERSION_LABEL
from .actions import (
    export_site_catalog,
    export_workspace_catalog,
    plan,
    read_package,
    site_launch,
    validate_manifest,
)
from .browsers import installed_browsers, launch_browser
from .downloads import DownloadManager
from .errors import AppError, RecoveryError
from .mail import MailStore, extract_codes, generate_aliases, make_service_alias, primary_code, sanitize_mail_html
from .transport import fetch_inbox, send_mail
from .models import new_id, validate_library, visible_site_ids
from .operations import (
    OrganizationHistory,
    batch_edit,
    bookmark_sources,
    import_bookmarks,
    merge_library,
    organization_state,
    preview_bookmarks,
    remove_from_tiles,
    restore_library,
    save_browser_bookmark,
)
from .search import floating_sites, record_launch, search_key
from .store import LibraryStore
from .vault import mail_vault, site_vault


class PortalService:
    def __init__(self, data_dir, browser_probe=None, launcher=None, clock=None):
        self.data_dir = Path(data_dir)
        self.browser_probe = browser_probe or (lambda: [item["id"] for item in installed_browsers()])
        self.launcher = launcher if launcher is not None else launch_browser
        self.clock = clock or time.time
        self.store = LibraryStore(self.data_dir)
        self.vault = site_vault(self.data_dir)
        self.mail_vault = mail_vault(self.data_dir / "MailCenter")
        self.downloads = None
        self.mail = None
        self.history = OrganizationHistory()
        self.pending = {}
        self.usage = self._load_usage()
        self.profiles = {}
        self.launches = {}
        self.focus_query = ""
        self.proposal = None
        self.launch_log = []
        self.page_token = secrets.token_urlsafe(24)
        self.host_token = secrets.token_urlsafe(24)
        self.store.load(self._installed())

    def create_library(self):
        self.store.create(self._installed())
        return self.state()

    def state(self):
        library = self.store.library
        keys = {}
        if library:
            keys = {site["id"]: search_key(site) for site in library["sites"]}
        return {
            "ok": True,
            "version": VERSION_LABEL,
            "access": self.store.access,
            "message": self.store.message,
            "library": library,
            "searchKeys": keys,
            "installedBrowsers": self._installed(),
            "usage": self.usage,
            "floating": self._floating(),
            "profiles": [
                {"id": profile_id, "label": info["label"], "browsers": sorted(info["browsers"])}
                for profile_id, info in self.profiles.items()
            ],
            "proposal": self.proposal,
            "focusQuery": self.focus_query,
            "downloads": self._download_state(),
            "mail": self._mail_state(),
            "vaultUnlocked": self.vault.is_unlocked(self.clock()),
        }

    def save_site(self, payload):
        self._writable()
        incoming = payload.get("site")
        if not isinstance(incoming, dict):
            raise AppError("网站内容无效。")
        if any(key in incoming for key in ("password", "secret")):
            raise AppError("密码不能写入网站资料。")
        library = copy.deepcopy(self.store.library)
        site = copy.deepcopy(incoming)
        if not site.get("id"):
            site["id"] = new_id()
        accounts = []
        for account in site.get("accounts") or []:
            if any(key in account for key in ("password", "secret", "token")):
                raise AppError("密码不能写入网站资料。")
            if not account.get("id"):
                account["id"] = new_id()
            account["hasPassword"] = bool(account.get("hasPassword"))
            accounts.append(account)
        site["accounts"] = accounts
        replaced = False
        for index, existing in enumerate(library["sites"]):
            if existing["id"] == site["id"]:
                for account in site["accounts"]:
                    previous = next((item for item in existing["accounts"] if item["id"] == account["id"]), None)
                    if previous and previous.get("hasPassword"):
                        account["hasPassword"] = True
                library["sites"][index] = site
                replaced = True
                break
        if not replaced:
            library["sites"].append(site)
            if site["id"] not in set(visible_site_ids(library["tiles"])):
                library["tiles"].append({"id": site["id"], "kind": "site"})
        now = self.clock()
        for item in payload.get("passwords") or []:
            if not item.get("password"):
                continue
            self.vault.save(item["id"], item["password"], now)
            for account in site["accounts"]:
                if account["id"] == item["id"]:
                    account["hasPassword"] = True
        library = validate_library(library)
        self.store.save(library)
        return self.state()

    def launch_site(self, site_id, browser_id=None, record=True):
        self._writable()
        site = self._site(site_id)
        connected = self._connected_map()
        launch = site_launch(site, browser_id, self._installed(), connected)
        if record:
            self.usage = record_launch(self.usage, site_id, self.clock())
            self._save_usage()
        self._open_launch(site, launch)
        return {"ok": True, "launch": launch, "state": self.state()}

    def remove_site(self, site_id):
        self._writable()
        library = copy.deepcopy(self.store.library)
        before = self._org(library)
        if site_id not in {site["id"] for site in library["sites"]}:
            raise AppError("网站不存在。")
        library["tiles"] = remove_from_tiles(site_id, library["tiles"])
        library = validate_library(library)
        self.history.push(before, self._org(library))
        self.store.save(library)
        return self.state()

    def restore_site(self, site_id):
        self._writable()
        library = copy.deepcopy(self.store.library)
        before = self._org(library)
        if site_id not in {site["id"] for site in library["sites"]}:
            raise AppError("网站不存在。")
        if site_id in set(visible_site_ids(library["tiles"])):
            return self.state()
        library["tiles"].append({"id": site_id, "kind": "site"})
        library = validate_library(library)
        self.history.push(before, self._org(library))
        self.store.save(library)
        return self.state()

    def set_layout(self, tiles):
        self._writable()
        library = copy.deepcopy(self.store.library)
        before = self._org(library)
        previous = set(visible_site_ids(library["tiles"]))
        library["tiles"] = tiles
        library = validate_library(library)
        if set(visible_site_ids(library["tiles"])) != previous:
            raise AppError("拖动不能增减网站，请使用移出或恢复。")
        self.history.push(before, self._org(library))
        self.store.save(library)
        return self.state()

    def batch(self, payload):
        self._writable()
        library = copy.deepcopy(self.store.library)
        before = self._org(library)
        updated = batch_edit(
            library,
            payload.get("siteIDs") or [],
            payload.get("operation"),
            browser=payload.get("browser"),
            folder_id=payload.get("folderID"),
            folder_name=payload.get("folderName"),
        )
        self.history.push(before, self._org(updated))
        self.store.save(updated)
        return self.state()

    def undo(self):
        self._writable()
        updated = self.history.undo(copy.deepcopy(self.store.library))
        self.store.save(updated)
        return self.state()

    def set_preferences(self, density, icon_size):
        self._writable()
        if density not in ("compact", "comfortable") or icon_size not in (60, 76, 92):
            raise AppError("外观选项无效。")
        library = copy.deepcopy(self.store.library)
        library["layoutDensity"] = density
        library["iconSize"] = icon_size
        self.store.save(library)
        return self.state()

    def set_appearance(self, appearance):
        self._writable()
        library = copy.deepcopy(self.store.library)
        library["appearance"] = appearance
        self.store.save(library)
        return self.state()

    def save_workspace(self, workspace):
        self._writable()
        library = copy.deepcopy(self.store.library)
        item = {
            "id": workspace.get("id") or new_id(),
            "name": (workspace.get("name") or "").strip(),
            "siteIDs": list(workspace.get("siteIDs") or []),
        }
        groups = list(library.get("workspaces") or [])
        for index, existing in enumerate(groups):
            if existing["id"] == item["id"]:
                groups[index] = item
                break
        else:
            groups.append(item)
        library["workspaces"] = groups
        self.store.save(library)
        return self.state()

    def delete_workspace(self, workspace_id):
        self._writable()
        library = copy.deepcopy(self.store.library)
        groups = [item for item in library.get("workspaces") or [] if item["id"] != workspace_id]
        if len(groups) == len(library.get("workspaces") or []):
            raise AppError("场景不存在。")
        if groups:
            library["workspaces"] = groups
        else:
            library.pop("workspaces", None)
        self.store.save(library)
        return self.state()

    def launch_workspace(self, workspace_id):
        self._writable()
        library = self.store.library
        group = next((item for item in library.get("workspaces") or [] if item["id"] == workspace_id), None)
        if group is None:
            raise AppError("场景不存在。")
        launches = []
        for site_id in group["siteIDs"]:
            site = self._site(site_id)
            launches.append(site_launch(site, site["defaultBrowser"], self._installed(), self._connected_map()))
        for launch in launches:
            site = self._site(launch["siteID"])
            self.usage = record_launch(self.usage, site["id"], self.clock())
            self._open_launch(site, launch)
        self._save_usage()
        return {"ok": True, "count": len(launches), "state": self.state()}

    def delete_account(self, site_id, account_id):
        self._writable()
        library = copy.deepcopy(self.store.library)
        site = next((item for item in library["sites"] if item["id"] == site_id), None)
        if site is None:
            raise AppError("网站不存在。")
        previous = self.vault.remove(account_id, self.clock())
        site["accounts"] = [account for account in site["accounts"] if account["id"] != account_id]
        if site.get("defaultAccount") == account_id:
            site.pop("defaultAccount", None)
        try:
            self.store.save(library)
        except Exception:
            if previous:
                self.vault.save(account_id, previous, self.clock())
            raise
        return self.state()

    def unlock(self):
        self.vault.unlock(self.clock())
        return self.state()

    def lock(self):
        self.vault.lock()
        self.mail_vault.lock()
        return self.state()

    def preview_backup(self, document, mode):
        self._writable()
        imported = validate_library(document)
        current = self.store.library
        nxt = restore_library(imported, current) if mode == "restore" else merge_library(imported, current)
        return self._hold(nxt, "backup", len(imported["sites"]))

    def preview_bookmarks(self, home, source_id):
        self._writable()
        preview = preview_bookmarks(Path(home), source_id, self.store.library)
        bar = next((item for item in preview["roots"] if item["id"] == "bookmark_bar"), None)
        if bar is None:
            raise AppError("这个浏览器资料没有收藏栏。")
        nxt = import_bookmarks(Path(home), source_id, ["bookmark_bar"], self.store.library)
        held = self._hold(nxt, "bookmarks", bar["siteCount"])
        held["preview"].update(preview)
        return held

    def bookmark_sources(self, home):
        return bookmark_sources(Path(home))

    def apply_pending(self, token, kind):
        self._writable()
        pending = self.pending.get(token)
        now = self.clock()
        if not pending or pending["kind"] != kind or pending["expires"] < now:
            raise AppError("预览已过期，请重新选择。")
        if validate_library(self.store.library) != pending["baseline"]:
            raise AppError("预览期间网站发生变化，请重新预览后导入。")
        self.store.save(pending["library"])
        self.pending.clear()
        self.history.entries.clear()
        return self.state()

    def open_action(self, directory, now=None):
        self._writable()
        manifest = read_package(Path(directory), now=now)
        if manifest["kind"] != "request":
            raise AppError("请打开动作请求包。")
        planned = plan(
            manifest["action"],
            manifest["parameters"],
            self.store.library,
            self._installed(),
            self._connected_map(),
            len(manifest.get("items") or []),
            len(manifest.get("references") or []),
        )
        if planned["type"] == "focusSearch":
            self.focus_query = planned["query"]
        elif planned["type"] == "proposeSite":
            self.proposal = {"url": planned["url"], "title": planned.get("title") or ""}
        elif planned["type"] == "prepareDownload":
            self._download_manager()
            return {"ok": True, "plan": planned, "prepared": self.downloads.prepare([item["url"] for item in planned["urls"]])}
        elif planned["type"] == "openSite":
            site = self._site(planned["launch"]["siteID"])
            self._open_launch(site, planned["launch"])
        elif planned["type"] == "openWorkspace":
            for launch in planned["sites"]:
                self._open_launch(self._site(launch["siteID"]), launch)
        return {"ok": True, "plan": planned, "state": self.state()}

    def validate_action(self, manifest, now=None):
        return validate_manifest(manifest, now=now)

    def export_catalog(self, kind, ids):
        self._writable()
        if kind == "workspaces":
            return export_workspace_catalog(self.store.library, set(ids))
        return export_site_catalog(self.store.library, set(ids))

    def floating_sites(self, query=""):
        if not self.store.library:
            return []
        return floating_sites(self.store.library, query, self.usage, 8)

    def set_floating(self, payload):
        prefs = self.store.preferences
        prefs.set("GaoMenHu.Floating.Enabled", bool(payload.get("enabled", True)))
        dock = payload.get("dock") if payload.get("dock") in ("left", "right", "none") else "right"
        prefs.set("GaoMenHu.Floating.Dock", dock)
        return self._floating()

    def download_manager(self):
        return self._download_manager()

    def mail_store(self):
        if self.mail is None:
            self.mail = MailStore(self.data_dir / "MailCenter")
            self.mail.load()
        return self.mail

    def native_message(self, message, browser):
        if not isinstance(message, dict) or not isinstance(message.get("type"), str):
            return {"ok": False, "error": "消息无效。"}
        profile_id = message.get("profileId")
        if not isinstance(profile_id, str) or not profile_id or len(profile_id) > 100:
            return {"ok": False, "error": "浏览器资料无效。"}
        label = str(message.get("label") or "默认资料")[:80]
        browsers = {browser} if browser in ("chrome", "edge") else {"chrome", "edge"}
        info = self.profiles.setdefault(profile_id, {"label": label, "browsers": set(), "seen": 0})
        info["label"] = label
        info["browsers"].update(browsers)
        info["seen"] = self.clock()
        kind = message["type"]
        if kind == "poll":
            launch = next((item for item in self.launches.values() if item["profileID"] == profile_id and not item.get("delivered")), None)
            if launch:
                launch["delivered"] = True
                return {"ok": True, "version": VERSION_LABEL, "launch": {"id": launch["id"], "url": launch["url"]}}
            return {"ok": True, "version": VERSION_LABEL}
        if kind == "credentials":
            return self._credentials(message, profile_id, browser if browser in ("chrome", "edge") else None)
        if kind == "saveBookmark":
            try:
                library, text = save_browser_bookmark(
                    copy.deepcopy(self.store.library),
                    message.get("url"),
                    message.get("title") or "",
                    browser if browser in ("chrome", "edge") else "chrome",
                    profile_id,
                    message.get("folderID"),
                )
                self.store.save(library)
                return {"ok": True, "message": text}
            except AppError as exc:
                return {"ok": False, "error": str(exc)}
        if kind == "collections":
            folders = [{"id": tile["id"], "name": tile.get("name")} for tile in (self.store.library or {}).get("tiles") or [] if tile["kind"] == "folder"]
            return {"ok": True, "folders": folders}
        if kind in ("bind", "launchStatus", "filled", "close"):
            return {"ok": True}
        return {"ok": False, "error": "不支持的操作。"}

    def _credentials(self, message, profile_id, browser):
        launch = self.launches.get(message.get("requestId"))
        if not launch or launch["profileID"] != profile_id:
            return {"ok": False}
        if not self.vault.is_unlocked(self.clock()):
            return {"ok": False, "error": "账号库已锁定，请回到搞门户解锁并重新打开网站。"}
        site = self._site(launch["siteID"])
        account = next((item for item in site["accounts"] if item["id"] == site.get("defaultAccount") and item.get("hasPassword")), None)
        if account is None:
            return {"ok": False}
        page = message.get("url") or ""
        allowed = set()
        from .models import origin_of
        site_origin = origin_of(site["url"])
        if site_origin and site_origin.startswith("https://"):
            allowed.add(site_origin)
        for host in account.get("loginHosts") or []:
            if "://" in host and not host.lower().startswith("https://"):
                continue
            normalized = host if "://" in host else "https://" + host
            origin = origin_of(normalized) if "://" in normalized else None
            if origin:
                allowed.add(origin)
        page_origin = origin_of(page)
        if not page_origin or page_origin not in allowed:
            return {"ok": False}
        try:
            password = self.vault.read(account["id"], self.clock())
        except AppError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "username": account["username"], "password": password}

    def _open_launch(self, site, launch):
        profile = launch.get("profileID")
        entry = {
            "id": new_id(),
            "siteID": site["id"],
            "url": site["url"],
            "browserID": launch["browserID"],
            "profileID": profile,
            "delivered": False,
        }
        if profile and profile in self.profiles:
            self.launches[entry["id"]] = entry
            self.launch_log.append({"mode": "extension", "browserID": launch["browserID"], "url": site["url"]})
            return
        if self.launcher:
            self.launcher(launch["browserID"], site["url"])
        self.launch_log.append({"mode": "process", "browserID": launch["browserID"], "url": site["url"]})

    def _download_manager(self):
        if self.downloads is None:
            self.downloads = DownloadManager(self.data_dir / "DownloadCenter")
        return self.downloads

    def _download_state(self):
        if self.downloads is None:
            return None
        return {
            "items": self.downloads.database["items"],
            "destinations": self.downloads.database["destinations"],
            "settings": self.downloads.database["settings"],
        }

    def _mail_state(self):
        if self.mail is None:
            return None
        return {
            "accounts": self.mail.library["accounts"],
            "drafts": self.mail.library["drafts"],
            "messages": [
                {key: value for key, value in message.items() if key != "html"}
                | {"html": sanitize_mail_html(message.get("html") or "")}
                for message in self.mail.messages
            ],
            "authorized": sorted(self.mail.authorized),
        }

    def _hold(self, library, kind, sites):
        now = self.clock()
        self.pending = {token: item for token, item in self.pending.items() if item["expires"] >= now}
        if len(self.pending) >= 8:
            self.pending.clear()
        token = str(uuid.uuid4())
        self.pending[token] = {
            "library": library,
            "baseline": validate_library(self.store.library),
            "kind": kind,
            "expires": now + 600,
        }
        return {"ok": True, "token": token, "preview": {"sites": sites, "message": "请确认后再写入。密码不会从备份恢复。"}}

    def _floating(self):
        prefs = self.store.preferences
        return {
            "enabled": bool(prefs.get("GaoMenHu.Floating.Enabled", True)),
            "dock": prefs.get("GaoMenHu.Floating.Dock", "right"),
        }

    def _load_usage(self):
        raw = {}
        if self.store.preferences.path.exists() or self.store.preferences.data:
            raw = self.store.preferences.get("GaoMenHu.WebsiteLaunchHistory") or {}
        if not isinstance(raw, dict):
            return {}
        return raw

    def _save_usage(self):
        self.store.preferences.set("GaoMenHu.WebsiteLaunchHistory", self.usage)

    def _installed(self):
        found = [item for item in self.browser_probe() if item in ("chrome", "edge", "safari", "firefox")]
        return found

    def _connected_map(self):
        result = {"chrome": set(), "edge": set(), "firefox": set(), "safari": set()}
        for profile_id, info in self.profiles.items():
            for browser in info["browsers"]:
                result.setdefault(browser, set()).add(profile_id)
        return result

    def _site(self, site_id):
        if not self.store.library:
            raise AppError("网站资料还没有就绪。")
        matches = [site for site in self.store.library["sites"] if site["id"] == site_id]
        if len(matches) != 1:
            raise AppError("网站不存在。")
        return matches[0]

    def _writable(self):
        if self.store.access != "ready":
            raise RecoveryError(self.store.message or "网站资料不可写。")

    def _org(self, library):
        return json.loads(json.dumps(organization_state(library)))

    def codes(self, subject, body, html=None):
        return {"codes": extract_codes(subject, body, html), "primary": primary_code(subject, body, html)}

    def sync_mail(self, account_id):
        store = self.mail_store()
        if account_id not in store.authorized:
            raise AppError("这个邮箱还没有连接。请先明确连接，再收取邮件。")
        account = next(item for item in store.library["accounts"] if item["id"] == account_id)
        password = self.mail_vault.read(account_id, self.clock())
        return store.sync(account_id, lambda _account_id: fetch_inbox(account, password))

    def send_draft(self, draft_id):
        store = self.mail_store()
        draft = next((item for item in store.library["drafts"] if item["id"] == draft_id), None)
        if draft is None:
            raise AppError("草稿不存在。")
        account = next((item for item in store.library["accounts"] if item["id"] == draft.get("accountID")), None)
        if account is None or account["id"] not in store.authorized:
            raise AppError("这个邮箱还没有连接。请先明确连接，再发送邮件。")
        password = self.mail_vault.read(account["id"], self.clock())
        record = store.stage_submission(draft_id)
        try:
            send_mail(account, password, draft)
        except Exception as exc:
            raise AppError("发送没有完成，发送记录已保留，不会自动再发一封。") from exc
        return store.complete_submission(record["id"])

    def aliases(self, email, service=None, count=8):
        if service:
            return {"alias": make_service_alias(email, service)}
        return {"aliases": generate_aliases(email, count=count)}
