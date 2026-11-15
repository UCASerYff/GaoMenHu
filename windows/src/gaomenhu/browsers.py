"""查找并启动本机浏览器。找不到指定浏览器时不会改用另一个。"""

import os
import shutil
import subprocess
from pathlib import Path

from .models import BROWSERS


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
    for candidate in _candidates().get(browser_id, []):
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
    command.append(url)
    subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    return path
