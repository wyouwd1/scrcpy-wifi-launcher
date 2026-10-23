# 工作原理

这份文档解释三件事：启动器按什么顺序找设备、为什么 Android 11+ 的端口每次都变、为什么"连接成功"还要再验一次。想改 `wifi-discover.ps1` 或判断某个失败是不是 bug，先看这里。

## 一次双击发生了什么

```text
启动scrcpy.bat
  │
  ├─ 定位同目录的 scrcpy.exe / adb.exe / wifi-discover.ps1
  ├─ adb start-server
  ├─ 有 SCRCPY_SERIAL？──是──> get-state 校验，失败即退出（不回落）
  │
  ├─ 调用 wifi-discover.ps1（-TimeoutSec 5）
  │     ├─ 1. 复用已在线 TCP 设备        source=existing-tcp
  │     ├─ 2. mDNS 无线调试              source=mdns-tls-connect / mdns-adb
  │     ├─ 3. USB 辅助 adb tcpip         source=usb-tcpip
  │     └─ 4. 局域网 /24 扫描            source=lan-scan
  │
  ├─ 拿到 WIFI_ENDPOINT？──是──> 用它启动 scrcpy
  │
  └─ 否 ──> 5. 回退 USB 设备选择（优先非 TCP、非模拟器）
              └─ 仍无设备 ──> 报错，提示无线调试与 adb pair
```

BAT 与 PowerShell 的分工：BAT 负责开关解析、设备回退、启动 scrcpy；PowerShell 只负责"找到一个可用端点"，成功时向 stdout 写两行固定格式，BAT 用临时文件解析。

```text
WIFI_ENDPOINT=192.168.1.100:37123
WIFI_SOURCE=mdns-tls-connect
```

退出码非 0 时，BAT 会丢弃这两行并回退 USB。

## 5 级优先级

顺序不是随便排的：越靠前越快、副作用越小、确定性越高。

### 第 1 级：复用已在线 TCP 设备

```text
adb devices  →  serial 含 ":" 且 state=device  →  adb -s ABCDEF0123456789 get-state
```

成功来源标记 `existing-tcp`。

`adb devices` 的列表可能已经过期（设备刚掉线、adbd 刚重启），所以不能只看列表，必须再 `get-state` 一次。这一级不发起网络探测，只查本机 adb server；能命中就绝不往下走。

### 第 2 级：mDNS 无线调试

```text
adb mdns services
  → 解析 _adb-tls-connect._tcp（优先）
  → 再解析 _adb._tcp
  → 逐个 adb connect + get-state
```

成功来源标记 `mdns-tls-connect` 或 `mdns-adb`。

解析规则：每行按空白切成三段以上，第二段是服务类型，最后一段是 `IP:端口`。服务类型只认上面两种，其余（如 `_adb-tls-pairing._tcp`）直接忽略——配对端口不能用来连接。

排序规则：`_adb-tls-connect._tcp` 优先级 0，`_adb._tcp` 优先级 1，同优先级按 adb 输出顺序。先 TLS 是因为它对应 Android 11+ 官方无线调试；`_adb._tcp` 是较早的 adb mDNS 服务名，是否广播取决于设备与 adb 版本。

mDNS 在 Windows 上并不总是可靠：Bonjour 服务冲突、防火墙拦 UDP 5353、虚拟网卡多播路由错误都会让 `adb mdns services` 返回空。所以这一级失败很正常，不是异常。

### 第 3 级：USB 辅助 `adb tcpip`

```text
找一个 state=device 且 serial 不含 ":"、不以 emulator- 开头的设备
  → adb -s <usb-serial> shell ip route        （找 wlan 的 src）
  → 失败则 adb -s <usb-serial> shell ip addr show wlan0
  → adb -s <usb-serial> tcpip <port>          （默认 5555）
  → 等 2000 ms
  → adb connect <wifi-ip>:<port> + get-state
  → 失败再等 1000 ms 重试
```

成功来源标记 `usb-tcpip`。

两个细节：

- **为什么要等 2 秒**：`adb tcpip` 会让手机端 adbd 从 USB 模式切到 TCP 监听模式，进程要重启并重新绑定端口。立刻 connect 多半是 `Connection refused`。
- **为什么读两个命令**：`ip route` 在部分机型/Android 版本上不显示 `src`，`ip addr show wlan0` 是兜底；两个都只接受私有 IPv4，避免把蜂窝网或 VPN 地址当成局域网地址。

