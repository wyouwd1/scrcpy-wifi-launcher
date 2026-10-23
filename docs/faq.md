# 常见问题（FAQ）

按主题分组：连接与配对、设备状态、画面与音频、其他。每条都给出可直接执行的排查命令。

> 命令默认在安装目录执行。若 `adb` 不在 PATH，用 `.\adb.exe`。

## 连接与配对

### 1. 这个启动器和直接双击 `scrcpy.exe` 有什么区别？

`scrcpy.exe` 只接受已经连上的设备。启动器先把设备找出来：复用已在线连接、查 mDNS 无线调试、用 USB 辅助切 `adb tcpip`、扫局域网，最后才回退 USB；它还会把窗口尺寸、出错暂停这些常用参数配好。

### 2. 为什么第一次用 WiFi 必须配对，或者先插一次 USB？

Android 不允许电脑远程打开手机的调试服务。无线调试在 Android 11+ 走 TLS，电脑必须先通过配对码把自己的 adb 公钥交给手机；Android 11 以下则要先 USB 授权再执行 `adb tcpip`。没有这两步之一，手机根本不会监听可连接的调试端口。

### 3. `adb pair` 显示成功，`adb connect` 还是失败？

最常见的原因是**用错了端口**。配对端口只用于 `adb pair`，连接要用另一个端口：

```powershell
.\adb.exe mdns services
```

在输出里找 `_adb-tls-connect._tcp` 那一行的 `IP:端口`，再 `connect`。若 mDNS 没有输出，回手机"无线调试"主页面看"IP 地址和端口"。

其他原因：手机和电脑不同子网、配对后手机关了无线调试、路由器 AP 隔离。

### 4. 配对端口和连接端口为什么不一样？

Android 11+ 会为配对和连接分别开两个随机端口：`_adb-tls-pairing._tcp` 用于配对（一次性），`_adb-tls-connect._tcp` 用于日常连接。配对完成后配对端口通常立即关闭，拿它去 `connect` 一定失败。

### 5. 手机重启后需要重新配对吗？

不需要。配对关系保存在手机里，重启、开关无线调试、切换 WiFi 都不会丢。变的是**端口**，启动器会自动重新发现。

只有这几种情况需要重新配对：在手机上"撤销 USB 调试授权"或清除 adb 授权、恢复出厂设置、删除电脑上的 `%USERPROFILE%\.android\adbkey`。

### 6. 换了 WiFi 或路由器后就连不上？

先确认三件事：手机和电脑在同一子网（`ipconfig` 对比手机 WiFi 详情里的 IP 与掩码）；路由器没开 AP 隔离/访客网络隔离；手机无线调试仍开着。

换了网段后旧连接会失效，执行一次：

```powershell
.\adb.exe disconnect
```

再双击 `启动scrcpy.bat`。

### 7. 公司、酒店、学校的 WiFi 能用吗？

多数不能。这类网络常开启客户端隔离，设备之间无法互访，mDNS 组播也常被屏蔽。可行的替代：

- 用手机开热点，电脑连手机热点（同一子网，通常不隔离）。
- 插 USB 使用，或用 USB 辅助切到 `adb tcpip` 后连接手机热点地址。
- 自备便携路由器。

### 8. 无线调试开关是灰色的，打不开？

- 先确认开发者选项已开启（连点"版本号"7 次）。
- 部分机型要求先登录小米/华为账号，或插入 SIM 卡。
- 开启了"USB 调试（安全设置）"或企业 MDM 策略时会被禁用，需在设置里关闭对应限制。
- 个别定制系统把入口放在"开发者选项 → 调试 → 无线调试"。

## 设备状态

### 9. `adb devices` 显示 `unauthorized`

手机没有信任这台电脑。解锁手机，重新插拔 USB，在"允许 USB 调试吗"弹窗点允许并勾选"一律允许"。

没弹窗时依次尝试：开发者选项 → "撤销 USB 调试授权" → 重新插拔；换数据线；换 USB 口；`.\adb.exe kill-server` 后重试。

### 10. `adb devices` 显示 `offline`

传输通道建立了但设备无响应。依次尝试：

```powershell
.\adb.exe disconnect
.\adb.exe kill-server
.\adb.exe start-server
```

仍 offline：重启手机，或换 USB 口/数据线。无线连接下 offline 多半是手机休眠或 WiFi 掉线。

### 11. `adb connect` 显示 `connected`，但 scrcpy 说 `no devices`

`adb connect` 的退出码只代表 TCP 连接建立，不代表设备已授权可用。必须复核：

```powershell
.\adb.exe -s 192.168.1.100:37123 get-state
```

