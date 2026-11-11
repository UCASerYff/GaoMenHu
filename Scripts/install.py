#!/usr/bin/env python3
"""Verify a signed release candidate, then replace only this application's installation."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
APP_ID = "cn.mendao.launcher"
FORMAL_APP = Path("/Applications/搞门户.app")
LEGACY_APP = Path("/Applications/门道.app")
TEAM = "5G96498KGJ"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, text=True, capture_output=True, **kwargs)


def validate_build_destination(path):
    path = Path(path).expanduser().resolve(strict=False)
    require(path.name.endswith(".app"), "测试构建目标必须是 .app。")
    require(any(parent.name.endswith(".noindex") for parent in path.parents), "测试构建目标必须位于 .noindex 容器。")
    return path


def app_info(path):
    with (path / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)


def verify_candidate(path, version):
    require(path.is_dir(), "发行包中缺少搞门户 App。")
    info = app_info(path)
    require(info.get("CFBundleIdentifier") == APP_ID, "候选程序的 Bundle ID 不符，停止安装。")
    require(info.get("CFBundleShortVersionString") == version, "候选程序版本与发行包不符，停止安装。")
    require(info.get("CFBundleVersion") == version.replace(".", ""), "候选程序构建号不符，停止安装。")
    run(["codesign", "--verify", "--strict", str(path)])
    details = run(["codesign", "--display", "--verbose=4", "--requirements", "-", str(path)])
    text = details.stdout + details.stderr
    require(f"TeamIdentifier={TEAM}" in text, "候选程序签名 Team 不符，停止安装。")
    require("cdhash " not in text, "候选程序仍使用不稳定的摘要指定要求，停止安装。")
    for executable in ("MenDao", "MenDaoBridge"):
        binary = path / "Contents/MacOS" / executable
        require(binary.is_file(), f"候选程序缺少 {executable}。")
        run(["codesign", "--verify", "--strict", str(binary)])
    return info


def verify_existing(path):
    if not path.exists():
        return
    require(path.is_dir() and not path.is_symlink(), f"旧安装路径异常：{path}")
    require(app_info(path).get("CFBundleIdentifier") == APP_ID, f"旧安装身份不符，不会删除：{path}")


def verified_release():
    version = (ROOT / "VERSION").read_text().strip()
    image = ROOT / "Release" / f"GaoMenHu-{version}.dmg"
    checksum = image.with_suffix(image.suffix + ".sha256")
    expected = checksum.read_text().split()[0].lower()
    digest = hashlib.sha256()
    with image.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    require(digest.hexdigest() == expected, "安装包 SHA-256 不符，停止安装。")
    return version, image


def install(no_open=False):
    version, image = verified_release()
    verify_existing(FORMAL_APP)
    verify_existing(LEGACY_APP)
    stage = Path("/Applications") / f".GaoMenHu-install-{uuid.uuid4()}.noindex"
    mount = Path(tempfile.mkdtemp(prefix="GaoMenHu-mount-", suffix=".noindex", dir="/private/tmp"))
    mounted = False
    try:
        stage.mkdir(mode=0o700)
        run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), str(image)])
        mounted = True
        candidate_source = mount / "搞门户.app"
        verify_candidate(candidate_source, version)
        candidate = stage / "搞门户.app"
        run(["ditto", str(candidate_source), str(candidate)])
        verify_candidate(candidate, version)
        run(["osascript", "-e", f'if application id "{APP_ID}" is running then tell application id "{APP_ID}" to quit'])
        running = run(["osascript", "-e", f'application id "{APP_ID}" is running'])
        require(running.stdout.strip() == "false", "搞门户仍在运行；请先保留草稿并正常退出，停止替换。")
        verify_existing(FORMAL_APP)
        verify_existing(LEGACY_APP)
        for old in (LEGACY_APP, FORMAL_APP):
            if old.exists():
                shutil.rmtree(old)
        os.rename(candidate, FORMAL_APP)
        run(["lsregister", "-f", str(FORMAL_APP)]) if shutil.which("lsregister") else None
        if not no_open:
            subprocess.run(["open", "-a", str(FORMAL_APP)], check=True)
    finally:
        try:
            if stage.exists():
                shutil.rmtree(stage)
        finally:
            if mounted:
                run(["hdiutil", "detach", str(mount), "-quiet"])
            mount.rmdir()
    print(f"已安装：{FORMAL_APP}")
    return FORMAL_APP


def main():
    parser = argparse.ArgumentParser(description="核验并安装搞门户当前发行版")
    parser.add_argument("--no-open", action="store_true", help="安装后不启动应用")
    arguments = parser.parse_args()
    try:
        install(no_open=arguments.no_open)
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"安装未完成：{error}\n")


if __name__ == "__main__":
    main()
