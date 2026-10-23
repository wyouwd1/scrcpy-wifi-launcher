#requires -Version 5.1
<#
.SYNOPSIS
  install.ps1 的 Pester 5 测试。

.DESCRIPTION
  运行方式：
    Invoke-Pester -Path .\tests\install.Tests.ps1 -Output Detailed

  说明：本机 Windows PowerShell 5.1 自带的是 Pester 3.4，不支持 Pester 5 的
  Should -Be / BeforeAll 语义。因此仓库同时提供 tests\run-install-tests.ps1
  （纯 PowerShell 断言，零依赖），CI 或本地没有 Pester 5 时运行它即可。

  测试只读取/调用 install.ps1 的函数，不会真的安装 scrcpy。
#>



# 统一控制台输出为 UTF-8：Windows PowerShell 5.1 默认使用 OEM 代码页，
# 中文日志重定向到文件或管道时会乱码。
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch {
    # 某些非交互宿主不允许修改控制台编码，忽略即可。
}



BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:InstallScript = Join-Path $script:RepoRoot 'install.ps1'
    $script:TempDir = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-install-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    # dot-source：入口保护会阻止主流程，只加载参数和函数。
    . $script:InstallScript

    $script:DefaultInstallDir = $InstallDir
    $script:DefaultVersion = $Version
    $script:DefaultForce = $Force.IsPresent
    $script:DefaultNoShortcut = $NoShortcut.IsPresent
    $script:DefaultOffline = $Offline
    $script:DefaultBranch = $Branch
    $script:DefaultLocalSource = $LocalSource
}

AfterAll {
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'install.ps1 参数默认值' {
    It 'InstallDir 默认为 LOCALAPPDATA 下的 scrcpy-wifi-launcher' {
        $expected = Join-Path $env:LOCALAPPDATA 'scrcpy-wifi-launcher'
        $script:DefaultInstallDir | Should -Be $expected
    }

    It 'Version 默认为 5.0.1' {
        $script:DefaultVersion | Should -Be '5.0.1'
    }

    It '开关参数默认关闭，Offline/Branch/LocalSource 默认为空或 main' {
        $script:DefaultForce | Should -BeFalse
        $script:DefaultNoShortcut | Should -BeFalse
        $script:DefaultOffline | Should -Be ''
        $script:DefaultBranch | Should -Be 'main'
        $script:DefaultLocalSource | Should -Be ''
    }
}

Describe '版本解析' {
    It '接受 v5.0.1 并生成正确的文件名' {
        $resolved = Resolve-ScrcpyVersion -Version 'v5.0.1'
        $resolved.Version | Should -Be '5.0.1'
        $resolved.Tag | Should -Be 'v5.0.1'
        $resolved.ZipName | Should -Be 'scrcpy-win64-v5.0.1.zip'
        $resolved.TopDir | Should -Be 'scrcpy-win64-v5.0.1'
        $resolved.Url | Should -Be 'https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-win64-v5.0.1.zip'
    }

    It '拒绝非法版本号' {
        { Resolve-ScrcpyVersion -Version 'abc' } | Should -Throw
    }

    It '对未内置哈希的版本拒绝安装' {
        { Get-ExpectedSha256 -Version '9.9.9' } | Should -Throw -ExpectedMessage '*未内置 SHA256*'
    }
}

Describe 'SHA256 校验' {
    It '对正确哈希返回实际值' {
        $file = Join-Path $script:TempDir 'hash-ok.txt'
        Set-Content -LiteralPath $file -Value 'scrcpy' -Encoding ASCII
        $expected = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $actual = Assert-FileSha256 -Path $file -ExpectedHash $expected
        $actual | Should -Be $expected
    }

    It '对错误哈希抛错' {
        $file = Join-Path $script:TempDir 'hash-bad.txt'
        Set-Content -LiteralPath $file -Value 'scrcpy' -Encoding ASCII
        { Assert-FileSha256 -Path $file -ExpectedHash ('0' * 64) } |
            Should -Throw -ExpectedMessage '*SHA256 校验失败*'
    }

    It '对非法哈希格式抛错' {
        $file = Join-Path $script:TempDir 'hash-format.txt'
        Set-Content -LiteralPath $file -Value 'scrcpy' -Encoding ASCII
        { Assert-FileSha256 -Path $file -ExpectedHash 'not-a-hash' } |
            Should -Throw -ExpectedMessage '*格式无效*'
    }
}

Describe 'Offline 模式' {
    It '离线 zip 不存在时函数抛错' {
        $missing = Join-Path $script:TempDir 'does-not-exist.zip'
        { Resolve-OfflineZip -Path $missing } |
            Should -Throw -ExpectedMessage '*离线安装包不存在*'
    }

    It '离线 zip 不存在时脚本退出码为 1' {
        $missing = Join-Path $script:TempDir 'missing-offline.zip'
        $target = Join-Path $script:TempDir 'install-target'
        # 使用当前 PowerShell 可执行文件，兼容 Windows PowerShell 5.1 与 PowerShell 7。
        $exe = (Get-Process -Id $PID).Path

        $output = & $exe -NoProfile -ExecutionPolicy Bypass -File $script:InstallScript `
            -Offline $missing -InstallDir $target -NoShortcut 2>&1 | Out-String
        $code = $LASTEXITCODE

        $code | Should -Be 1
        $output | Should -Match '离线安装包不存在'
    }
}
