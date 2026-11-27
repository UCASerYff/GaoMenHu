"""查找并启动本机浏览器。找不到指定浏览器时不会改用另一个。"""

import os
import shutil
import subprocess
from pathlib import Path

from .errors import AppError
from .models import BROWSERS

BROWSER_HELPERS = {"chrome": "chrome.exe", "edge": "msedge.exe"}
EXTENSION_PAGES = {"chrome": "chrome://extensions/", "edge": "edge://extensions/"}


def _candidates():
    local = os.environ.get("LOCALAPPDATA", "")
    program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
    program_files_x86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    return {
        "chrome": [
            shutil.which("chrome"),
            shutil.which("chrome.exe"),
            str(Path(program_files) / "Google" / "Chrome" / "Application" / "chrome.exe"),
            str(Path(program_files_x86) / "Google" / "Chrome" / "Application" / "chrome.exe"),
            str(Path(local) / "Google" / "Chrome" / "Application" / "chrome.exe") if local else None,
        ],
        "edge": [
            shutil.which("msedge"),
            shutil.which("msedge.exe"),
            str(Path(program_files) / "Microsoft" / "Edge" / "Application" / "msedge.exe"),
            str(Path(program_files_x86) / "Microsoft" / "Edge" / "Application" / "msedge.exe"),
        ],
        "firefox": [
            shutil.which("firefox"),
            shutil.which("firefox.exe"),
            str(Path(program_files) / "Mozilla Firefox" / "firefox.exe"),
            str(Path(program_files_x86) / "Mozilla Firefox" / "firefox.exe"),
        ],
        "safari": [],
    }


def installed_browsers():
    found = []
    for browser in BROWSERS:
        path = executable(browser["id"])
        if path:
            found.append({**browser, "path": path})
    return found


def executable(browser_id):
    candidates = _candidates().get(browser_id, [])
    if os.name == "nt" and browser_id in ("chrome", "edge", "firefox"):
        import winreg
        name = BROWSER_HELPERS.get(browser_id, "firefox.exe")
        subkey = rf"Software\Microsoft\Windows\CurrentVersion\App Paths\{name}"
        for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
            for view in (winreg.KEY_WOW64_64KEY, winreg.KEY_WOW64_32KEY):
                try:
                    with winreg.OpenKey(hive, subkey, access=winreg.KEY_READ | view) as key:
                        value, _ = winreg.QueryValueEx(key, "")
                        if isinstance(value, str):
                            candidates.append(os.path.expandvars(value.strip('"')))
                except OSError:
                    continue
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    return None


def launch_browser(browser_id, url, profile_directory=None):
    path = executable(browser_id)
    if not path:
        return None
    command = [path]
    if browser_id in ("chrome", "edge") and profile_directory:
        command.append("--profile-directory=" + profile_directory)
    if url:
        command.append(url)
    elif browser_id in BROWSER_HELPERS:
        command.append("--no-startup-window")
    try:
        subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    except OSError as exc:
        raise AppError("浏览器未能启动，请检查浏览器后重试。", "browser_launch_failed") from exc
    return path


def extension_directory():
    import sys
    if getattr(sys, "frozen", False):
        installed = Path(sys.executable).resolve().parent / "BrowserExtension"
        if (installed / "manifest.json").is_file():
            return installed
    return Path(__file__).resolve().parents[3] / "BrowserExtension"


def open_extension_setup(browser_id=None):
    folder = extension_directory()
    if not (folder / "manifest.json").is_file():
        raise AppError("找不到搞门户助手目录，请重新安装搞门户。")
    if browser_id:
        if not isinstance(browser_id, str) or browser_id not in EXTENSION_PAGES or not launch_browser(browser_id, EXTENSION_PAGES[browser_id]):
            raise AppError("浏览器未安装。")
    elif os.name == "nt":
        os.startfile(str(folder))
    return {"ok": True, "path": str(folder)}
