# 变更记录

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 变更

- 启动器界面与 `wifi-discover.ps1` 的注释、报错全部改为中文；BAT 改用 GBK 编码（代码页 936），CRLF 换行不变。
- CI 的 BAT 门禁由“ASCII-only”改为“无 BOM 的 GBK 合法字节序列”，同步更新 `install.ps1` 内置的 payload SHA256。

## [1.0.0] - 2026-10-23

### 新增

- Windows 一键启动器 `启动scrcpy.bat`：启动时用菜单选择 WiFi / USB，自动选择设备、自动注入窗口尺寸、错误时暂停。
- WiFi 与 USB 的选择：`1` = WiFi，`2` 或 15 秒不操作 = USB（默认），`Q` = 退出。
- 非交互模式（`--no-pause`）默认 USB，不弹菜单；可用 `--wifi` 或 `SCRCPY_CONN=wifi` 覆盖。
- WiFi 自动发现 `wifi-discover.ps1`，五级优先级：
  1. 复用 `adb devices` 中已在线 TCP/IP 设备
  2. `adb mdns services` 的 `_adb-tls-connect._tcp`（Android 11+ 无线调试）
  3. `adb mdns services` 的 `_adb._tcp`（经典 `adb tcpip`）
  4. USB 辅助：读取手机 WiFi IP 并执行 `adb tcpip`
  5. 本机所在 `/24` 网段 5555 端口探测
- 全部失败时自动回退 USB，不影响原有工作流。
- 环境变量覆盖：`SCRCPY_SERIAL`、`SCRCPY_WIDTH`、`SCRCPY_HEIGHT`、`SCRCPY_NO_WIFI`、`SCRCPY_WIFI_PORT`、`SCRCPY_NO_LAN_SCAN`。
- 命令行开关：`--no-wifi`、`--no-pause`。
- `install.ps1`：下载官方 scrcpy、SHA256 校验、部署、创建桌面快捷方式。
- GitHub Actions：CI 静态检查 + 测试，tag 触发自动发布。

### 安全

- 安装器**默认只从 GitHub 官方 release 下载**；第三方镜像必须显式 `-Mirror` 或 `SCRCPY_MIRROR` 开启，且仍做 SHA256 校验。
- 安装器内置 `src/start-scrcpy.bat`、`src/wifi-discover.ps1`、`uninstall.ps1` 的 SHA256；从网络拉取时逐个校验，不匹配立即中止。CI 会检查内置哈希与实际文件一致。
- 局域网 `/24` 端口扫描可用 `SCRCPY_NO_LAN_SCAN=1` 关闭，适合公司网络、EDR 告警或不想让本机发起扫描的场景。
- 卸载与 `-Force` 覆盖安装会拒绝用户主目录下的桌面/文档/下载等常用目录，避免误删用户数据。

### 已知限制

- Android 11+ 首次使用必须在手机上完成一次「无线调试 → 使用配对码配对」或用 USB 连接一次，这是 Android 的安全设计，无法绕过。
- 局域网扫描只能发现经典 `adb tcpip 5555`，发现不了 Android 11+ 的随机 TLS 端口；后者依赖 mDNS。
- mDNS 在开启 AP 隔离、双频分离或纯 IPv6 的网络中可能失效，此时回退 USB。
