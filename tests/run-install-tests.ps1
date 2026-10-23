#requires -Version 5.1
<#
.SYNOPSIS
  install.ps1 的零依赖测试运行器（纯 PowerShell 断言）。

.DESCRIPTION
  本机 Windows PowerShell 5.1 自带 Pester 3.4，不支持 Pester 5 的
  Should -Be / BeforeAll 语义。本脚本不依赖任何 Pester 版本，直接运行：

    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-install-tests.ps1

  退出码 0 表示全部通过，1 表示有失败。
  与 tests\install.Tests.ps1 覆盖同一组核心行为：
    - 参数默认值
    - 版本解析
    - SHA256 校验对错误哈希抛错
    - Offline 模式在文件缺失时报错（函数级 + 进程级退出码）
#>
[CmdletBinding()]
param()


# 统一控制台输出为 UTF-8：Windows PowerShell 5.1 默认使用 OEM 代码页，
# 中文日志重定向到文件或管道时会乱码。
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch {
    # 某些非交互宿主不允许修改控制台编码，忽略即可。
}



$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Expected -ne $Actual) {
        throw "期望：$Expected`n实际：$Actual"
    }
    Write-Host "  [PASS] $Name" -ForegroundColor Green
    $script:Passed++
}

function Assert-False {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Actual) {
        throw "期望 false，实际：$Actual"
    }
    Write-Host "  [PASS] $Name" -ForegroundColor Green
    $script:Passed++
}

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Actual -notmatch $Pattern) {
        throw "文本不匹配：$Pattern`n实际输出：$Actual"
    }
    Write-Host "  [PASS] $Name" -ForegroundColor Green
    $script:Passed++
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $threw = $false
    $message = ''
    try {
        & $Action | Out-Null
    } catch {
        $threw = $true
        $message = $_.Exception.Message
    }
    if (-not $threw) {
        throw '预期抛错，实际没有抛错。'
    }
    if ($message -notmatch $Pattern) {
        throw "错误消息不匹配：$Pattern`n实际消息：$message"
    }
    Write-Host "  [PASS] $Name" -ForegroundColor Green
    $script:Passed++
}

function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    Write-Host "[tests] $Name" -ForegroundColor Cyan
    try {
        & $Body
    } catch {
        $script:Failed++
        $script:Failures += ('{0}：{1}' -f $Name, $_.Exception.Message)
        Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    }
}

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:InstallScript = Join-Path $script:RepoRoot 'install.ps1'
$script:TempDir = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-install-tests-' + [guid]::NewGuid().ToString('N'))

try {
    if (-not (Test-Path -LiteralPath $script:InstallScript -PathType Leaf)) {
        throw "找不到 install.ps1：$($script:InstallScript)"
    }
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    # dot-source：入口保护会阻止主流程。
    . $script:InstallScript

    Invoke-Case '参数默认值' {
        Assert-Equal (Join-Path $env:LOCALAPPDATA 'scrcpy-wifi-launcher') $InstallDir 'InstallDir 默认值'
        Assert-Equal '5.0.1' $Version 'Version 默认值'
        Assert-False $Force.IsPresent 'Force 默认关闭'
        Assert-False $NoShortcut.IsPresent 'NoShortcut 默认关闭'
        Assert-Equal '' $Offline 'Offline 默认为空'
        Assert-Equal 'main' $Branch 'Branch 默认 main'
        Assert-Equal '' $LocalSource 'LocalSource 默认为空'
    }

    Invoke-Case '版本解析' {
        $resolved = Resolve-ScrcpyVersion -Version 'v5.0.1'
        Assert-Equal '5.0.1' $resolved.Version '解析版本号'
        Assert-Equal 'v5.0.1' $resolved.Tag '生成 tag'
        Assert-Equal 'scrcpy-win64-v5.0.1.zip' $resolved.ZipName '生成 zip 文件名'
        Assert-Equal 'scrcpy-win64-v5.0.1' $resolved.TopDir '生成顶层目录名'
        Assert-Throws { Resolve-ScrcpyVersion -Version 'abc' } '版本号格式无效' '拒绝非法版本'
        Assert-Throws { Get-ExpectedSha256 -Version '9.9.9' } '未内置 SHA256' '未知版本拒绝安装'
    }

    Invoke-Case 'SHA256 校验' {
        $file = Join-Path $script:TempDir 'hash-ok.txt'
        Set-Content -LiteralPath $file -Value 'scrcpy' -Encoding ASCII
        $expected = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $actual = Assert-FileSha256 -Path $file -ExpectedHash $expected
        Assert-Equal $expected $actual '正确哈希通过'

        Assert-Throws {
            Assert-FileSha256 -Path $file -ExpectedHash ('0' * 64)
        } 'SHA256 校验失败' '错误哈希抛错'

        Assert-Throws {
            Assert-FileSha256 -Path $file -ExpectedHash 'not-a-hash'
        } '格式无效' '非法哈希格式抛错'
    }

    Invoke-Case 'Offline 模式文件缺失' {
        $missing = Join-Path $script:TempDir 'missing.zip'
        Assert-Throws { Resolve-OfflineZip -Path $missing } '离线安装包不存在' '函数抛错'

        $target = Join-Path $script:TempDir 'install-target'
        # 使用当前 PowerShell 可执行文件，兼容 Windows PowerShell 5.1 与 PowerShell 7。
        $exe = (Get-Process -Id $PID).Path
        $stdout = Join-Path $script:TempDir 'child-stdout.txt'
        $stderr = Join-Path $script:TempDir 'child-stderr.txt'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Offline "{1}" -InstallDir "{2}" -NoShortcut' -f `
            $script:InstallScript, $missing, $target

        $process = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden
        $output = ''
        if (Test-Path -LiteralPath $stdout) { $output += (Get-Content -LiteralPath $stdout -Raw -Encoding UTF8) }
        if (Test-Path -LiteralPath $stderr) { $output += (Get-Content -LiteralPath $stderr -Raw -Encoding UTF8) }

        Assert-Equal 1 $process.ExitCode '脚本退出码为 1'
        Assert-Match '离线安装包不存在' $output '脚本输出可读错误'
    }

    Write-Host ''
    if ($script:Failed -eq 0) {
        Write-Host "[tests] 全部通过：$script:Passed PASS / 0 FAIL" -ForegroundColor Green
        exit 0
    }

    Write-Host "[tests] 测试失败：$script:Passed PASS / $script:Failed FAIL" -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
} finally {
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