这一级有副作用：它改变了手机的 adbd 监听状态（直到重启）。所以它排在 mDNS 之后——能不动手机就不动。

### 第 4 级：局域网 /24 扫描

```text
枚举本机网卡
  → 只保留 Wireless80211 / Ethernet、状态 Up、非虚拟网卡
  → 只保留私有 IPv4 且掩码为 255.255.255.0
  → 对每个 /24 的 1..254 并发 TCP connect（预算 2800 ms）
  → 对开放主机最多 16 个执行 adb connect + get-state（每个 2 s，不重试）
```

成功来源标记 `lan-scan`。

虚拟网卡过滤名单：WSL、Hyper-V、vEthernet、VMware、VirtualBox、Loopback、Teredo、isatap、Docker、podman、Wintun、Tailscale、ZeroTier、VPN、TAP-、Npcap、Bluetooth、Wi-Fi Direct。不排除的话，WSL 的 `172.x` 和 Hyper-V 的虚拟网段会浪费掉全部扫描预算。

只扫 /24 是因为家用/办公网络绝大多数是 /24；扫 /16 是 65534 个地址，在 2.8 秒内不可能完成，只会制造噪音。掩码不是 /24 的网卡直接跳过，宁可不扫也不乱扫。

最多只对 16 个开放主机做 `adb connect`：一个网段里可能有一堆开了 5555 的设备（打印机、树莓派、其他 adb 服务），逐个试会耗光总预算。

### 第 5 级：回退 USB

这一级在 BAT 里，不在 PowerShell 里。逻辑：

1. 统计 `adb devices` 中 `device` / `unauthorized` / `offline` 的数量。
2. 优先选"看起来像 USB"的序列号：不含 `:`、不以 `emulator-` 开头。
3. 没有 USB 就取第一个 `device`。
4. 一个都没有 → 打印计数、提示无线调试与 `adb pair`、返回 1。

如果用户显式设了 `SCRCPY_SERIAL`，这一整套自动选择都不执行：只校验指定设备，失败就退出。这是为了避免"以为连的是 A，实际投屏到 B"。

## 时间预算

| 项 | 值 | 位置 |
| --- | --- | --- |
| 发现总预算 | 13 000 ms | `$script:TotalBudgetMs` |
| 局域网扫描预算 | 2 800 ms | `$script:ScanBudgetMs` |
| 单条 adb 命令超时 | 5 000 ms（BAT 传入 `-TimeoutSec 5`） | `启动scrcpy.bat` |
| USB 辅助等待 | 2 000 ms + 1 000 ms 重试 | `Try-UsbAssist` |
| connect 后复核重试间隔 | 250 ms | `Connect-Endpoint` |

每条 adb 调用前都会检查剩余预算，超预算直接返回失败，不会让双击后的窗口卡死。所有 adb 子进程都带超时和 `Kill`，不会留下僵尸进程。

## 为什么 Android 11+ 的端口是随机的

Android 11 之前，`adb tcpip 5555` 让 adbd 监听一个固定端口 5555。Android 11 的"无线调试"换了一套实现：

- 无线调试由系统按需启动一个 TLS 模式的 adbd 监听器。
- 监听端口在**每次开启无线调试时由系统动态分配**，不是编译期常量，也不是 5555。
- 配对和连接是两个独立的监听器，分别通过 `_adb-tls-pairing._tcp` 和 `_adb-tls-connect._tcp` 广播，所以**配对端口 ≠ 连接端口**。
- 关闭再打开无线调试、重启手机、切换网络，都会重新绑定端口。

这样设计的原因：

1. **减少攻击面**。固定 5555 等于告诉整个局域网"这里有 adb"，随机端口让盲目扫描难以命中。
2. **避免端口冲突**。手机上的其他服务可能占用固定端口，动态分配更稳。
3. **会话隔离**。每次开启都是新的监听器，旧连接和旧端口自然失效。

对启动器的直接后果：**任何把端口写死的方案都会过期**。正确做法只有两个——查 mDNS，或让用户看手机屏幕。`wifi-discover.ps1` 选前者，屏幕上的端口只在配对时用一次。

## 为什么必须配对一次

adb 的信任模型是公钥认证：

- 电脑第一次 `adb start-server` 时会生成一对 RSA 密钥：`%USERPROFILE%\.android\adbkey` 和 `adbkey.pub`。
- 手机端把被信任的公钥存在 `/data/misc/adb/adb_keys`。
- 每次连接，手机用这对密钥验证对方身份；不在名单里的电脑只能拿到 `unauthorized`。

