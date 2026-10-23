## 变更说明

<!-- 简要说明这个 PR 做了什么、为什么需要 -->

## 检查清单

- [ ] `src/` 下的 BAT 仍为 ASCII-only（无中文、全角符号或其它非 ASCII 字节）
- [ ] PowerShell 脚本兼容 Windows PowerShell 5.1（未使用 `??`、`?.`、`Join-String` 等 PS 7 专属语法）
- [ ] 未提交敏感信息（真实内网 IP、设备序列号、`C:\Users\<本机用户名>` 路径）
- [ ] 未提交 `scrcpy.exe`、`adb.exe` 等二进制文件
- [ ] 已更新相关文档（README / docs）

## 测试

<!-- 说明你怎么验证的：命令、Windows 版本、PowerShell 版本、实际输出 -->
