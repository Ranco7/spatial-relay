# 空间音频桥

这是 Spatial Relay 的后台版本。默认自动接管网易云音乐和 Google Chrome。
安装后没有菜单栏图标、Dock 图标或常驻窗口。登录后自动运行。
日常只操作 macOS 耳机面板里的“关闭、固定、头部追踪”。

**当前属于待 AirPods 实机验收的测试版。**
构建和自动测试通过，也不能证明 M4、macOS 27 beta、AirPods Pro 3 的系统面板已经亮起。

## 下载与安装

打开本仓库的 [Releases（发布版本）](https://github.com/Ranco7/spatial-relay/releases)，
下载最新测试版的 SpatialRelay-0.3.0-arm64.zip。不要下载 Source code（源码压缩包）。

1. 双击 ZIP 解压，打开 SpatialRelay 文件夹。
2. 双击“安装.command”。弹出的终端会显示安装位置，完成后可以关掉终端。
3. 戴上并连接 AirPods。在 Mac 控制中心的声音面板中，把 AirPods 选为声音输出。
4. 在网易云或 Chrome 播放音频。系统首次询问音频录制权限时，选择允许。
5. 打开系统耳机面板，检查“空间化立体声”是否出现“关闭、固定、头部追踪”，点击“固定”。

安装包使用本地临时签名（ad-hoc），没有苹果开发者证书与公证。
如果系统拦截打开，在系统设置的“隐私与安全性”中查看提示。
不会自动删除隔离标记、关闭 Gatekeeper 或改系统隐私数据库。
权限未通过前，不能保证捕获有声；拒绝后请在系统设置的音频录制权限中允许“空间音频桥”。

安装脚本不覆盖已有安装或配置，不生成备份。更换版本时，先运行旧包的“卸载.command”。
卸载会停止服务，把应用、配置和自启动文件移入废纸篓；不会硬删除。
安装位置统一定义在 [环境说明](env/environment.md)。

## 最短实机验收

连接 AirPods，依次测试网易云歌曲、Chrome 网页音视频。
播放时系统耳机面板必须能点击“固定”和“头部追踪”，且音频只有一份。
切换两种模式后服务继续工作。退出并重开目标应用、断开并重连耳机、休眠并唤醒后，也应恢复。

持续播放至少 20 分钟，确认音高稳定、没有周期性抖动或明显延迟增长。
Chrome 视频会增加桥接延迟，目前使用约 80 毫秒预缓冲；没有视频时间戳，
不能保证所有视频完全唇音同步。

如果面板仍显示“不可用”，双击“查看状态.command”，先检查：
active 表示是否正在接管；capturedFrames 是累计捕获帧数；
callbacks 是系统回调次数；droppedFrames 是丢帧数，正常应为 0。
状态文件明确标注 nativeSpatialAudioMenuVerified=false，因为程序不会把内部状态当成系统界面验收。
状态文件仅包含设备和进程信息，没有音频内容。

## 音频与时钟

播放路径为：

目标应用及其辅助进程 → Core Audio Process Tap → Float32 PCM 内存缓冲
→ AVSampleBufferAudioRenderer → 系统输出 AirPods。

捕获名单使用 Core Audio 的 AudioObjectID，不把 PID 当成音频对象。
通过进程实际可执行文件所属的外层 .app 识别应用家族。
没有系统全局捕获，音频不写入磁盘、不上传。
捕获期间用 mutedWhenTapped 静音目标应用原始输出；正常停止和故障会释放捕获、恢复原声。

捕获后不加入有损编码、EQ、归一化、增益或采样率转换。
平面声道转为交错排列时只复制样本，保持 Float32 字节。
设备定向捕获不开立体声 mixdown，保留捕获点实际提供的声道数和采样率。
支持 1～32 个 PCM 声道；多声道必须有输出设备提供的真实声道布局，否则停止接管并保留原声。
应用或 Core Audio 在捕获点之前已做的混音、音量处理或降混无法撤销。
AirPods 本身是双声道设备，不能据此声称保留了源文件的 Atmos 对象信息或原始多声道。

renderer 明确允许 mono、stereo 和 multichannel 空间化。
聚合设备包含实际输出设备，使用其作为 main sub-device 时钟源，读取确认配置和采样率。
tap 与物理输出的漂移补偿均关闭；程序不主动重采样。
聚合设备的物理输入和输出流在启动前禁用并核对，只读取指定应用的 tap。
AVFoundation 仍直接输出到 AirPods，使用苹果原生渲染。
这一时钟配置降低捕获与输出自由漂移风险，不能保证苹果内部不存在重采样，也不能代替蓝牙实测。

主输出流固定为 stream 0；目标应用明确输出到其他设备、受保护内容、
系统拒绝捕获、耳机不支持系统空间音频等情况不保证接管。
没有采用私有接口强行打开系统按钮。

## 运行与配置

两款目标应用默认同时接管，无日常开关或控制界面。
高级目标名单存在安装目录的 config.json 中；安装后无需编辑。
程序会重新读取修改后的配置。配置错误时停止接管，避免意外监听。
重命名耳机导致自动名称识别失败时，可设置 outputDeviceUID，
其值可通过程序的 --diagnose（只读诊断）获取；不改变系统默认输出。

硬件与进程通知触发重新发现，另有每 2 秒一次的低频检查。
辅助进程更换时更新同一个 tap 的名单。
耳机断开、采样率改变、应用退出、渲染故障和休眠都会释放或重建捕获。
失败重试从 5 秒递增到 60 秒；LaunchAgent 的崩溃重启有 30 秒限速。

## 开发与验证

保留上游 Xcode 项目、MIT 许可证、实时 SPSC 环形缓冲和 renderer 恢复逻辑。
旧菜单 UI 源文件保留供对照，已从构建目标移除。

GitHub Actions 在原生 arm64 Mac 上执行测试、静态分析、Release 构建、
PCM 字节检查、只读诊断、后台空闲运行及安装/卸载脚本检查。
全部通过后，上传安装包并发布带提交编号的测试版。
云端运行没有 AirPods，原生系统面板和蓝牙长期播放仍需按上面的步骤验收。

上游：[shevlfs/spatial-relay](https://github.com/shevlfs/spatial-relay)，基线提交
399d19696d25e9ca918eecde2ff0579512d1ba73，MIT 许可证。
苹果 API：[CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)、
[allowedAudioSpatializationFormats](https://developer.apple.com/documentation/avfoundation/avsamplebufferaudiorenderer/allowedaudiospatializationformats)。
