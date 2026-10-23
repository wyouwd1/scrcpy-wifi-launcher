#requires -Version 5.1
<#
.SYNOPSIS
  卸载 scrcpy WiFi 中文启动器。

.DESCRIPTION
  默认行为：
    - 删除桌面快捷方式。
    - 按 install-manifest.json 删除安装器放入的文件。
    - 保留安装目录中不属于安装清单的用户文件（-KeepData 默认为 true）。

  只有显式使用 -KeepData:$false 才会删除整个安装目录（包括用户设置）。
  -Force 仅表示跳过交互确认，不代表删除用户数据。

.PARAMETER InstallDir
  安装目录。默认：$env:LOCALAPPDATA\scrcpy-wifi-launcher。
  如果本脚本位于安装目录内，则默认卸载自身所在目录。

.PARAMETER KeepData
  是否保留用户文件。默认 true。删除全部数据请使用 -KeepData:$false
  （PowerShell 控制台）或 -PurgeData（cmd / powershell -File）。

.PARAMETER PurgeData
  删除整个安装目录，包括用户文件。等价于 -KeepData:$false，
  主要用于 cmd 或 powershell -File 场景（这两种方式无法直接传 bool 值）。

.PARAMETER Force
  跳过交互确认。适合脚本化卸载。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -Force

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -PurgeData -Force
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [bool]$KeepData = $true,
    [switch]$PurgeData,
    [switch]$Force
)


# 统一控制台输出为 UTF-8：Windows PowerShell 5.1 默认使用 OEM 代码页，
# 中文日志重定向到文件或管道时会乱码。
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch {
    # 某些非交互宿主不允许修改控制台编码，忽略即可。
}



$script:ManifestName = 'install-manifest.json'
$script:ShortcutNames = @('启动 scrcpy.lnk', '启动scrcpy.lnk', 'scrcpy WiFi 启动器.lnk')

function Write-UninstallLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )

    switch ($Level) {
        'WARN'  { Write-Host ('[uninstall] 警告：' + $Message) -ForegroundColor Yellow }
        'ERROR' { Write-Host ('[uninstall] 错误：' + $Message) -ForegroundColor Red }
        'STEP'  { Write-Host ('[uninstall] ' + $Message) -ForegroundColor Cyan }
        default { Write-Host ('[uninstall] ' + $Message) }
    }
}

function Get-DefaultInstallDir {
    if ($env:LOCALAPPDATA) {
        return (Join-Path $env:LOCALAPPDATA 'scrcpy-wifi-launcher')
    }
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($local)) {
        throw '无法确定 LOCALAPPDATA 路径，请使用 -InstallDir 指定安装目录。'
    }
    return (Join-Path $local 'scrcpy-wifi-launcher')
}

function Resolve-InstallPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw '安装目录不能为空。'
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    try {
        $full = [IO.Path]::GetFullPath($expanded)
    } catch {
        throw "安装目录无效：$Path"
    }

    $root = [IO.Path]::GetPathRoot($full)
    if ($full -ne $root) {
        $full = $full.TrimEnd('\')
    }
    return $full
}

function Assert-SafeInstallDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $full = Resolve-InstallPath -Path $Path
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\') -ieq $root.TrimEnd('\')) {
        throw "拒绝使用磁盘根目录作为安装目录：$full"
    }

    $protected = @(
        $env:USERPROFILE,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    )
    foreach ($item in $protected) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $protectedFull = [IO.Path]::GetFullPath($item).TrimEnd('\')
        if ($full.TrimEnd('\') -ieq $protectedFull) {
            throw "拒绝使用受保护目录作为安装目录：$full"
        }
    }
    return $full
}

function Test-PathInside {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($Child)
    return $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)
}

function Read-InstallManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir
    )

    $manifestPath = Join-Path $InstallDir $script:ManifestName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $null
    }

    try {
        $json = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)
        return ($json | ConvertFrom-Json)
    } catch {
        throw "安装清单损坏，未删除任何文件：$manifestPath`n$($_.Exception.Message)`n如确认要强制删除，请使用 -PurgeData -Force。"
    }
}

