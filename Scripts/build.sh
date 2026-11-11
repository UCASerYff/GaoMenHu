#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$PROJECT_DIR/VERSION" | tr -d '\n')"
BUILD_NUM="$(print "$VERSION" | tr -d '.')"
SIGN_IDENTITY='A15B2B2D22B018CBC842063C9A8A589946647524'
SIGN_TEAM='5G96498KGJ'
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]{2}$' ]]; then print -u2 "VERSION 格式必须为 1.00"; exit 1; fi
TEST_FLAGS=()
if (( $# > 0 )); then
  if (( $# != 2 )) || [[ "$1" != "--app-only" ]]; then print -u2 "用法：build.sh [--app-only /绝对路径/容器.noindex/测试.app]"; exit 1; fi
  # Resolve and check the destination before compiling or creating any App.
  DEST="$(python3 - "$PROJECT_DIR/Scripts/install.py" "$2" <<'PY'
import runpy
import sys
from pathlib import Path
try:
    helpers = runpy.run_path(sys.argv[1], run_name="gaomenhu_build_paths")
    print(helpers["validate_build_destination"](Path(sys.argv[2])))
except (RuntimeError, OSError, ValueError) as error:
    print(str(error) if isinstance(error, RuntimeError) else "测试构建目标无效。", file=sys.stderr)
    sys.exit(1)
PY
)"
  TEST_FLAGS=(-D DEBUG_TESTING)
fi
STAGING_ROOT="$(mktemp -d /private/tmp/mendao-build.XXXXXX)"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGING="$STAGING_ROOT/Build.noindex"
mkdir -m 700 "$STAGING"
APP="$STAGING/搞门户.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$STAGING/module-cache"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
clang -O2 -arch arm64 -mmacosx-version-min=14.0 -isysroot "$SDK" \
  -c "$PROJECT_DIR/Sources/Mail/MailNative.c" -o "$STAGING/MailNative.o"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$STAGING/module-cache" \
  -import-objc-header "$PROJECT_DIR/Sources/Mail/MailNative.h" \
  "$TEST_FLAGS[@]" "$PROJECT_DIR/Tests/UITesting.swift" "$PROJECT_DIR/Tests/NativeFeatureTests.swift" \
  "$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Sources/PortalTheme.swift" "$PROJECT_DIR/Sources/Vault.swift" "$PROJECT_DIR/Sources/Socket.swift" \
  "$PROJECT_DIR/Sources/BridgeServer.swift" "$PROJECT_DIR/Sources/IconLoader.swift" "$PROJECT_DIR/Sources/LibraryOperations.swift" "$PROJECT_DIR/Sources/Features.swift" "$PROJECT_DIR/Sources/FullBackup.swift" "$PROJECT_DIR/Sources/NativeSettings.swift" "$PROJECT_DIR/Sources/FloatingLauncherLogic.swift" "$PROJECT_DIR/Sources/FloatingLauncher.swift" "$PROJECT_DIR/Sources/GaoActionPackage.swift" "$PROJECT_DIR/Sources/PortalActions.swift" "$PROJECT_DIR/Sources/PortalDownloadResults.swift" "$PROJECT_DIR/Sources/PortalIntegration.swift" "$PROJECT_DIR/Sources/PortalDownloadIngress.swift" "$PROJECT_DIR/Sources/PortalDownloadHost.swift" "$PROJECT_DIR/Sources/Downloads/"*.swift "$PROJECT_DIR/Sources/PortalMailHost.swift" "$PROJECT_DIR/Sources/PortalMailPreferences.swift" "$PROJECT_DIR/Sources/Mail/"*.swift "$PROJECT_DIR/Sources/App.swift" "$STAGING/MailNative.o" \
  -framework SwiftUI -framework AppKit -framework WebKit -framework Security -framework LocalAuthentication -framework Carbon -framework ImageIO -framework Network -framework CryptoKit -framework AuthenticationServices -framework UserNotifications -lcurl -lsqlite3 \
  -o "$APP/Contents/MacOS/MenDao"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -module-cache-path "$STAGING/module-cache" \
  "$PROJECT_DIR/Sources/Socket.swift" "$PROJECT_DIR/Sources/NativeHost.swift" \
  -o "$APP/Contents/MacOS/MenDaoBridge"
swift -module-cache-path "$STAGING/module-cache" "$PROJECT_DIR/Scripts/MakeIcon.swift" "$PROJECT_DIR" "$STAGING"
python3 "$PROJECT_DIR/Scripts/make_icns.py" "$STAGING/AppIcon.iconset" "$STAGING/AppIcon.icns"
cp "$PROJECT_DIR/Assets/AppIcon.png" "$APP/Contents/Resources/Mark.png"
cp "$STAGING/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$PROJECT_DIR/Resources/"* "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Docs/Downloads"
cp -R "$PROJECT_DIR/Docs/Downloads/"* "$APP/Contents/Resources/Docs/Downloads/"
mkdir -p "$APP/Contents/Resources/Docs/Mail"
cp -R "$PROJECT_DIR/Docs/Mail/"* "$APP/Contents/Resources/Docs/Mail/"
cp -R "$PROJECT_DIR/BrowserExtension" "$APP/Contents/Resources/BrowserExtension"
cp "$PROJECT_DIR/BrowserExtension/extension-id.txt" "$APP/Contents/Resources/extension-id.txt"
if (( $# > 0 )) && [[ "$1" == "--app-only" ]]; then cp "$PROJECT_DIR/Tests/UI.js" "$APP/Contents/Resources/UI.js"; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>cn.mendao.launcher</string>
<key>CFBundleName</key><string>搞门户</string>
<key>CFBundleDisplayName</key><string>搞门户</string>
<key>CFBundleExecutable</key><string>MenDao</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUM</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSSupportsAutomaticTermination</key><false/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSHumanReadableCopyright</key><string>搞门户</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>搞系列动作交接包</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSTypeIsPackage</key><true/>
<key>LSItemContentTypes</key><array><string>com.gaoseries.action-package</string></array>
</dict></array>
<key>UTImportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>com.gaoseries.action-package</string>
<key>UTTypeDescription</key><string>搞系列动作交接包</string>
<key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>gaoaction</string></array></dict>
</dict></array>
</dict></plist>
PLIST
# Keep local extended metadata out of distributable files.
xattr -cr "$APP"
for SIGN_PATH SIGN_BUNDLE_ID in "$APP/Contents/MacOS/MenDaoBridge" cn.mendao.bridge "$APP" cn.mendao.launcher; do
  SIGN_REQUIREMENT="identifier \"$SIGN_BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$SIGN_TEAM\""
  # The authorized development identity must be available in the real user
  # session. A sandbox lookup failure is never a reason to fall back to ad-hoc.
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$SIGN_BUNDLE_ID" \
    --requirements "=designated => $SIGN_REQUIREMENT" "$SIGN_PATH"
  codesign --verify --strict --test-requirement "=$SIGN_REQUIREMENT" "$SIGN_PATH"
  SIGN_DETAILS="$(codesign --display --verbose=4 "$SIGN_PATH" 2>&1)"
  [[ "$SIGN_DETAILS" == *"TeamIdentifier=$SIGN_TEAM"* ]] || { print -u2 '签名 Team 与授权身份不符，停止发行。'; exit 1; }
  SIGN_DR="$(codesign --display --requirements - "$SIGN_PATH" 2>&1)"
  [[ "$SIGN_DR" != *'cdhash '* ]] || { print -u2 '签名 DR 仍绑定旧 cdhash，停止发行。'; exit 1; }
done
# Capture the final signed code before the private staging container is removed.
# This inventory contains program identity/hashes only, never user data.
python3 - "$APP" <<'PY_AUDIT'
import hashlib, json, subprocess, sys
from pathlib import Path
app = Path(sys.argv[1])
magics = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'}
records = []
for path in sorted(app.rglob('*')):
    if not path.is_file():
        continue
    with path.open('rb') as stream:
        magic = stream.read(4)
    if magic not in magics:
        continue
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)
    display = subprocess.run(['codesign', '--display', '--verbose=4', '--requirements', '-', str(path)], check=True, capture_output=True, text=True)
    detail = display.stdout + display.stderr
    if 'TeamIdentifier=5G96498KGJ' not in detail or 'cdhash ' in detail:
        raise SystemExit('Final Mach-O has unexpected Team or unstable designated requirement')
    data = path.read_bytes()
    if (str(Path.home()) + '/').encode() in data:
        raise SystemExit('Final Mach-O contains a private build-home path')
    records.append({'path': str(path.relative_to(app)), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'signatureAndCompleteDR': detail.strip()})
if {x['path'] for x in records} != {'Contents/MacOS/MenDao', 'Contents/MacOS/MenDaoBridge'}:
    raise SystemExit('Unexpected final Mach-O inventory')
print('CANDIDATE_MACHO_INVENTORY=' + json.dumps(records, ensure_ascii=False, sort_keys=True))
PY_AUDIT
if (( $# > 0 )) && [[ "$1" == "--app-only" ]]; then
  ditto "$APP" "$DEST"
  print "APP=$DEST"
  exit 0
fi
mkdir -p "$PROJECT_DIR/Release" "$STAGING/disk"
: > "$STAGING/disk/.metadata_never_index"
ditto "$APP" "$STAGING/disk/搞门户.app"
ln -s /Applications "$STAGING/disk/Applications"
cp "$PROJECT_DIR/使用说明.txt" "$STAGING/disk/使用说明.txt"
xattr -cr "$STAGING/disk"
hdiutil create -quiet -volname "搞门户 V$VERSION" -srcfolder "$STAGING/disk" -format UDZO "$STAGING/GaoMenHu-$VERSION.dmg"
# The previous package is retained until installation and business verification
# succeed. Cleanup belongs to the verified upgrade-finalization step.
mv "$STAGING/GaoMenHu-$VERSION.dmg" "$PROJECT_DIR/Release/"
(cd "$PROJECT_DIR/Release" && shasum -a 256 "GaoMenHu-$VERSION.dmg" > "GaoMenHu-$VERSION.dmg.sha256")
print "完成：$PROJECT_DIR/Release/GaoMenHu-$VERSION.dmg"
