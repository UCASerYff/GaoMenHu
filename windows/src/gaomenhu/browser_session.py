"""Short-lived per-browser site launch and HTTPS autofill grants."""

import copy
import threading
import uuid

from . import VERSION_LABEL
from .browsers import BROWSER_HELPERS
from .errors import AppError
from .models import new_id, origin_of
from .operations import save_browser_bookmark

PROFILE_SECONDS = 9
GRANT_SECONDS = 300


class BrowserSession:
    def __init__(self, service):
        self.service = service
        self.lock = threading.RLock()
        self.profiles = {}
        self.launches = {}
        self.feedback = {}

    def clients(self):
        with self.lock:
            self._prune()
            return sorted(self.profiles.values(), key=lambda row: (row["browser"], row["label"], row["id"]))

    def messages(self):
        with self.lock:
            return dict(self.feedback)

    def connected(self):
        result = {browser: set() for browser in BROWSER_HELPERS}
        for client in self.clients():
            result[client["browser"]].add(client["id"])
        return result

    def require_consent(self, launch):
        if launch["browserID"] in BROWSER_HELPERS and launch["requiresAuthentication"]:
            if not self.service.vault.is_unlocked(self.service.clock()):
                raise AppError("请先解锁账号库，再填入所选账号。", "vault_locked")

    def launch(self, site, plan, record=True):
        self.require_consent(plan)
        browser, profile = plan["browserID"], plan["profileID"]
        grant = {
            "id": new_id(), "siteID": site["id"], "url": site["url"], "browserID": browser,
            "profileID": profile, "claimed": None, "tabID": None, "accountID": plan.get("accountID"),
            "filled": False, "opened": False, "record": record,
            "expires": self.service.clock() + GRANT_SECONDS,
            "site": copy.deepcopy(site),
        }
        if browser in BROWSER_HELPERS and (profile or plan["requiresAuthentication"]):
            with self.lock:
                self._prune()
                if len(self.launches) >= 128:
                    raise AppError("待打开的网页过多，请稍后重试。")
                self.launches[grant["id"]] = grant
                if not profile:
                    try:
                        self._process(browser, None)
                    except AppError:
                        self.launches.pop(grant["id"], None)
                        raise
                timer = threading.Timer(8, self._unclaimed, args=(grant["id"],))
                timer.daemon = True
                timer.start()
                opened_timer = threading.Timer(20, self._confirm_open, args=(grant["id"],))
                opened_timer.daemon = True
                opened_timer.start()
                self.service.launch_log.append({"mode": "extension", "browserID": browser, "url": site["url"]})
            return {"requestID": grant["id"], "message": "正在用浏览器助手打开…" if profile else "正在连接浏览器助手…"}
        self._process(browser, site["url"])
        self.service.launch_log.append({"mode": "process", "browserID": browser, "url": site["url"]})
        if record:
            with self.lock:
                self.service._record_success(site["id"])
        return {"message": "已交给所选浏览器打开。"}

    def _process(self, browser, url):
        if self.service.launcher(browser, url) is None and self.service.uses_system_launcher:
            raise AppError("浏览器未安装或已移动，请重新检查。", "browser_unavailable")

    def _unclaimed(self, request_id):
        with self.lock:
            grant = self.launches.get(request_id)
            if not grant or grant["claimed"]:
                return
            del self.launches[request_id]
            explicit = grant["site"]["profiles"].get(grant["browserID"])
            if explicit:
                self._report(request_id, "指定的浏览器资料未响应，请重新连接该资料的搞门户助手。")
                return
            try:
                self._process(grant["browserID"], grant["url"])
                if grant["record"]:
                    self.service._record_success(grant["siteID"])
                self._report(request_id, "网页已打开。请重新连接浏览器助手后重试自动填充。")
            except AppError as exc:
                self._report(request_id, str(exc))

    def _confirm_open(self, request_id):
        with self.lock:
            grant = self.launches.get(request_id)
            if grant and not grant["opened"]:
                del self.launches[request_id]
                self._report(request_id, "浏览器助手未确认网页已打开，请检查标签页和助手连接后重试。")

    def request(self, message, browser):
        if not isinstance(browser, str) or browser not in BROWSER_HELPERS or not isinstance(message, dict):
            return {"ok": False, "error": "连接身份无效。"}
        profile = message.get("profileId")
        try:
            if not isinstance(profile, str) or len(profile) > 100:
                raise ValueError
            uuid.UUID(profile)
        except ValueError:
            return {"ok": False, "error": "浏览器资料无效。"}
        kind = message.get("type")
        if kind not in ("poll", "bind", "launchStatus", "credentials", "filled", "close", "collections", "saveBookmark"):
            return {"ok": False, "error": "不支持的操作。"}
        with self.lock:
            self._prune()
            label = message.get("label")
            self.profiles[browser, profile] = {
                "id": profile, "browser": browser, "browsers": [browser],
                "label": (label.strip()[:80] or "默认资料") if isinstance(label, str) else "默认资料",
                "seen": self.service.clock(),
            }
            if kind == "poll":
                return self._poll(browser, profile)
            if kind == "collections":
                tiles = (self.service.store.library or {}).get("tiles", [])
                return {"ok": True, "folders": [
                    {"id": tile["id"], "name": tile.get("name") or "文件夹"}
                    for tile in tiles if tile["kind"] == "folder"
                ]}
            if kind == "saveBookmark":
                return self._save_bookmark(message, browser, profile)
            request_id = message.get("requestId")
            grant = self.launches.get(request_id) if isinstance(request_id, str) else None
            if not grant or grant["browserID"] != browser or grant["claimed"] != profile:
                return {"ok": False}
            tab_id = message.get("tabId")
            valid_tab = type(tab_id) is int and 0 <= tab_id <= 2_147_483_647
            if kind == "bind" and valid_tab and grant["tabID"] is None:
                grant["tabID"] = tab_id
                return {"ok": True}
            if kind == "close":
                del self.launches[request_id]
                return {"ok": True}
            if kind == "launchStatus" and message.get("status") == "failed" and (grant["tabID"] is None or (valid_tab and grant["tabID"] == tab_id)):
                del self.launches[request_id]
                self._report(request_id, "浏览器未能完成打开，请从搞门户重试。")
                return {"ok": True}
            if not valid_tab or grant["tabID"] != tab_id:
                return {"ok": False}
            if kind == "launchStatus" and message.get("status") == "opened":
                return self._opened(grant)
            if kind == "credentials":
                return self._credentials(grant, message.get("url"))
            if kind == "filled" and type(message.get("passwordFilled")) is bool:
                grant["filled"] = message["passwordFilled"]
                self._report(request_id, "账号和密码已填入，请自行完成登录。" if grant["filled"] else "账号已填入，等待下一步密码页面。")
                if grant["filled"] and grant["opened"]:
                    del self.launches[request_id]
                return {"ok": True}
            return {"ok": False}

    def _save_bookmark(self, message, browser, profile):
        title, folder = message.get("title"), message.get("folderID")
        if not isinstance(title, str) or (folder is not None and not isinstance(folder, str)):
            return {"ok": False, "error": "收藏资料无效。"}
        try:
            self.service._writable()
            library, notice = save_browser_bookmark(
                copy.deepcopy(self.service.store.library), message.get("url"), title, browser, profile, folder,
            )
            self.service.store.save(library)
        except AppError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "message": notice}

    def _poll(self, browser, profile):
        for request_id, grant in tuple(self.launches.items()):
            if grant["browserID"] != browser or grant["claimed"] or grant["profileID"] not in (None, profile):
                continue
            if grant["profileID"] is None and len(self.connected()[browser]) > 1:
                del self.launches[request_id]
                self._report(request_id, "多个浏览器资料已连接，请为网站指定资料。")
                continue
            grant["claimed"] = profile
            return {"ok": True, "version": VERSION_LABEL, "launch": {"id": request_id, "url": grant["url"]}}
        return {"ok": True, "version": VERSION_LABEL, "unlocked": self.service.vault.is_unlocked(self.service.clock())}

    def _opened(self, grant):
        request_id = grant["id"]
        if not grant["opened"] and grant["record"]:
            self.service._record_success(grant["siteID"])
        grant["opened"] = True
        if grant["filled"] or not grant["accountID"] or not self._account(grant):
            del self.launches[request_id]
            if not grant["filled"]:
                self._report(request_id, "网页已在指定浏览器资料中打开。")
        else:
            self._report(request_id, "网页已打开，等待登录表单…")
            timer = threading.Timer(25, self._unfilled, args=(request_id,))
            timer.daemon = True
            timer.start()
        return {"ok": True}

    def _unfilled(self, request_id):
        with self.lock:
            if self.feedback.get(request_id) == "网页已打开，等待登录表单…" and request_id in self.launches:
                self._report(request_id, "尚未检测到可填表单：可能已登录，或需要先进入登录页。")

    def _account(self, grant):
        try:
            current = self.service._site(grant["siteID"])
        except AppError:
            return None
        fields = ("url", "allowedBrowsers", "defaultBrowser", "accounts", "defaultAccount", "profiles")
        if any(current.get(field) != grant["site"].get(field) for field in fields):
            return None
        return next((account for account in current["accounts"] if account["id"] == grant["accountID"] and account["hasPassword"]), None)

    def _credentials(self, grant, url):
        account = self._account(grant)
        if grant["filled"] or not account:
            return {"ok": False}
        origin = origin_of(url) if isinstance(url, str) else None
        allowed = {origin_of(grant["url"])}
        allowed.update(origin_of(host if "://" in host else "https://" + host) for host in account.get("loginHosts") or [])
        if not origin or not origin.startswith("https://") or origin not in allowed:
            notice = "当前登录页的域名未获授权。请核对账号的其他登录域名。"
            self._report(grant["id"], notice)
            return {"ok": False, "error": notice}
        try:
            password = self.service.vault.read(account["id"], self.service.clock())
        except AppError as exc:
            self._report(grant["id"], str(exc))
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "username": account["username"], "password": password}

    def _report(self, request_id, message):
        self.feedback.pop(request_id, None)
        self.feedback[request_id] = message
        while len(self.feedback) > 32:
            del self.feedback[next(iter(self.feedback))]

    def _prune(self):
        now = self.service.clock()
        for key, profile in tuple(self.profiles.items()):
            if now - profile["seen"] >= PROFILE_SECONDS:
                del self.profiles[key]
        for key, grant in tuple(self.launches.items()):
            if now >= grant["expires"]:
                del self.launches[key]