function Remove-DesktopShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [string]$DesktopDir = ''
    )

    if ([string]::IsNullOrWhiteSpace($DesktopDir)) {
        $DesktopDir = [Environment]::GetFolderPath('Desktop')
    }
    if ([string]::IsNullOrWhiteSpace($DesktopDir)) {
        $DesktopDir = Join-Path $env:USERPROFILE 'Desktop'
    }
    if (-not (Test-Path -LiteralPath $DesktopDir -PathType Container)) {
        Write-UninstallLog "桌面目录不存在，跳过快捷方式清理：$DesktopDir" -Level WARN
        return
    }

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($name in $script:ShortcutNames) {
            $shortcutPath = Join-Path $DesktopDir $name
            if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { continue }

            $target = ''
            $shortcut = $null
            try {
                $shortcut = $shell.CreateShortcut($shortcutPath)
                $target = $shortcut.TargetPath
            } catch {
                $target = ''
            } finally {
                if ($shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
            }

            if ([string]::IsNullOrWhiteSpace($target) -or (Test-PathInside -Child $target -Parent $InstallDir)) {
                Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction Stop
                Write-UninstallLog "已删除桌面快捷方式：$shortcutPath"
            } else {
                Write-UninstallLog "跳过指向其他位置的同名快捷方式：$shortcutPath" -Level WARN
            }
        }
    } finally {
        if ($shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    }
}

function Remove-EmptySubdirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $directories = @(
        Get-ChildItem -LiteralPath $Root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending
    )
    foreach ($directory in $directories) {
        $children = @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) {
            Remove-Item -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-IsKnownAppFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FileName
    )

    # 没有安装清单时的保守回退列表：只删除 scrcpy 5.x 官方包和启动器的已知文件。
    $exact = @(
        'scrcpy.exe',
        'scrcpy-server',
        'scrcpy.png',
        'disconnected.png',
        'scrcpy-noconsole.vbs',
        'adb.exe',
        'AdbWinApi.dll',
        'AdbWinUsbApi.dll',
        'avcodec-63.dll',
        'avformat-63.dll',
        'avutil-61.dll',
        'SDL3.dll',
        'swresample-7.dll',
        'libusb-1.0.dll',
        'LICENSE.txt',
        'open_a_terminal_here.bat',
        '启动scrcpy.bat',
        'wifi-discover.ps1',
        'uninstall.ps1'
    )
    if ($exact -contains $FileName) { return $true }

    $patterns = @('av*.dll', 'SDL*.dll', 'swresample*.dll', 'libusb*.dll', 'AdbWin*.dll')
    foreach ($pattern in $patterns) {
        if ($FileName -like $pattern) { return $true }
    }
    return $false
}

