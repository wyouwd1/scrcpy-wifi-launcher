# scrcpy WiFi Launcher (Unofficial)

> **非官方项目（Unofficial）**：与 Genymobile 及 scrcpy 上游无隶属、赞助或背书关系。

**双击即连。** 一个 Windows 下的 scrcpy 启动器：自动在局域网里找到你的 Android 手机并投屏，WiFi 不可用时自动回退 USB。

<details>
<summary><b>English Quick Start</b></summary>

A Windows batch launcher for [scrcpy](https://github.com/Genymobile/scrcpy). Double-click and it finds your Android device over Wi-Fi — Android 11+ wireless debugging, classic `adb tcpip 5555`, USB-assisted setup, or a LAN scan — and falls back to USB when nothing works. Pure BAT + PowerShell 5.1: no Python, Node.js, Java or Android SDK.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/wyouwd1/scrcpy-wifi-launcher/main/install.ps1 -OutFile $env:TEMP\scrcpy-install.ps1; & $env:TEMP\scrcpy-install.ps1"
```

Then double-click the desktop shortcut. First-time wireless debugging requires one-time pairing on the phone (`adb pair <phone-ip>:<pair-port>`); see [Wi-Fi first-time pairing](#wifi-首次配对必读).

</details>

## 快速开始

Windows 10/11，在 PowerShell 中执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/wyouwd1/scrcpy-wifi-launcher/main/install.ps1 -OutFile $env:TEMP\scrcpy-install.ps1; & $env:TEMP\scrcpy-install.ps1"
```

装完双击桌面快捷方式。首次连 WiFi 需要在手机上配对一次，见 [WiFi 首次配对](#wifi-首次配对必读)。

## 特性

- **双击即用**：不用命令行，不用记 IP，不用每次手动 `adb connect`。
- **5 级 WiFi 发现**：已在线 TCP 设备 → mDNS 无线调试 → USB 辅助 `adb tcpip` → 局域网 /24 扫描 → 回退 USB。
- **端口不写死**：Android 11+ 的无线调试端口每次可能不同，启动器从 mDNS 实时读取。
- **连接必复核**：`adb connect` 返回成功不算数，逐台 `adb get-state` 确认 `device` 才采用。
- **失败有出口**：WiFi 全失败自动选 USB 设备；`SCRCPY_SERIAL` 可强制指定；出错窗口保留，不闪退。
- **参数透传**：`启动scrcpy.bat --max-size=1024 --video-codec=h264` 原样交给 scrcpy。
- **零运行时依赖**：纯 BAT + PowerShell 5.1，scrcpy 与 adb 都放在本地目录。
- **已实测**：WiFi 发现夹具测试 25 项通过（25 PASS / 0 FAIL / 2 SKIP，2 项因桌面 GUI 占用跳过）。

## 系统要求

| 项 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 / Windows 11（x64） |
| PowerShell | 5.1（系统自带，无需安装 PowerShell 7） |
| 手机 | Android 11+ 推荐无线调试；Android 5.0+ 可用 USB + `adb tcpip` |
| 网络 | 电脑与手机在同一局域网、同一子网，且路由器未开启 AP 隔离 |
| 权限 | 普通用户即可；安装到 `Program Files` 才需要管理员 |

> 不需要 Python、Node.js、Java 或 Android SDK。

## 安装

### 一条命令（推荐）

命令就是[快速开始](#快速开始)里那一条。脚本会完成四件事：

1. 下载 scrcpy 5.0.1 官方 win64 包（Genymobile release）。
2. 校验 SHA256，不匹配立即中止。
3. 解压到本地安装目录。
4. 放入 `启动scrcpy.bat` 与 `wifi-discover.ps1`，创建桌面快捷方式。

安装结束会打印实际安装目录，默认是 `%LOCALAPPDATA%\scrcpy-wifi-launcher`。后续命令都在该目录执行。

> 命令里的 `-ExecutionPolicy Bypass` 只对本次 PowerShell 进程生效，用来绕过 Windows 默认的 `Restricted` 策略，不修改系统设置。若电脑由公司 GPO / AppLocker 管控，该参数无效，请走「手动安装」或让 IT 放行。安装脚本本身开源，可先下载审阅再运行。

### 中国大陆网络

安装脚本**默认只从 GitHub 官方 release 下载**，不使用任何第三方镜像。如果 GitHub 下载很慢或连不上，可以显式指定镜像前缀（下载后仍会做 SHA256 校验）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/wyouwd1/scrcpy-wifi-launcher/main/install.ps1 -OutFile $env:TEMP\scrcpy-install.ps1; & $env:TEMP\scrcpy-install.ps1 -Mirror https://ghproxy.net"
```

也可以设环境变量 `SCRCPY_MIRROR`。镜像属于**你自己选择的信任对象**，本仓库不为其可用性或安全性背书；不想用镜像就走上面的手动安装。

### 连 install.ps1 都下载不动时

`raw.githubusercontent.com` 在部分网络完全不可达。改用 jsDelivr 拉安装脚本（后续步骤会自动回退到同一 CDN）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://cdn.jsdelivr.net/gh/wyouwd1/scrcpy-wifi-launcher@main/install.ps1 -OutFile $env:TEMP\scrcpy-install.ps1; & $env:TEMP\scrcpy-install.ps1"
```

### 启动器脚本的下载源

安装器需要下载 `start-scrcpy.bat`、`wifi-discover.ps1`、`uninstall.ps1` 三个脚本，会依次尝试：

1. `raw.githubusercontent.com`（GitHub 官方）
2. `cdn.jsdelivr.net`（jsDelivr CDN，国内一般可直连）

两个来源下载后都会做 SHA256 校验，哈希写死在 `install.ps1` 里，任何篡改都会被拒绝安装。所以即使 CDN 被劫持也无法注入代码。

### 手动安装

1. 下载官方包：<https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-win64-v5.0.1.zip>
2. 校验 SHA256：

   ```powershell
   Get-FileHash .\scrcpy-win64-v5.0.1.zip -Algorithm SHA256
   ```

   结果应为：

   ```text
   b12a2c4ee8be317422451fc7dcf8ee20a71b5ea7ef9ad73ddd825a25316227a5
   ```

3. 解压到任意目录，例如 `%LOCALAPPDATA%\scrcpy-wifi-launcher`。
4. 把本仓库的 `src\start-scrcpy.bat` 和 `src\wifi-discover.ps1` 复制到 `scrcpy.exe` 所在目录，并把 `start-scrcpy.bat` 重命名为 `启动scrcpy.bat`。
5. 双击 `启动scrcpy.bat`。

`启动scrcpy.bat`、`wifi-discover.ps1`、`scrcpy.exe`、`adb.exe` 四者必须在同一目录，启动器按自身路径定位它们。

> 首次运行被 SmartScreen 拦截：右键文件 → 属性 → 勾选"解除锁定" → 确定，再运行。

## 使用

双击 `启动scrcpy.bat` 或桌面快捷方式，先选连接方式：

```text
===============================
  选择连接方式
===============================
  1. WiFi  - 自动发现（可能较慢）
  2. USB   - 数据线，更流畅  [默认]
  Q. 退出

请选择 [1/2/Q]，15 秒内不操作默认 2：
```

| 按键 | 行为 |
| --- | --- |
| `1` | 走 WiFi 自动发现（5 级优先级，见下） |
| `2` 或 15 秒不操作 | 直接走 USB |
| `Q` | 退出 |

**WiFi 比 USB 延迟高、更容易卡**，这是无线传输的物理限制。要稳定低延迟就选 USB；WiFi 只适合不方便插线的场景。

选完会打印选中的设备和发现路径：

```text
[信息] 已选 WiFi 端点：192.168.1.100:37123   来源：mdns-tls-connect
[信息] 快捷键：Alt+o 熄屏，Alt+Shift+o 亮屏，Alt+p 电源键
```

`source` 的含义：

| source | 含义 |
| --- | --- |
| `existing-tcp` | 复用了 `adb devices` 中已在线的 `IP:端口` |
| `mdns-tls-connect` | Android 11+ 无线调试（`_adb-tls-connect._tcp`） |
| `mdns-adb` | 经典 `_adb._tcp` 服务 |
| `usb-tcpip` | 插着 USB，读到手机 WiFi IP 后执行 `adb tcpip` |
| `lan-scan` | 扫描本机所在 /24 网段找到的开放 adb 端口 |

常用调用：

```bat
rem 透传 scrcpy 参数
启动scrcpy.bat --max-size=1024 --max-fps=60

rem 直接走 USB，不显示选择菜单
启动scrcpy.bat --no-wifi

rem 直接走 WiFi，不显示选择菜单
启动scrcpy.bat --wifi

rem 自动化调用：不显示菜单、默认 USB、出错不等待按键
启动scrcpy.bat --no-pause

rem 自动化且要 WiFi
启动scrcpy.bat --wifi --no-pause

rem 只看 scrcpy 帮助，不触发设备发现
启动scrcpy.bat --help
```

默认窗口 580×1264（竖屏比例），用环境变量 `SCRCPY_WIDTH` / `SCRCPY_HEIGHT` 调整。

快捷键（scrcpy 默认，MOD 为左 Alt）：`MOD+o` 息屏、`MOD+Shift+o` 亮屏、`MOD+p` 电源键、`MOD+h` 主页。想把 MOD 改成左 Ctrl：`启动scrcpy.bat --shortcut-mod=lctrl`。

## WiFi 首次配对（必读）

**电脑无法远程打开手机的调试服务**，这是 Android 的安全限制，不是启动器的缺陷。首次走 WiFi 必须满足 A 或 B 之一。

### A. Android 11+：配对一次

1. 手机与电脑连同一个 WiFi。
2. 手机：设置 → 关于手机 → 连点"版本号"7 次，开启开发者选项。
3. 设置 → 系统 → 开发者选项 → 打开"无线调试"。
4. 进入"无线调试"→"使用配对码配对设备"，记下屏幕上的 **IP:配对端口** 和 6 位配对码。
5. 电脑上进入安装目录，执行：

   ```powershell
   .\adb.exe pair 192.168.1.100:41234
   ```

   按提示输入手机显示的 6 位配对码。
6. 配对成功后双击 `启动scrcpy.bat` 即可，启动器会自动从 mDNS 找到随机端口，不需要手填。

配对是一次性的。之后只要手机开着无线调试、且与电脑同网，就能自动连接。**手机重启、重新开关无线调试、切换 WiFi 后端口会变，但配对关系保留。**

### B. 有 USB 线：插一次就行

1. USB 连接手机与电脑。
2. 手机弹窗"允许 USB 调试吗？"→ 勾选"一律允许"→ 允许。
3. 双击 `启动scrcpy.bat`。启动器读取手机 WiFi IP，自动执行 `adb tcpip 5555`，之后走 WiFi，拔线不影响已建立的连接。

### C. 两者都没有

先完成 A 或 B。无线调试关闭、从未配对、USB 也未授权时，电脑没有任何合法途径连上手机。

配对排查：

- `failed to connect`：确认同网段、配对端口没抄错（**配对端口和连接端口不是一个**）、路由器没开 AP 隔离。
- `wrong pairing code`：配对码只在当前配对框有效，关闭后重新打开会生成新的码。
- 配对成功但 `adb devices` 没设备：`.\adb.exe mdns services` 看有没有 `_adb-tls-connect._tcp`；或锁屏后重新打开无线调试。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `SCRCPY_SERIAL` | 空 | 强制使用指定设备（序列号或 `IP:端口`）。设置后不再自动发现；设备不在线直接报错，**不回落**到其他设备 |
| `SCRCPY_WIDTH` | `580` | scrcpy 窗口宽度（像素） |
| `SCRCPY_HEIGHT` | `1264` | scrcpy 窗口高度（像素） |
| `SCRCPY_WIFI_PORT` | `5555` | USB 辅助与局域网扫描使用的 adb 端口；Android 11+ 无线调试端口由 mDNS 决定，不受此变量影响 |
| `SCRCPY_CONN` | 空 | `wifi` 或 `usb`，直接指定连接方式并跳过选择菜单。非法值会报错退出 |
| `SCRCPY_NO_WIFI` | 空 | 设为 `1` 跳过 WiFi 发现，只用 USB（等同 `--no-wifi` / `SCRCPY_CONN=usb`） |
| `SCRCPY_NO_LAN_SCAN` | 空 | 设为 `1` 关闭最后一级「局域网 /24 端口扫描」。公司网络、EDR 告警或不想让本机发起扫描时使用 |
| `SCRCPY_NO_PAUSE` | 空 | 设为 `1` 出错不暂停（等同 `--no-pause`） |

临时设置（仅当前 cmd 窗口有效）：

```bat
set SCRCPY_SERIAL=192.168.1.100:37123
启动scrcpy.bat
```

永久设置：`setx SCRCPY_SERIAL 192.168.1.100:37123`，新开窗口后生效。

## 常见问题

**1. 连不上，一直回退 USB 或报 `no adb device`**

按顺序检查：

1. 手机和电脑是否同一 WiFi、同一子网（双频路由器两个 SSID 也可能隔离）。
2. 手机"无线调试"是否开着，是否配对过。
3. `.\adb.exe mdns services` 有没有 `_adb-tls-connect._tcp`。
4. 路由器是否开了"AP 隔离 / 客户端隔离"。
5. 手机是否锁屏（部分机型锁屏后停掉无线调试）。

手动验证一次：

```powershell
.\adb.exe devices
.\adb.exe mdns services
.\adb.exe connect 192.168.1.100:37123
.\adb.exe -s 192.168.1.100:37123 get-state    # 必须输出 device
```

**2. 有多台设备，连错或提示 multiple devices**

启动器优先选 USB 设备（序列号不含 `:` 且不以 `emulator-` 开头），没有 USB 才取第一个在线设备。精确指定：

```bat
set SCRCPY_SERIAL=ABCDEF0123456789
启动scrcpy.bat
```

`.\adb.exe devices -l` 可看型号。注意：设了 `SCRCPY_SERIAL` 而该设备离线时，启动器会直接报错退出，这是刻意设计——静默换设备更容易连错。

**3. USB 插上没反应，或一直 `unauthorized`**

- 解锁手机，重新插拔，在弹窗点"允许 USB 调试"并勾选"一律允许"。
- 没弹窗：开发者选项里"撤销 USB 调试授权"再插一次；换数据线（很多线只能充电）；换 USB 口。
- 设备管理器有黄色感叹号：装手机厂商 USB 驱动或 Google USB Driver。
- 仍不行：`.\adb.exe kill-server` 后重试；再不行删除 `%USERPROFILE%\.android\adbkey` 和 `adbkey.pub` 重新授权（会让所有已授权电脑失效）。

**4. 昨天能连，今天端口变了**

Android 11+ 的无线调试端口是动态分配的，重新开关无线调试、重启手机、切换网络都会变。不要写死端口，启动器每次都从 mDNS 重新读。若手工连过旧端口，先 `.\adb.exe disconnect` 清掉。

经典 `adb tcpip 5555` 模式端口固定，但手机重启后需要重新执行一次（再插一次 USB，或重新配对）。

**5. 花屏、黑屏或报硬件解码错误**

先关硬解：

```bat
启动scrcpy.bat --hwdec=disabled
```

仍异常再换编码器：

```bat
启动scrcpy.bat --video-codec=h264 --hwdec=disabled
```

少数机型/驱动组合下 `--max-size=1024` 更稳。也可更新显卡驱动。这是 scrcpy 与显卡驱动的问题，与启动器无关。

**6. 杀毒软件报毒或 SmartScreen 拦截**

启动器会调用 `powershell -ExecutionPolicy Bypass` 并扫描局域网端口，这两点都是启发式查杀的常见触发条件。本项目不发布二进制、不重打包 scrcpy，安装脚本只从 Genymobile 官方 release 下载并校验 SHA256。

- 核对下载来源与 SHA256（见"手动安装"）。
- SmartScreen：右键文件 → 属性 → 解除锁定。
- 企业环境：把安装目录加入白名单，或直接手动安装。

**7. 双击窗口一闪而过**

默认只在出错时暂停。用 cmd 手动运行看完整输出：

```bat
cd /d "<安装目录>"
启动scrcpy.bat
```

带 `[错误]` 的那行就是原因。

**8. `adb` 版本冲突，连到了别的 adb server**

启动器只使用同目录的 `adb.exe`（37.0.1）。如果另装了 Android SDK 且 `adb` 在 PATH 中，5037 端口可能被旧 server 占用：

```powershell
.\adb.exe kill-server
.\adb.exe start-server
```

仍冲突就退出 Android Studio、手机助手类软件。

**9. 能连上但 scrcpy 窗口打不开或立刻退出**

先确认设备能执行命令：

```powershell
.\adb.exe -s ABCDEF0123456789 shell echo ok
```

再用 `启动scrcpy.bat --no-pause` 保留窗口看报错。常见原因是 scrcpy.exe 与 DLL 不同版本（不要单独替换 `SDL3.dll`、`avcodec-*.dll`），或安装目录里的 DLL 被杀软隔离。

**10. 怎么更新 scrcpy**

用新版官方 zip 重跑 `install.ps1`，或手动替换整个安装目录。不要只替换 `scrcpy.exe`：scrcpy 与 SDL / FFmpeg 运行库必须成套同版本。

## 故障排查

按顺序执行，多数问题在前两步就能定位：

```powershell
cd /d "<安装目录>"

# 1. adb server 与设备状态：device / unauthorized / offline
.\adb.exe start-server
.\adb.exe devices

# 2. mDNS 是否能看到无线调试服务
.\adb.exe mdns services

# 3. 手动连接并用 get-state 复核
.\adb.exe connect 192.168.1.100:37123
.\adb.exe -s 192.168.1.100:37123 get-state

# 4. 单独跑发现脚本，看它走了哪条路
powershell -NoProfile -ExecutionPolicy Bypass -File .\wifi-discover.ps1 -AdbPath .\adb.exe -Port 5555 -TimeoutSec 5

# 5. 最后才怀疑 scrcpy 本身
.\scrcpy.exe -s 192.168.1.100:37123 --pause-on-exit=if-error
```

`wifi-discover.ps1` 成功时输出两行：

```text
WIFI_ENDPOINT=192.168.1.100:37123
WIFI_SOURCE=mdns-tls-connect
```

失败时 stderr 有 `[wifi] ...` 信息。把这两段输出贴进 issue。

结果对照：

| 现象 | 结论 |
| --- | --- |
| `adb devices` 空，`adb mdns services` 也空 | 网络或配对问题，回到"WiFi 首次配对" |
| `adb devices` 有 `unauthorized` | USB 授权问题，见 FAQ 3 |
| `adb connect` 成功但 `get-state` 不是 `device` | 端口通但未授权/transport 未就绪，`adb disconnect` 后重新配对 |
| `adb devices` 正常但 scrcpy 报错 | scrcpy 或显卡驱动问题，见 FAQ 5、9 |

## 项目结构

```text
scrcpy-wifi-launcher/
├─ README.md                  # 本文件
├─ CONTRIBUTING.md            # 贡献指南
├─ CHANGELOG.md               # 变更记录
├─ SECURITY.md                # 安全策略
├─ LICENSE                    # Apache-2.0
├─ THIRD-PARTY-NOTICES.md     # 第三方组件声明
├─ install.ps1                # 一条命令安装
├─ uninstall.ps1              # 卸载
├─ .gitattributes             # 强制 BAT/PS1 使用 CRLF
├─ src/
│  ├─ start-scrcpy.bat        # 入口（GBK + CRLF），安装后改名 启动scrcpy.bat
│  └─ wifi-discover.ps1       # 5 级 WiFi 发现
├─ docs/
│  ├─ faq.md                  # 常见问题
│  ├─ how-it-works.md         # 原理与设计取舍
│  └─ 使用说明.md             # 快速上手
├─ scripts/
│  └─ publish.sh              # 维护者发布脚本
├─ tests/                     # 夹具测试
└─ .github/workflows/         # CI、release、stale
```

## 链接

- 本项目：<https://github.com/wyouwd1/scrcpy-wifi-launcher>
- 上游 scrcpy：<https://github.com/Genymobile/scrcpy>

## 许可证

本仓库的启动器脚本与文档采用 [Apache License 2.0](LICENSE)。

scrcpy 由 [Genymobile](https://github.com/Genymobile/scrcpy) 开发，版权 © 2018 Genymobile、© 2018-2026 Romain Vimont，按 Apache License 2.0 授权。本项目是**非官方社区项目**，不修改、不重打包 scrcpy 二进制；安装脚本仅从 Genymobile 官方 release 下载并按固定 SHA256 校验。adb 来自 Android SDK Platform Tools。第三方声明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

本项目与 Genymobile 无隶属、赞助或背书关系；scrcpy 名称归其各自所有者。本项目不使用 Genymobile/scrcpy 的 Logo 作为项目标识。
