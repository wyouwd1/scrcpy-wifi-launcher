# 安全策略

## 报告漏洞

请**不要**开公开 issue。用 GitHub 的 [Private vulnerability reporting](../../security/advisories/new) 提交，或在 issue 中只写"需要私下沟通"并留下联系方式。

我们会在 7 天内响应。

## 范围

本仓库只包含**启动脚本**，不含 scrcpy 二进制。以下不属于本仓库范围：

- scrcpy 本体漏洞 → 报给 https://github.com/Genymobile/scrcpy
- adb / platform-tools 漏洞 → 报给 Google
- 手机端系统问题 → 报给设备厂商

## 设计上的安全取舍

| 取舍 | 原因 | 缓解 |
|------|------|------|
| 安装脚本从网络下载 zip | 避免仓库体积膨胀、始终拿到官方原版 | 固定 SHA256 校验，不匹配立即中止并删除临时文件 |
| 启动器用 `-ExecutionPolicy Bypass` 调 PowerShell | 家用 Windows 默认策略会拦截 .ps1 | 只对**单个进程**生效，不改系统策略；脚本本身开源可审计 |
| USB 辅助执行 `adb tcpip 5555` | 让只插过 USB 的用户也能用 WiFi | 仅在用户已授权 USB 调试时执行；`--no-wifi` 可禁用 |
| 局域网 5555 端口探测 | 覆盖 mDNS 失效的老设备 | 仅扫描本机私有 `/24`，仅 5555 端口，有超时预算 |

## 不收集任何数据

本仓库脚本不联网上报、不写注册表、不采集设备信息。`adb` 的本地服务仅监听 `127.0.0.1:5037`（adb 默认行为）。
