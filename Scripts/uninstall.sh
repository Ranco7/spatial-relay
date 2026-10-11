#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/paths.sh"
printf '卸载会停止音频桥，恢复应用原声，并把应用、配置与登录自启动文件移入废纸篓。\n文件可以从废纸篓找回；恢复文件后需重新加载登录服务。\n'
if [[ "${SPATIAL_RELAY_INSTALL_TEST_ONLY:-0}" != "1" ]] && launchctl print "gui/$(id -u)/$RELAY_LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$RELAY_LABEL"
fi
mkdir -p "$RELAY_TRASH_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
if [[ -e "$RELAY_AGENT" ]]; then
    mv "$RELAY_AGENT" "$RELAY_TRASH_DIR/SpatialRelay-LaunchAgent-$STAMP.plist"
fi
if [[ -e "$RELAY_SUPPORT_DIR" ]]; then
    mv "$RELAY_SUPPORT_DIR" "$RELAY_TRASH_DIR/SpatialRelay-$STAMP"
fi
printf '卸载完成，文件已移入废纸篓。\n'