输出 `device` 才算成功；输出 `unauthorized` 要重新配对，`offline` 要 `disconnect` 重连，`unknown` 多半是端口上根本不是 adb 服务（连到了路由器或其他程序）。

启动器内部就是这么判断的，所以它不会把"假 connected"当成成功。

### 12. 有多台设备，怎么指定其中一台？

```bat
set SCRCPY_SERIAL=ABCDEF0123456789
启动scrcpy.bat
```

序列号用 `.\adb.exe devices -l` 查。不设置时启动器优先选 USB 设备，没有 USB 才取第一台在线设备，并在有多台时打印提示。

注意：设了 `SCRCPY_SERIAL` 但设备不在线，启动器会直接报错退出，不会偷偷换一台。

### 13. Android 11 以下能用无线吗？

能，但没有"无线调试"配对界面，必须先 USB：

1. USB 连接并授权调试。
2. 执行 `.\adb.exe tcpip 5555`。
3. 拔线，双击 `启动scrcpy.bat`。

手机重启后 `tcpip` 模式失效，需要再插一次 USB，或 root 后用 `setprop service.adb.tcp.port 5555` 持久化。

## 画面与音频

### 14. 画面卡顿、延迟高？

按影响从大到小：

1. 用 5GHz WiFi，别用 2.4GHz；电脑尽量有线连路由器。
2. 关掉手机省电模式，保持屏幕常亮。
3. 降码率或帧率：`启动scrcpy.bat --video-bit-rate=4M --max-fps=30`。
4. 降分辨率：`启动scrcpy.bat --max-size=1024`。
5. 关闭其他占用 WiFi 带宽的程序。

WiFi 投屏的延迟受路由器和干扰影响很大，无法给出固定数值。

### 15. 没有声音，或声音卡顿？

scrcpy 5.x 默认转发音频，需要 Android 11+。检查：

- 手机媒体音量不是 0。
- `启动scrcpy.bat --audio-codec=opus` 或 `--audio-codec=aac` 换编码器。
- 部分机型不支持音频捕获，用 `--no-audio` 关闭音频转发，改走蓝牙/扬声器。

### 16. 花屏、黑屏、报硬件解码错误？

先禁用硬解：

```bat
启动scrcpy.bat --hwdec=disabled
```

仍异常再指定编码器：

```bat
启动scrcpy.bat --video-codec=h264 --hwdec=disabled
```

少数驱动组合下 `--max-size=1024` 能绕过。也可以更新显卡驱动。这是 scrcpy 与 GPU 驱动的问题，与启动器无关。

## 其他

### 17. 端口 5555 被占用，或 `adb connect` 连到了别的设备？

5555 只用于 USB 辅助和局域网扫描。手机侧端口被占用时，改一个：

```bat
set SCRCPY_WIFI_PORT=5556
启动scrcpy.bat
```

但要先确认手机确实在 5556 上监听（`adb tcpip 5556`）。Android 11+ 无线调试不受此变量影响，端口由系统随机分配。

连到别的设备时：`.\adb.exe devices` 看清单，用 `SCRCPY_SERIAL` 指定，或 `.\adb.exe disconnect <错误端点>`。

### 18. 杀毒软件报毒，或 SmartScreen 拦截下载？

启动器会调用 `powershell -ExecutionPolicy Bypass` 并做局域网端口扫描，容易被启发式规则命中。本项目不发布 exe、不重打包 scrcpy，安装脚本只从 Genymobile 官方 release 下载并校验 SHA256。

处理：核对 SHA256；SmartScreen 选"更多信息 → 仍要运行"或右键属性解除锁定；企业环境把安装目录加白名单。

### 19. 怎么更新或卸载？

更新：用新版官方 zip 重跑 `install.ps1`，或整个目录替换。不要只换 `scrcpy.exe`，SDL / FFmpeg 运行库必须同版本。

卸载：运行 `uninstall.ps1`（仓库根目录或安装目录）；手动安装的直接删除安装目录，再删桌面快捷方式和 `%USERPROFILE%\.android` 下的授权文件（可选）。

### 20. 能同时投屏多台手机吗？

可以。启动器一次只拉起一个 scrcpy 窗口，开多个 cmd 窗口分别指定设备即可：

```bat
set SCRCPY_SERIAL=ABCDEF0123456789
启动scrcpy.bat

rem 另一个窗口
set SCRCPY_SERIAL=ABCDEF0123456788
启动scrcpy.bat
```

每台手机都要各自完成配对或 USB 授权。多路 WiFi 投屏会争抢带宽，建议降到 `--max-size=1024`。
