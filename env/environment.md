# 路径与环境

安装路径由 Scripts/paths.sh 统一定义，程序通过 macOS 的用户应用支持目录取得同一位置。
不需要管理员密码，不改默认声音输出。

| 变量 | 默认位置 |
| --- | --- |
| RELAY_SUPPORT_DIR | ~/Library/Application Support/SpatialRelay |
| RELAY_APP | $RELAY_SUPPORT_DIR/SpatialRelay.app |
| RELAY_CONFIG | $RELAY_SUPPORT_DIR/config.json |
| RELAY_AGENT_DIR | ~/Library/LaunchAgents |
| RELAY_AGENT | $RELAY_AGENT_DIR/com.ranco7.SpatialRelay.plist |
| RELAY_TRASH_DIR | ~/.Trash |
| 状态文件 | $RELAY_SUPPORT_DIR/status.json |

测试安装脚本可用 SPATIAL_RELAY_SUPPORT_DIR、SPATIAL_RELAY_AGENT_DIR、
SPATIAL_RELAY_TRASH_DIR 指定隔离位置，并设 SPATIAL_RELAY_INSTALL_TEST_ONLY=1，
只检查安装文件、不加载登录服务。日常安装不需要这些变量。

构建：Apple Silicon、macOS 14.2+、Xcode 16.4+；GitHub Actions 使用 macos-15 原生 arm64 runner。
设备验收目标：M4 / macOS 27 beta / AirPods Pro 3。CI 没有这副耳机，不能证明系统面板已亮起。
