#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/paths.sh"
if [[ "$(uname -m)" != "arm64" ]]; then
    printf '需要 Apple Silicon Mac。\n' >&2
    exit 1
fi
if [[ -e "$RELAY_SUPPORT_DIR" || -e "$RELAY_AGENT" ]]; then
    printf '安装位置已有文件，未覆盖。若要更换版本，请先运行原安装包的卸载脚本。\n%s\n' "$RELAY_SUPPORT_DIR" >&2
    exit 1
fi
if [[ ! -d "$PACKAGE_DIR/SpatialRelay.app" ]]; then
    printf '请使用 GitHub 下载的完整安装包；源码压缩包里没有编译好的应用。\n' >&2
    exit 1
fi
codesign --verify --strict "$PACKAGE_DIR/SpatialRelay.app"
printf '安装应用与配置：%s\n登录自启动文件：%s\n' "$RELAY_SUPPORT_DIR" "$RELAY_AGENT"
mkdir -p "$RELAY_SUPPORT_DIR" "$RELAY_AGENT_DIR"
ditto "$PACKAGE_DIR/SpatialRelay.app" "$RELAY_APP"
cp "$PACKAGE_DIR/Configuration/config.json" "$RELAY_CONFIG"
cp "$PACKAGE_DIR/LaunchAgents/com.ranco7.SpatialRelay.plist" "$RELAY_AGENT"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $RELAY_EXECUTABLE" "$RELAY_AGENT"
plutil -lint "$RELAY_AGENT" >/dev/null
chmod 600 "$RELAY_AGENT" "$RELAY_CONFIG"
"$RELAY_EXECUTABLE" --check-config
if [[ "${SPATIAL_RELAY_INSTALL_TEST_ONLY:-0}" != "1" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$RELAY_AGENT"
    launchctl print "gui/$(id -u)/$RELAY_LABEL" >/dev/null
    printf '安装完成，已静默运行并设为登录自动启动。\n连接 AirPods，播放网易云或 Chrome；首次系统音频录制提示请选择允许。\n随后只需在系统耳机面板选择「固定」或「头部追踪」。\n'
else
    printf '安装文件校验完成（测试模式未启动服务）。\n'
fi
