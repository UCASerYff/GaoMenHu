"""本机业务入口。网页、测试和浏览器助手都调用这里。"""

import copy
import json
import secrets
import threading
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
from .browser_session import BrowserSession
from .browsers import installed_browsers, launch_browser
from .centers import download_state, import_request, mail_route
from .downloads import DownloadManager
from .errors import AppError, RecoveryError
from .floating_geometry import valid_anchor
from .icons import WebsiteIcons
from .mail import MailStore, extract_codes, generate_aliases, make_service_alias, primary_code
from .mail_oauth import MailOAuth
from .models import bookmark_url_key, new_id, normalized_host, validate_library, visible_site_ids
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
)
from .search import floating_sites, normalized_usage, record_launch, search_key
from .store import LibraryStore
from .vault import mail_vault, site_vault


class PortalService:
    def __init__(self, data_dir, browser_probe=None, launcher=None, clock=None):
        self.data_dir = Path(data_dir)
        self.browser_probe = browser_probe or (lambda: [item["id"] for item in installed_browsers()])
        self.launcher = launcher if launcher is not None else launch_browser
        self.uses_system_launcher = launcher is None
        self.clock = clock or time.time
        self.store = LibraryStore(self.data_dir)
        self.vault = site_vault(self.data_dir)
        self.mail_vault = mail_vault(self.data_dir / "MailCenter")
        self.downloads = None
        self.mail = None
        self.center_init_lock = threading.RLock()
        self.mail_lock = threading.RLock()
        self.mail_sending = set()
        self.mail_last_attempt = {}
        self.mail_autosync = None
        self.mail_oauth = MailOAuth(self)
        self.history = OrganizationHistory()
        self.library_lock = threading.RLock()
        self.icons = WebsiteIcons(self)
        self.pending = {}
        self.usage = self._load_usage()
        self._floating_lock = threading.RLock()
        self._floating_session = {}
        self.browser_session = BrowserSession(self)
        self.focus_query = ""
        self.proposal = None
        self.launch_log = []
        self.page_token = secrets.token_urlsafe(24)
        self.host_token = secrets.token_urlsafe(24)
        self.store.load(self._installed())

    def create_library(self):
        with self.library_lock:
            self.store.create(self._installed())
            with self._floating_lock:
                if self._floating_session:
                    self.store.preferences.update(self._floating_session)
                    self._floating_session.clear()
        return self.state()

    def launcher_runtime(self):
        with self.library_lock:
            access = self.store.access
            message = self.store.message
            revision = self.store.baseline_identity
        return {
            "ok": True,
            "version": VERSION_LABEL,
            "access": access,
            "message": message,
            "libraryRevision": revision,
            "installedBrowsers": self._installed(),
            "floating": self.floating_preferences(),
            "profiles": [{key: value for key, value in client.items() if key != "seen"} for client in self.browser_session.clients()],
            "launchFeedback": self.browser_session.messages(),
            "proposal": self.proposal,
            "focusQuery": self.focus_query,
            "vaultUnlocked": self.vault.is_unlocked(self.clock()),
        }

    def state(self, launcher_only=False):
        with self.library_lock:
            state = self.launcher_runtime()
            library = self.store.library
            state["library"] = library
            state["canUndo"] = bool(self.history.entries)
        state["searchKeys"] = {site["id"]: search_key(site) for site in library["sites"]} if library else {}
        if not launcher_only:
            state.update(usage=self.usage, downloads=self._download_state(), mail=self._mail_state())
        return state

    def save_site(self, payload):
        incoming = payload.get("site")
        if not isinstance(incoming, dict):
            raise AppError("网站内容无效。")
        if any(key in incoming for key in ("password", "secret")):
            raise AppError("密码不能写入网站资料。")
        with self.library_lock:
            self._writable()
            library = copy.deepcopy(self.store.library)
            site = copy.deepcopy(incoming)
            site["id"] = site.get("id") or new_id()
            index = next((i for i, saved in enumerate(library["sites"]) if saved["id"] == site["id"]), None)
            previous = library["sites"][index] if index is not None else {}
            previous_accounts = {account["id"]: account for account in previous.get("accounts", [])}
            accounts = site.get("accounts", [])
            patches = payload.get("passwords", [])
            if not isinstance(accounts, list) or not isinstance(patches, list):
                raise AppError("账号配置无效。")
            passwords = {}
            for patch in patches:
                if not isinstance(patch, dict) or not isinstance(patch.get("id"), str) or not isinstance(patch.get("password"), str):
                    raise AppError("账号密码配置无效。")
                if patch["password"]:
                    passwords[patch["id"]] = patch["password"]
            account_ids = set()
            for account in accounts:
                if not isinstance(account, dict) or any(key in account for key in ("password", "secret", "token")):
                    raise AppError("账号配置无效。")
                account["id"] = account.get("id") or new_id()
                if not isinstance(account["id"], str) or account["id"] in account_ids:
                    raise AppError("账号配置无效。")
                account_ids.add(account["id"])
                hosts = account.get("loginHosts", [])
                if not isinstance(hosts, list):
                    raise AppError("登录域名格式不正确。")
                normalized = [normalized_host(host) for host in hosts]
                if None in normalized:
                    raise AppError("登录域名格式不正确。请填写完整域名，例如 accounts.example.com。")
                account["loginHosts"] = list(dict.fromkeys(normalized))
                old_account = previous_accounts.get(account["id"], {})
                account["hasPassword"] = bool(old_account.get("hasPassword") or account["id"] in passwords)
                if old_account.get("hasPassword") and account["id"] in passwords:
                    previous_id = account["id"]
                    account["id"] = new_id()
                    passwords[account["id"]] = passwords.pop(previous_id)
                    if site.get("defaultAccount") == previous_id:
                        site["defaultAccount"] = account["id"]
            retained = {account["id"] for account in accounts}
            if not passwords.keys() <= retained:
                raise AppError("只能保存当前网站账号的密码。")
            site["accounts"] = accounts
            if not accounts:
                site.pop("defaultAccount", None)
            if previous and previous.get("url") == site.get("url") and not site.pop("iconChanged", False):
                for key in self.icons.FIELDS:
                    site.pop(key, None)
                    if key in previous:
                        site[key] = previous[key]
            elif previous.get("url") != site.get("url") and site.get("iconSource") != "custom":
                for key in self.icons.FIELDS:
                    site.pop(key, None)
            if index is None:
                library["sites"].append(site)
                library["tiles"].append({"id": site["id"], "kind": "site"})
            else:
                library["sites"][index] = site
            library = validate_library(library)
            old_secrets = {}
            now = self.clock()
            cleanup_failed = False
            with self.vault.maintain_lock_state(now):
                try:
                    if passwords:
                        if not self.vault.is_unlocked(now):
                            self.vault.unlock(now)
                        old_secrets = {account_id: self.vault.cache.get(account_id) for account_id in passwords}
                        for account_id, password in passwords.items():
                            self.vault.save(account_id, password, now)
                    self.store.save(library)
                except Exception:
                    for account_id, secret in old_secrets.items():
                        if secret is None:
                            self.vault.remove(account_id, now)
                        else:
                            self.vault.save(account_id, secret, now)
                    raise
                for account_id in previous_accounts.keys() - retained:
                    if previous_accounts[account_id].get("hasPassword"):
                        try:
                            self.vault.remove(account_id, now)
                        except (AppError, OSError):
                            cleanup_failed = True
            self.history.entries.clear()
            if payload.get("portalRequestID") and self.proposal and self.proposal.get("requestID") == payload["portalRequestID"]:
                self.proposal = None
        state = self.state()
        if cleanup_failed:
            state["siteWarning"] = "网站已保存，但旧账号的密码清理失败。"
        return state

    def refresh_icons(self, site_id=None):
        self._writable()
        sites = [self._site(site_id)] if site_id else self.store.library["sites"]
        count = self.icons.schedule(sites)
        if not count and site_id and sites[0].get("iconSource") == "custom":
            return {"ok": True, "message": "此网站正在使用自定义图标。请在网站编辑中切换到清晰图标。"}
        return {"ok": True, "message": "正在获取清晰图标，完成后会自动更新。" if count else "没有待刷新的网站图标。"}

    def launch_site(self, site_id, browser_id=None, record=True, account_id=None):
        self._writable()
        site = self._site(site_id)
        launch = site_launch(site, browser_id, self._installed(), self._connected_map(), account_id)
        result = self._open_launch(site, launch, record)
        return {"ok": True, "launch": launch, "state": self.state(), **result}

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
        installed, connected = self._installed(), self._connected_map()
        for site_id in group["siteIDs"]:
            site = self._site(site_id)
            launch = site_launch(site, site["defaultBrowser"], installed, connected)
            self.browser_session.require_consent(launch)
            launches.append((site, launch))
        failures = []
        for site, launch in launches:
            try:
                self._open_launch(site, launch)
            except AppError as exc:
                failures.append({"siteID": site["id"], "name": site["name"], "error": str(exc)})
        count = len(launches) - len(failures)
        message = f"正在打开 {count} 个网站。"
        if failures:
            message += " 未能打开：" + "、".join(item["name"] for item in failures)
        return {"ok": True, "count": count, "failures": failures, "message": message, "state": self.state()}

    def delete_account(self, site_id, account_id):
        self._writable()
        library = copy.deepcopy(self.store.library)
        site = next((item for item in library["sites"] if item["id"] == site_id), None)
        if site is None:
            raise AppError("网站不存在。")
        account = next((item for item in site["accounts"] if item["id"] == account_id), None)
        if account is None:
            raise AppError("指定账号不存在。")
        site["accounts"] = [account for account in site["accounts"] if account["id"] != account_id]
        if site.get("defaultAccount") == account_id:
            site.pop("defaultAccount", None)
        now = self.clock()
        with self.vault.maintain_lock_state(now):
            previous = self.vault.remove(account_id, now) if account["hasPassword"] else None
            try:
                self.store.save(library)
            except Exception:
                if previous:
                    self.vault.save(account_id, previous, now)
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
        if mode not in ("merge", "restore"):
            raise AppError("请选择合并或恢复资料。")
        imported = validate_library(document)
        current = self.store.library
        nxt = restore_library(imported, current) if mode == "restore" else merge_library(imported, current)
        existing = {bookmark_url_key(site["url"]) for site in current["sites"]}
        details = {
            "sites": len(imported["sites"]),
            "folders": sum(tile["kind"] == "folder" for tile in imported["tiles"]),
            "duplicates": sum(bookmark_url_key(site["url"]) in existing for site in imported["sites"]),
            "message": "恢复排列、场景和设置。当前资料独有的网站将保留为移除入口。" if mode == "restore"
                       else "合并新增网站与文件夹，并保留当前网站的账号与浏览器设置。",
        }
        return self._hold(nxt, "backup", details)

    def preview_bookmarks(self, home, source_id):
        self._writable()
        preview = preview_bookmarks(Path(home), source_id, self.store.library)
        bar = next((item for item in preview["roots"] if item["id"] == "bookmark_bar"), None)
        if bar is None:
            raise AppError("这个浏览器资料没有收藏栏。")
        nxt = import_bookmarks(Path(home), source_id, ["bookmark_bar"], self.store.library)
        return self._hold(nxt, "bookmarks", preview | {
            "sites": bar["siteCount"] - bar["duplicateCount"],
            "folders": bar["folderCount"],
            "duplicates": bar["duplicateCount"],
            "folderNames": [folder["name"] for folder in bar["children"]],
            "message": "导入选中的个人资料收藏栏，并保留当前网站的账号与浏览器设置。",
        })

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
        manifest = read_package(Path(directory), now=now)
        if manifest["kind"] != "request":
            raise AppError("请打开动作请求包。")
        if manifest["action"] == "downloads.prepare":
            manager = self._download_manager()
            with manager.lock:
                request_id = import_request(manager, manifest)
            return {"ok": True, "plan": {"type": "downloadRequest", "requestID": request_id}, "path": f"/downloads#request={request_id}"}
        self._writable()
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
            self.proposal = {
                "url": planned["url"], "title": planned.get("title") or "",
                "requestID": manifest["requestID"],
            }
        elif planned["type"] == "prepareDownload":
            prepared = self._download_manager().prepare([item["url"] for item in planned["urls"]])
            ticket = secrets.token_urlsafe(18)
            with self.center_init_lock:
                self.download_composers = {k: value for k, value in getattr(self, "download_composers", {}).items() if value[0] > self.clock()}
                self.download_composers[ticket] = (self.clock() + 300, prepared)
            return {"ok": True, "plan": planned, "prepared": prepared, "path": f"/downloads?review={ticket}"}
        elif planned["type"] == "openSite":
            site = self._site(planned["launch"]["siteID"])
            self._open_launch(site, planned["launch"])
        elif planned["type"] == "openWorkspace":
            for launch in planned["sites"]:
                self.browser_session.require_consent(launch)
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
        with self.library_lock:
            library, usage = self.store.library, self.usage
        return floating_sites(library, query, usage, 8) if library else []

    def set_floating(self, payload, *, anchor=None):
        prefix = "GaoMenHu.Floating."
        changes = {}
        if isinstance(payload.get("enabled"), bool):
            changes[prefix + "Enabled"] = payload["enabled"]
        if payload.get("dock") in ("left", "right", "none", "free"):
            changes[prefix + "Dock"] = "none" if payload["dock"] == "free" else payload["dock"]
        if valid_anchor(anchor):
            changes[prefix + "WindowsAnchorV1"] = anchor
        if payload.get("reset") is True:
            changes.update({prefix + "Dock": "right", prefix + "Enabled": True, prefix + "WindowsAnchorV1": None})
        with self._floating_lock:
            if changes and self.store.access == "ready":
                self.store.preferences.update(self._floating_session | changes)
                self._floating_session.clear()
            else:
                self._floating_session.update(changes)
            return self.floating_preferences()

    def download_manager(self):
        return self._download_manager()

    def mail_store(self):
        with self.center_init_lock:
            if self.mail is None:
                store = MailStore(self.data_dir / "MailCenter")
                try:
                    store.load()
                except (OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
                    raise AppError("邮件资料无法读取，已停止写入。") from exc
                self.mail = store
            return self.mail

    def native_message(self, message, browser):
        return self.browser_session.request(message, browser)

    def _open_launch(self, site, launch, record=True):
        return self.browser_session.launch(site, launch, record)

    def _record_success(self, site_id):
        self.usage = record_launch(self.usage, site_id, self.clock())
        self._save_usage()

    def _download_manager(self):
        with self.center_init_lock:
            if self.downloads is None:
                self.downloads = DownloadManager(self.data_dir / "DownloadCenter")
            return self.downloads

    def _download_state(self):
        return download_state(self.downloads) if self.downloads is not None else None

    def _mail_state(self):
        return {"initialized": True} if self.mail is not None else None

    def _hold(self, library, kind, preview):
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
        return {"ok": True, "token": token, "preview": preview}

    def floating_preferences(self):
        with self._floating_lock:
            values = self.store.preferences.data | self._floating_session
            dock = values.get("GaoMenHu.Floating.Dock", "right")
            if dock == "free":
                dock = "none"
            anchor = values.get("GaoMenHu.Floating.WindowsAnchorV1")
            return {
                "enabled": bool(values.get("GaoMenHu.Floating.Enabled", True)),
                "dock": dock if dock in ("left", "right", "none") else "right",
                "anchor": dict(anchor) if valid_anchor(anchor) else None,
            }

    def _load_usage(self):
        return normalized_usage(self.store.preferences.get("GaoMenHu.WebsiteLaunchHistory"))

    def _save_usage(self):
        self.store.preferences.set("GaoMenHu.WebsiteLaunchHistory", self.usage)

    def _installed(self):
        found = [item for item in self.browser_probe() if item in ("chrome", "edge", "safari", "firefox")]
        return found

    def _connected_map(self):
        return self.browser_session.connected()

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
        return mail_route(self, "sync", {"id": account_id})["messages"]

    def send_draft(self, draft_id):
        return mail_route(self, "send", {"draftID": draft_id})["submission"]

    def aliases(self, email, service=None, count=8):
        if service:
            return {"alias": make_service_alias(email, service)}
        return {"aliases": generate_aliases(email, count=count)}