USB 调试的授权方式是弹窗："允许 USB 调试吗？"——你点允许，手机就把电脑公钥写进 `adb_keys`。

Android 11+ 的无线调试没有这个弹窗，改成配对码流程：

1. 手机打开"使用配对码配对设备"，显示 6 位码，并启动 `_adb-tls-pairing._tcp` 监听。
2. 电脑执行 `adb pair <ip>:<pair-port>`，双方用 SPAKE2 从配对码派生出相同的会话密钥。
3. 在这个加密通道里，电脑把自己的公钥发给手机。
4. 手机把公钥写入 `adb_keys`，关闭配对监听。

配对完成后，后续 `adb connect` 才能通过 TLS 握手。没配对时：

- 手机的连接端口可能根本没开（无线调试关闭）；
- 即使开了，TLS 握手也会因为客户端公钥不被信任而失败；
- `adb connect` 可能先报 TCP 成功，随后 transport 被断开，表现为 `offline` 或设备消失。

这不是可以绕过的"限制"，而是 Android 的安全边界：adb 权限等同于 shell 权限，能装应用、读文件、录屏。系统不会允许局域网内任意主机无凭证接入。

## 为什么 `adb connect` 返回 0 仍可能失败

`adb connect` 的退出码语义很窄：**TCP 连接建立成功就是 0**。它不保证：

- 对端真的是 adb（可能是路由器、打印机、别的服务占了同一端口）；
- TLS 握手通过（Android 11+ 未配对时会失败）；
- adb 的 `CNXN` 握手和认证完成；
- transport 已经注册进 `adb devices` 列表。

所以会出现这些情况，全都返回 0：

```text
connected to 192.168.1.100:37123                      # 实际 get-state=offline
already connected to 192.168.1.100:37123              # 旧连接已死
connected to 192.168.1.100:5555                       # 对端不是 adb，get-state=unknown
```

如果启动器只看 `connect` 的退出码，就会把一个坏端点当成成功，然后 scrcpy 报 `no devices`，用户看到的是"启动器说连上了但投屏失败"。

因此 `wifi-discover.ps1` 用两段式判定：

```powershell
adb connect <endpoint>          # 只负责建立 TCP
adb -s <endpoint> get-state     # 必须输出 device
```

`get-state` 读取的是 adb server 里已注册 transport 的状态，能区分 `device` / `offline` / `unauthorized` / `unknown`，这才是"可用"的定义。

`Connect-Endpoint` 还做了一次 250 ms 后的重试，但**只重试 `get-state`，不重复 `connect`**：socket 已经建立，再 connect 只会得到 `already connected`；而 transport 注册有延迟，等 250 ms 再查一次能救回一批"刚连上还没注册好"的设备。

同样的复核也用在第 1 级（复用 existing-tcp）和 `SCRCPY_SERIAL` 校验上：`adb devices` 里有、`get-state` 不是 `device`，一律不算成功。

## 设计取舍

| 决策 | 原因 | 代价 |
| --- | --- | --- |
| WiFi 优先于 USB | 用户的核心诉求是拔线 | 首次需要配对或插一次线 |
| mDNS 先于 USB 辅助 | 不改手机状态，成功率高 | Windows 上 mDNS 可能不可用 |
| USB 辅助先于扫描 | 确定性高，不依赖 mDNS | 会重启手机 adbd，至少多等约 2 秒 |
| 扫描放最后 | 兜底手段，慢且有网络噪音 | 扫描 2.8 秒 + 最多 16 次 connect，受总预算约束 |
| 显式 `SCRCPY_SERIAL` 不回落 | 避免投屏到错误设备 | 设备离线时直接失败 |
| 只扫 /24、私有地址 | 控制时间与影响范围 | 非 /24 网络扫不到 |
| 不猜配对码、不 root | 守住安全边界 | 首次必须人工操作一次 |

## 安全边界

- USB 辅助与局域网扫描只使用 RFC1918 私有地址（`10/8`、`172.16/12`、`192.168/16`），不碰公网地址。
- 只扫描本机物理网卡的 /24，不扫描他人网段。
- 不尝试暴力破解配对码，不修改手机系统属性，不申请 root。
- 启动器本身不写注册表，不常驻后台，不安装服务。
- 对手机的持久化副作用只有 `adb tcpip` 改变 adbd 监听状态，手机重启即恢复。
