#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$PROJECT_DIR/VERSION" | tr -d '\n')"
BUILD_NUM="$(print "$VERSION" | tr -d '.')"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]{2}$' ]]; then print -u2 "VERSION 格式必须为 1.00"; exit 1; fi
STAGING="$(mktemp -d /private/tmp/mendao-build.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/搞门户.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$STAGING/module-cache"
TEST_FLAGS=()
if (( $# > 0 )) && [[ "$1" == "--app-only" ]]; then TEST_FLAGS=(-D DEBUG_TESTING); fi
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -module-cache-path "$STAGING/module-cache" \
  "$TEST_FLAGS[@]" "$PROJECT_DIR/Tests/UITesting.swift" "$PROJECT_DIR/Tests/NativeFeatureTests.swift" \
  "$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Sources/Vault.swift" "$PROJECT_DIR/Sources/Socket.swift" \
  "$PROJECT_DIR/Sources/BridgeServer.swift" "$PROJECT_DIR/Sources/IconLoader.swift" "$PROJECT_DIR/Sources/LibraryOperations.swift" "$PROJECT_DIR/Sources/Features.swift" "$PROJECT_DIR/Sources/App.swift" \
  -framework AppKit -framework WebKit -framework Security -framework LocalAuthentication -framework Carbon -framework ImageIO \
  -o "$APP/Contents/MacOS/MenDao"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -module-cache-path "$STAGING/module-cache" \
  "$PROJECT_DIR/Sources/Socket.swift" "$PROJECT_DIR/Sources/NativeHost.swift" \
  -o "$APP/Contents/MacOS/MenDaoBridge"
swift -module-cache-path "$STAGING/module-cache" "$PROJECT_DIR/Scripts/MakeIcon.swift" "$PROJECT_DIR" "$STAGING"
python3 "$PROJECT_DIR/Scripts/make_icns.py" "$STAGING/AppIcon.iconset" "$PROJECT_DIR/Assets/AppIcon.icns"
cp "$PROJECT_DIR/Assets/AppIcon.png" "$APP/Contents/Resources/Mark.png"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/"* "$APP/Contents/Resources/"
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
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>搞门户</string>
</dict></plist>
PLIST
# Keep local extended metadata out of distributable files.
xattr -cr "$APP"
codesign --force --sign - --identifier cn.mendao.bridge "$APP/Contents/MacOS/MenDaoBridge"
codesign --force --sign - --identifier cn.mendao.launcher "$APP"
codesign --verify --strict "$APP"
if (( $# > 0 )) && [[ "$1" == "--app-only" ]]; then
  DEST="$2"
  ditto "$APP" "$DEST"
  print "APP=$DEST"
  exit 0
fi
mkdir -p "$PROJECT_DIR/Release" "$STAGING/disk"
ditto "$APP" "$STAGING/disk/搞门户.app"
ln -s /Applications "$STAGING/disk/Applications"
cp "$PROJECT_DIR/使用说明.txt" "$STAGING/disk/使用说明.txt"
xattr -cr "$STAGING/disk"
hdiutil create -quiet -volname "搞门户 V$VERSION" -srcfolder "$STAGING/disk" -format UDZO "$STAGING/GaoMenHu-$VERSION.dmg"
# Remove previous project release packages only after the new package succeeds.
find "$PROJECT_DIR/Release" -maxdepth 1 -type f \( -name '搞门户-V*.dmg' -o -name '门道-V*.dmg' -o -name 'GaoMenHu-*.dmg' -o -name 'GaoMenHu-*.dmg.sha256' \) -delete
find "$PROJECT_DIR/Release" -maxdepth 1 -type f -name '验证结果-V*.json' ! -name "验证结果-V$VERSION.json" -delete
mv "$STAGING/GaoMenHu-$VERSION.dmg" "$PROJECT_DIR/Release/"
(cd "$PROJECT_DIR/Release" && shasum -a 256 "GaoMenHu-$VERSION.dmg" > "GaoMenHu-$VERSION.dmg.sha256")
print "完成：$PROJECT_DIR/Release/GaoMenHu-$VERSION.dmg"