function Invoke-Uninstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [bool]$KeepData = $true,
        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'

    $installPath = Assert-SafeInstallDir -Path $InstallDir
    Write-UninstallLog "安装目录：$installPath" -Level STEP

    if (-not (Test-Path -LiteralPath $installPath)) {
        Write-UninstallLog '安装目录不存在，检查并清理残留快捷方式。'
        Remove-DesktopShortcut -InstallDir $installPath
        Write-UninstallLog '无需卸载。'
        return 0
    }
    if (-not (Test-Path -LiteralPath $installPath -PathType Container)) {
        throw "安装路径不是目录：$installPath"
    }

    if (-not $Force) {
        Write-UninstallLog '即将卸载 scrcpy WiFi 启动器。'
        if ($KeepData) {
            Write-UninstallLog '安装目录中的用户文件会保留。'
        } else {
            Write-UninstallLog '警告：-KeepData:$false 会删除安装目录内的全部文件。' -Level WARN
        }
        $answer = ''
        try {
            $answer = Read-Host '[uninstall] 确认卸载请输入 YES'
        } catch {
            Write-UninstallLog '当前环境无法交互确认，已取消。可加 -Force 跳过确认。' -Level WARN
            return 0
        }
        if ($answer -ne 'YES' -and $answer -ne 'yes') {
            Write-UninstallLog '已取消，未做任何更改。'
            return 0
        }
    }

    # 避免当前工作目录占用安装目录，导致最后无法删除目录。
    try {
        $current = (Get-Location).Path
        if ($current -ieq $installPath -or (Test-PathInside -Child $current -Parent $installPath)) {
            Set-Location -LiteralPath ([IO.Path]::GetTempPath())
        }
    } catch {
        # 切换目录失败不影响文件删除，继续。
    }

    # 先读清单：清单损坏时在删除任何东西之前退出。
    $manifest = $null
    if ($KeepData) {
        $manifest = Read-InstallManifest -InstallDir $installPath
    }

    Remove-DesktopShortcut -InstallDir $installPath

    if (-not $KeepData) {
        Write-UninstallLog '删除整个安装目录（-KeepData:$false）...' -Level WARN
        Remove-Item -LiteralPath $installPath -Recurse -Force -ErrorAction Stop
        Write-UninstallLog '卸载完成，安装目录已删除。' -Level STEP
        return 0
    }
    $failed = @()
    $removed = 0
    $usedFallback = $false

    if ($manifest) {
        $version = ''
        if ($manifest.version) { $version = [string]$manifest.version }
        if ($version) {
            Write-UninstallLog "已安装版本：$version"
        }

        $relativeFiles = @($manifest.files)
        foreach ($relative in $relativeFiles) {
            if ([string]::IsNullOrWhiteSpace([string]$relative)) { continue }
            $relativePath = ([string]$relative).TrimStart('\', '/')
            $targetPath = Join-Path $installPath $relativePath

            if (-not (Test-PathInside -Child $targetPath -Parent $installPath)) {
                throw "安装清单包含非法路径，已停止卸载：$relative"
            }

            try {
                if (Test-Path -LiteralPath $targetPath) {
                    Remove-Item -LiteralPath $targetPath -Force -ErrorAction Stop
                    $removed++
                }
            } catch {
                $failed += ('{0}：{1}' -f $relativePath, $_.Exception.Message)
            }
        }
    } else {
        $usedFallback = $true
        Write-UninstallLog '未找到 install-manifest.json，按已知文件列表卸载，未知文件将保留。' -Level WARN
        $rootFiles = @(Get-ChildItem -LiteralPath $installPath -File -Force -ErrorAction SilentlyContinue)
        foreach ($file in $rootFiles) {
            if (Test-IsKnownAppFile -FileName $file.Name) {
                try {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $removed++
                } catch {
                    $failed += ('{0}：{1}' -f $file.Name, $_.Exception.Message)
                }
            }
        }
    }

    # 安装清单本身也是安装器生成的文件，最后删除。
    $manifestPath = Join-Path $installPath $script:ManifestName
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            Remove-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
            $removed++
        } catch {
            $failed += ('{0}：{1}' -f $script:ManifestName, $_.Exception.Message)
        }
    }

    if ($failed.Count -gt 0) {
        $detail = $failed -join "`n"
        throw "部分文件删除失败，可能被占用。请关闭 scrcpy/adb 后重试，或使用 -PurgeData -Force 强制删除。`n$detail"
    }

    Remove-EmptySubdirectories -Root $installPath

    $remaining = @(Get-ChildItem -LiteralPath $installPath -Recurse -File -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Remove-Item -LiteralPath $installPath -Recurse -Force -ErrorAction Stop
        Write-UninstallLog "已删除 $removed 个文件，安装目录已移除。" -Level STEP
        Write-UninstallLog '卸载完成。' -Level STEP
    } else {
        Write-UninstallLog "已删除 $removed 个安装文件。" -Level STEP
        Write-UninstallLog "已保留 $($remaining.Count) 个用户文件：$installPath"
        if ($usedFallback) {
            Write-UninstallLog '未找到安装清单，保留了所有未知文件；如确认无用可手动删除该目录。' -Level WARN
        }
        Write-UninstallLog '卸载完成（用户数据已保留）。' -Level STEP
    }
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $effectiveInstallDir = $InstallDir
        if ([string]::IsNullOrWhiteSpace($effectiveInstallDir)) {
            $looksLikeInstallDir = $false
            if ($PSScriptRoot) {
                if ((Test-Path -LiteralPath (Join-Path $PSScriptRoot 'scrcpy.exe') -PathType Leaf) -or
                    (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install-manifest.json') -PathType Leaf)) {
                    $looksLikeInstallDir = $true
                }
            }
            if ($looksLikeInstallDir) {
                $effectiveInstallDir = $PSScriptRoot
            } else {
                $effectiveInstallDir = Get-DefaultInstallDir
            }
        }

        $effectiveKeepData = $KeepData
        if ($PurgeData) { $effectiveKeepData = $false }
        $exitCode = Invoke-Uninstall -InstallDir $effectiveInstallDir -KeepData:$effectiveKeepData -Force:$Force
        exit $exitCode
    } catch {
        Write-UninstallLog $_.Exception.Message -Level ERROR
        exit 1
    }
}
