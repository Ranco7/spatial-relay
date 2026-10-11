#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELAY_BUILD_DIR="${SPATIAL_RELAY_BUILD_DIR:-$PROJECT_DIR/build}"
RELAY_DIST_DIR="${SPATIAL_RELAY_DIST_DIR:-$PROJECT_DIR/dist}"
if [[ -e "$RELAY_DIST_DIR" ]]; then
    printf '输出目录已经存在，未覆盖：%s\n' "$RELAY_DIST_DIR" >&2
    exit 1
fi
mkdir -p "$RELAY_DIST_DIR/SpatialRelay"
RELAY_PACKAGE_DIR="$RELAY_DIST_DIR/SpatialRelay"
xcodebuild -quiet -project "$PROJECT_DIR/SpatialRelay.xcodeproj" \
    -scheme SpatialRelay -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$RELAY_BUILD_DIR" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
ditto "$RELAY_BUILD_DIR/Build/Products/Release/SpatialRelay.app" "$RELAY_PACKAGE_DIR/SpatialRelay.app"
codesign --force --sign "${SPATIAL_RELAY_SIGNING_IDENTITY:--}" \
    --identifier com.ranco7.SpatialRelay \
    --entitlements "$PROJECT_DIR/SpatialRelay/SpatialRelay.entitlements" \
    --options runtime "$RELAY_PACKAGE_DIR/SpatialRelay.app"
codesign --verify --strict "$RELAY_PACKAGE_DIR/SpatialRelay.app"
lipo "$RELAY_PACKAGE_DIR/SpatialRelay.app/Contents/MacOS/SpatialRelay" -verify_arch arm64
cp "$PROJECT_DIR/安装.command" "$PROJECT_DIR/卸载.command" "$PROJECT_DIR/查看状态.command" "$RELAY_PACKAGE_DIR/"
cp "$PROJECT_DIR/README.md" "$PROJECT_DIR/LICENSE" "$RELAY_PACKAGE_DIR/"
mkdir -p "$RELAY_PACKAGE_DIR/Scripts"
cp "$PROJECT_DIR/Scripts/paths.sh" "$PROJECT_DIR/Scripts/install.sh" "$PROJECT_DIR/Scripts/uninstall.sh" "$RELAY_PACKAGE_DIR/Scripts/"
ditto "$PROJECT_DIR/Configuration" "$RELAY_PACKAGE_DIR/Configuration"
ditto "$PROJECT_DIR/LaunchAgents" "$RELAY_PACKAGE_DIR/LaunchAgents"
chmod +x "$RELAY_PACKAGE_DIR/"*.command "$RELAY_PACKAGE_DIR/Scripts/"*.sh
ditto -c -k --sequesterRsrc --keepParent "$RELAY_PACKAGE_DIR" "$RELAY_DIST_DIR/SpatialRelay-0.3.0-arm64.zip"
(cd "$RELAY_DIST_DIR" && shasum -a 256 SpatialRelay-0.3.0-arm64.zip > SpatialRelay-0.3.0-arm64.zip.sha256)
