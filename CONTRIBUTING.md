# 贡献指南

欢迎提 issue 和 PR。这个项目只有两个脚本和一批文档，门槛不高，但有几条硬约束不能破。

## 提 Issue

先搜一下现有 issue，再按下面顺序自查：

1. 单独运行 `wifi-discover.ps1`，确认失败发生在发现阶段还是 scrcpy 阶段。
2. 贴出 `.\adb.exe devices`、`.\adb.exe mdns services` 的完整输出。
3. 说明手机型号、Android 版本、Windows 版本、scrcpy 版本。

**必须脱敏**：真实 IP 用示例地址 `192.168.1.100` 代替，设备序列号打码成 `ABCDEF0123456789`，不要贴用户名目录、公司内网地址、配对码。

一个 issue 只报一个问题。附上复现步骤和期望结果，比"连不上"有用得多。

## 提 PR

1. Fork 后从 `main` 切分支，分支名用 `fix/...` 或 `feat/...`。
2. 一个 PR 只做一件事，不要把格式化改动和功能改动混在一起。
3. 描述里写清：改了什么、为什么改、怎么验证的。
4. 不要提交 exe、dll、zip、日志、截图里的真实 IP。

提交信息用中文描述，保留英文 type 前缀：

```text
feat: 支持从 mDNS 读取 IPv6 端点
fix: 修复 tcpip 端口被占用时的回退
docs: 补充路由器 AP 隔离的排查步骤
```

## 代码风格

### BAT（`src/start-scrcpy.bat`）

- **GBK 编码**：文件必须保存为无 BOM 的 GBK（代码页 936），中文才能被 cmd.exe 正确解析。禁止 UTF-8（含 BOM）——cmd 按字节读取批处理，UTF-8 中文会导致语句错位。GBK 无法表示的字符（emoji、部分生僻字）不要使用。
- **CRLF 换行**：仓库用 `.gitattributes` 强制 `*.bat text eol=crlf`，本地编辑后不要转成 LF。
- 固定开头：`@echo off` + `setlocal EnableExtensions EnableDelayedExpansion`。
- 变量名全大写，用 `set "NAME=value"` 形式；引用时加引号。
- 注释用 `rem`，不用 `::`（在括号块里会出问题）。
- 输出统一前缀：`[信息]` / `[警告]` / `[错误]`。
- BAT 不做破坏性操作；安装/卸载脚本需要删除或覆盖时，先备份并提供 `-Force` 之类的显式开关。

### PowerShell（`src/wifi-discover.ps1`）

- **必须兼容 Windows PowerShell 5.1**（Windows 10/11 自带）。不要用 PowerShell 7 才有的语法：
  - `??`、`?.`、`??=`
  - `ForEach-Object -Parallel`、`-AsByteStream`
  - `Get-Content -Raw` 可以，`ConvertFrom-Json -AsHashtable` 不行
- 文件头保留 `#requires -Version 5.1`。
- 函数用 `Verb-Noun` 命名；变量用英文，注释可用中文。
- 对外输出用中文（会被 BAT 捕获）；协议行 `WIFI_ENDPOINT=` / `WIFI_SOURCE=` 必须保持 ASCII 且格式不变。错误写 stderr，成功写 stdout。
- 任何外部命令都要有超时，不要裸调 `adb` 后无限等待。
- 新增网络操作前先检查剩余时间预算，遵守现有的 13 秒总预算。

### 文档

- 中文为主，技术术语、命令、报错原文保持英文。
- 代码块标注语言；命令必须可复制执行。
- 不写未实测的性能数字，不贴真实 IP / 序列号 / 用户名路径。

## 修改发现逻辑

`wifi-discover.ps1` 的优先级是设计的一部分。新增策略时：

1. 想清楚它插在第几级，为什么比相邻级别更优。
2. 定义新的 `WIFI_SOURCE` 值，并同步更新 README 的 source 表。
3. 保证失败时能干净地落到下一级，不消耗过多预算。
4. 补一条夹具测试，覆盖成功和失败两个分支。

## 测试

提交前在 Windows 上跑一遍 `tests\` 下的夹具测试（入口与说明见该目录的 README）。至少覆盖：

- 正常发现与四种 `source`
- mDNS 随机端口
- USB 辅助 `adb tcpip`
- 无设备时的回退与退出码

没有 Windows 环境时，在 PR 里注明"未实测"，不要假装跑过。

## 许可证

提交 PR 即表示同意以 [Apache License 2.0](LICENSE) 授权你的贡献。
