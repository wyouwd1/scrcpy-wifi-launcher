#requires -Version 5.1
<#
.SYNOPSIS
  安装 scrcpy WiFi 中文启动器（Windows PowerShell 5.1）。

.DESCRIPTION
  一条命令完成：
    1. 从 GitHub 官方 release 下载 scrcpy 5.0.1（默认只使用官方源；中国大陆可显式指定镜像）。
    2. 用固定 SHA256 校验安装包，防止下载被篡改。
    3. 解压到临时目录，再部署到 -InstallDir。
    4. 从仓库 raw 地址下载启动器脚本（或使用 -LocalSource 指定的本地仓库）。
    5. 在桌面创建快捷方式。

  安装到用户目录（LOCALAPPDATA），不需要管理员权限，不写注册表。
  重复运行不会破坏已有安装；覆盖安装必须显式加 -Force，旧目录会改名为 .bak-时间戳。

.PARAMETER InstallDir
  安装目录。默认：$env:LOCALAPPDATA\scrcpy-wifi-launcher。

.PARAMETER Version
  scrcpy 版本，默认 5.0.1。当前脚本只内置了 5.0.1 的 SHA256。

.PARAMETER Force
  覆盖已有安装。旧目录会先改名为 <InstallDir>.bak-<yyyyMMdd-HHmmss>，不会直接删除。

.PARAMETER NoShortcut
  不创建桌面快捷方式。

.PARAMETER Offline
  使用本地 scrcpy zip，跳过下载。zip 仍会做 SHA256 校验。

.PARAMETER Mirror
  可选镜像前缀。默认不使用镜像，只从 GitHub 官方 release 下载。
  中国大陆网络可显式指定，例如：-Mirror https://ghproxy.net
  也可以通过环境变量 SCRCPY_MIRROR 设置。镜像 URL 由
  "<Mirror>/<官方 release URL>" 拼接，下载内容仍必须通过 SHA256 校验。

.PARAMETER Branch
  下载启动器脚本使用的 git 分支或 tag，默认 main。

.PARAMETER LocalSource
  本地仓库根目录。提供后从该目录的 src\ 和 uninstall.ps1 复制启动器文件，
  不再访问 GitHub raw。适合本地开发和完全离线安装。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
  .\install.ps1 -Offline .\scrcpy-win64-v5.0.1.zip -NoShortcut

.NOTES
  本文件同时被 tests\install.Tests.ps1 dot-source。主流程用
  $MyInvocation.InvocationName -ne '.' 保护，dot-source 时只加载函数和参数。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = $(
        if ($env:LOCALAPPDATA) {
            Join-Path $env:LOCALAPPDATA 'scrcpy-wifi-launcher'
        } else {
            Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'scrcpy-wifi-launcher'
        }
    ),
    [string]$Version = '5.0.1',
    [switch]$Force,
    [switch]$NoShortcut,
    [string]$Offline = '',
    [string]$Mirror = $env:SCRCPY_MIRROR,
    [string]$Branch = 'main',
    [string]$LocalSource = ''
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



# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

$script:InstallerVersion = '1.0.0'
$script:ProductName = 'scrcpy-wifi-launcher'
$script:RepoOwner = 'wyouwd1'
$script:RepoName = 'scrcpy-wifi-launcher'
$script:RawBase = 'https://raw.githubusercontent.com/{0}/{1}' -f $script:RepoOwner, $script:RepoName
$script:ManifestName = 'install-manifest.json'
$script:ShortcutName = '启动 scrcpy.lnk'

# 只内置经过人工核对的版本哈希。新增版本时在这里追加。
$script:KnownSha256 = @{
    '5.0.1' = 'b12a2c4ee8be317422451fc7dcf8ee20a71b5ea7ef9ad73ddd825a25316227a5'
}

# 启动器脚本的固定哈希：只用于校验"从网络下载"的 payload，
# 防止 main 分支被改动后，安装器把未经审阅的脚本放到用户机器上。
# 修改 src/ 或 uninstall.ps1 后必须同步更新这里（CI 会检查一致性）。
$script:PayloadSha256 = @{
    'src/start-scrcpy.bat'  = 'bed05932d9240368eaa9772094cf6e2c5f0b022c42cee05bf65c8b9074a80baf'
    'src/wifi-discover.ps1' = '8d9035493b2bad90627ff3f2d8bc2114e219d79d9ef372dcbf817e329d5edc46'
    'uninstall.ps1'         = '0f6664b3db028259e9d4f6664993b2211411ea7d4d161dff3b73bd2d50cd5945'
}

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------

function Write-InstallLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )

    switch ($Level) {
        'WARN'  { Write-Host ('[install] 警告：' + $Message) -ForegroundColor Yellow }
        'ERROR' { Write-Host ('[install] 错误：' + $Message) -ForegroundColor Red }
        'STEP'  { Write-Host ('[install] ' + $Message) -ForegroundColor Cyan }
        default { Write-Host ('[install] ' + $Message) }
    }
}

# ---------------------------------------------------------------------------
# 版本与哈希
# ---------------------------------------------------------------------------

function Resolve-ScrcpyVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Version
    )

    $raw = $Version.Trim()
    if ($raw -notmatch '^[vV]?(\d+\.\d+(?:\.[0-9]+){0,2})$') {
        throw "版本号格式无效：$Version（示例：5.0.1）"
    }

    $normalized = $Matches[1]
    $tag = 'v' + $normalized
    return [PSCustomObject]@{
        Version   = $normalized
        Tag       = $tag
        ZipName   = "scrcpy-win64-$tag.zip"
        TopDir    = "scrcpy-win64-$tag"
        Url       = "https://github.com/Genymobile/scrcpy/releases/download/$tag/scrcpy-win64-$tag.zip"
    }
}

function Get-ExpectedSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Version
    )

    $key = $Version.Trim().TrimStart('v', 'V')
    if (-not $script:KnownSha256.ContainsKey($key)) {
        throw "版本 $Version 未内置 SHA256，出于安全考虑拒绝自动安装。请联系维护者添加校验值。"
    }
    return $script:KnownSha256[$key]
}

function Get-FileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "文件不存在：$Path"
    }
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop
    return $hash.Hash.ToLowerInvariant()
}

function Assert-FileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    $normalized = ($ExpectedHash -replace '\s', '').ToLowerInvariant()
    if ($normalized -notmatch '^[0-9a-f]{64}$') {
        throw "SHA256 期望值格式无效：$ExpectedHash"
    }

    $actual = Get-FileSha256 -Path $Path
    if ($actual -ne $normalized) {
        throw "SHA256 校验失败：期望 $normalized，实际 $actual"
    }
    return $actual
}

# ---------------------------------------------------------------------------
# 路径与权限
# ---------------------------------------------------------------------------

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

    # 拒绝把用户主目录下的常用目录（桌面/文档/下载等）当作安装目录，
    # 避免 -Force 备份或卸载时把用户数据整体改名/删除。
    if ($env:USERPROFILE) {
        $profileFull = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
        $parent = Split-Path -Parent $full
        if ($parent -and $parent.TrimEnd('\') -ieq $profileFull) {
            $leaf = Split-Path -Leaf $full
            if ($leaf -match '^(Desktop|Documents|Downloads|Pictures|Videos|Music|OneDrive.*|桌面|文档|下载|图片|视频|音乐)$') {
                throw "拒绝使用用户常用目录作为安装目录：$full。请换一个专用目录，例如默认的 `$env:LOCALAPPDATA\scrcpy-wifi-launcher。"
            }
        }
    }
    return $full
}

function Test-DirectoryWritable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    # 从目标目录向上找到第一个已存在的目录，在里面写一个探针文件。
    $probeDir = $Path
    while ($probeDir -and -not (Test-Path -LiteralPath $probeDir -PathType Container)) {
        $parent = Split-Path -Parent $probeDir
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $probeDir) { break }
        $probeDir = $parent
    }

    if (-not $probeDir -or -not (Test-Path -LiteralPath $probeDir -PathType Container)) {
        return $false
    }

    $probe = Join-Path $probeDir ('.scrcpy-write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($probe, 'ok')
        return $true
    } catch {
        return $false
    } finally {
        if (Test-Path -LiteralPath $probe) {
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-OfflineZip {
    [CmdletBinding()]
    param(
        [string]$Path = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if (-not (Test-Path -LiteralPath $expanded -PathType Leaf)) {
        throw "离线安装包不存在：$expanded"
    }

    $item = Get-Item -LiteralPath $expanded -ErrorAction Stop
    if ($item.Length -le 0) {
        throw "离线安装包为空：$($item.FullName)"
    }
    return $item.FullName
}

function Get-InstalledVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir
    )

    $manifestPath = Join-Path $InstallDir $script:ManifestName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }

    try {
        $json = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)
        $manifest = $json | ConvertFrom-Json
        if ($manifest.version) { return [string]$manifest.version }
    } catch {
        return $null
    }
    return $null
}

# ---------------------------------------------------------------------------
# 下载
# ---------------------------------------------------------------------------

function Invoke-DownloadFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$TimeoutSec = 300,
        [int]$MaxAttempts = 3,
        [string]$Activity = '下载文件'
    )

    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $handler = $null
        $client = $null
        $response = $null
        $inputStream = $null
        $outputStream = $null

        try {
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            }

            $handler = New-Object -TypeName System.Net.Http.HttpClientHandler
            $handler.AllowAutoRedirect = $true
            $client = New-Object -TypeName System.Net.Http.HttpClient -ArgumentList $handler
            $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
            $client.DefaultRequestHeaders.UserAgent.ParseAdd('scrcpy-wifi-launcher-installer/1.0')

            $response = $client.GetAsync(
                [Uri]$Uri,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()

            if (-not $response.IsSuccessStatusCode) {
                throw ('HTTP {0} {1}' -f [int]$response.StatusCode, $response.ReasonPhrase)
            }

            $total = $response.Content.Headers.ContentLength
            $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $outputStream = [IO.File]::Open(
                $Destination,
                [IO.FileMode]::Create,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )

            $buffer = New-Object byte[] 81920
            $readTotal = [long]0
            $lastPercent = -1

            while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outputStream.Write($buffer, 0, $count)
                $readTotal += $count

                if ($total -and $total -gt 0) {
                    $percent = [int](($readTotal * 100) / $total)
                    if ($percent -ne $lastPercent) {
                        Write-Progress -Activity $Activity `
                            -Status ('{0:N1} / {1:N1} MB ({2}%)' -f ($readTotal / 1MB), ($total / 1MB), $percent) `
                            -PercentComplete $percent
                        $lastPercent = $percent
                    }
                } else {
                    Write-Progress -Activity $Activity -Status ('已下载 {0:N1} MB' -f ($readTotal / 1MB)) -PercentComplete -1
                }
            }

            Write-Progress -Activity $Activity -Completed
            return
        } catch {
            Write-Progress -Activity $Activity -Completed
            # 取最内层异常，避免只看到 “发送请求时出错” 这类笼统信息。
            $reason = $_.Exception.GetBaseException().Message

            if ($outputStream) { $outputStream.Dispose(); $outputStream = $null }
            if ($inputStream) { $inputStream.Dispose(); $inputStream = $null }
            if ($response) { $response.Dispose(); $response = $null }
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            }

            Write-InstallLog "下载失败（第 $attempt/$MaxAttempts 次）：$reason" -Level WARN
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds (2 * $attempt)
            } else {
                throw "下载失败：$Uri`n$reason"
            }
        } finally {
            if ($outputStream) { $outputStream.Dispose() }
            if ($inputStream) { $inputStream.Dispose() }
            if ($response) { $response.Dispose() }
            if ($client) { $client.Dispose() }
            if ($handler) { $handler.Dispose() }
        }
    }
}

function Get-ScrcpyZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$ResolvedVersion,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Mirror = ''
    )

    # 默认只用官方源。镜像必须由用户显式开启，避免默认供应链风险。
    $sources = @(
        [PSCustomObject]@{ Name = 'GitHub 官方源'; Url = $ResolvedVersion.Url }
    )
    if (-not [string]::IsNullOrWhiteSpace($Mirror)) {
        $mirrorBase = $Mirror.Trim().TrimEnd('/')
        if ($mirrorBase -notmatch '^https?://') {
            throw "镜像地址必须以 http:// 或 https:// 开头：$Mirror"
        }
        $sources += [PSCustomObject]@{
            Name = "镜像源 $mirrorBase"
            Url  = $mirrorBase + '/' + $ResolvedVersion.Url
        }
    }
    $errors = @()

    foreach ($source in $sources) {
        Write-InstallLog "从 $($source.Name) 下载 scrcpy：$($source.Url)"
        try {
            Invoke-DownloadFile -Uri $source.Url -Destination $Destination `
                -TimeoutSec 300 -MaxAttempts 3 -Activity '下载 scrcpy'
            return $source.Name
        } catch {
            $errors += ('{0}：{1}' -f $source.Name, $_.Exception.Message)
            Write-InstallLog "$($source.Name) 失败，准备尝试下一个来源。" -Level WARN
        }
    }

    $detail = $errors -join "`n"
    throw "无法下载 scrcpy $($ResolvedVersion.Version)。`n$detail`n请手动下载 $($ResolvedVersion.Url) ，然后用 -Offline <zip路径> 安装；中国大陆网络也可用 -Mirror https://ghproxy.net 重试。"
}

# ---------------------------------------------------------------------------
# 解压与部署
# ---------------------------------------------------------------------------

function Expand-ScrcpyZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedTopDir
    )

    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        throw "压缩包不存在：$ZipPath"
    }

    New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
    } catch {
        throw "解压失败：$($_.Exception.Message)"
    }

    $top = Join-Path $Destination $ExpectedTopDir
    if (-not (Test-Path -LiteralPath $top -PathType Container)) {
        $dirs = @(Get-ChildItem -LiteralPath $Destination -Directory -ErrorAction Stop)
        if ($dirs.Count -eq 1) {
            $top = $dirs[0].FullName
            Write-InstallLog "压缩包顶层目录与预期不同，使用实际目录：$($dirs[0].Name)" -Level WARN
        } else {
            throw "压缩包结构异常：未找到顶层目录 $ExpectedTopDir"
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $top 'scrcpy.exe') -PathType Leaf)) {
        throw "压缩包结构异常：$top 下未找到 scrcpy.exe"
    }
    return $top
}

function Move-DirectoryContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    try {
        Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
    } catch {
        Write-InstallLog "直接移动失败，改为复制：$($_.Exception.Message)" -Level WARN
        if (Test-Path -LiteralPath $Destination) {
            throw "目标目录已存在，无法复制：$Destination"
        }
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force -ErrorAction Stop
        Remove-Item -LiteralPath $Source -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-PayloadUrls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [string]$Branch = 'main'
    )

    # GitHub raw 优先；失败后回退 jsDelivr（国内一般可直连）。
    # 两者都只是传输通道，真正的信任锚是 PayloadSha256。
    return @(
        ('https://raw.githubusercontent.com/{0}/{1}/{2}/{3}' -f $script:RepoOwner, $script:RepoName, $Branch, $RelativePath),
        ('https://cdn.jsdelivr.net/gh/{0}/{1}@{2}/{3}' -f $script:RepoOwner, $script:RepoName, $Branch, $RelativePath)
    )
}

function Get-LauncherPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TempDir,
        [string]$LocalSource = '',
        [string]$Branch = 'main'
    )

    $items = @(
        [PSCustomObject]@{ RelativePath = 'src/start-scrcpy.bat'; TargetName = '启动scrcpy.bat' },
        [PSCustomObject]@{ RelativePath = 'src/wifi-discover.ps1'; TargetName = 'wifi-discover.ps1' },
        [PSCustomObject]@{ RelativePath = 'uninstall.ps1'; TargetName = 'uninstall.ps1' }
    )

    $payloadDir = Join-Path $TempDir 'payload'
    New-Item -ItemType Directory -Path $payloadDir -Force -ErrorAction Stop | Out-Null
    $result = @()
    $localRoot = ''

    if (-not [string]::IsNullOrWhiteSpace($LocalSource)) {
        $localRoot = (Resolve-Path -LiteralPath $LocalSource -ErrorAction Stop).Path
    }

    foreach ($item in $items) {
        $destination = Join-Path $payloadDir $item.TargetName

        if ($localRoot) {
            $sourcePath = Join-Path $localRoot ($item.RelativePath -replace '/', '\')
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "本地源文件缺失：$sourcePath"
            }
            Copy-Item -LiteralPath $sourcePath -Destination $destination -Force -ErrorAction Stop
        } else {
            # 依次尝试 GitHub raw 与 jsDelivr CDN（国内网络通常可直连 CDN）。
            # 无论走哪个源，最终都必须通过下面的 SHA256 校验。
            $urls = @(Get-PayloadUrls -RelativePath $item.RelativePath -Branch $Branch)
            $downloaded = $false
            $lastError = ''
            foreach ($url in $urls) {
                try {
                    Write-InstallLog "下载启动器文件：$url"
                    Invoke-DownloadFile -Uri $url -Destination $destination -TimeoutSec 60 -MaxAttempts 2 -Activity "下载 $($item.TargetName)"
                    $downloaded = $true
                    break
                } catch {
                    $lastError = $_.Exception.Message
                    Write-InstallLog "该源下载失败，尝试下一个：$lastError" -Level WARN
                }
            }
            if (-not $downloaded) {
                throw "无法下载启动器文件：$($item.RelativePath)`n$lastError`n可改用 -LocalSource <仓库路径> 从本地安装。"
            }

            # 网络下载的 payload 必须匹配内置哈希，避免 main 分支被改动后安装未审阅脚本。
            $expectedPayloadHash = $script:PayloadSha256[$item.RelativePath]
            if ([string]::IsNullOrWhiteSpace($expectedPayloadHash)) {
                throw "缺少 $($item.RelativePath) 的内置 SHA256，出于安全考虑拒绝安装未校验的脚本。"
            }
            $actualPayloadHash = Get-FileSha256 -Path $destination
            if ($actualPayloadHash -ne $expectedPayloadHash) {
                throw "启动器脚本 SHA256 校验失败：$($item.RelativePath)`n期望：$expectedPayloadHash`n实际：$actualPayloadHash`n请确认 -Branch 指向已发布版本，或改用 -LocalSource 从本地仓库安装。"
            }
            Write-InstallLog "启动器脚本校验通过：$($item.TargetName)"
        }

        $file = Get-Item -LiteralPath $destination -ErrorAction Stop
        if ($file.Length -le 0) {
            throw "启动器文件为空：$($item.RelativePath)"
        }
        $result += [PSCustomObject]@{
            TargetName = $item.TargetName
            Path       = $destination
            Size       = $file.Length
        }
    }
    return $result
}

function Copy-LauncherPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][object[]]$Payload
    )

    foreach ($item in $Payload) {
        $destination = Join-Path $InstallDir $item.TargetName
        Copy-Item -LiteralPath $item.Path -Destination $destination -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            throw "复制启动器文件失败：$($item.TargetName)"
        }
    }
}

function Write-InstallManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$ZipSha256,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$Branch = '',
        [string]$BackupPath = ''
    )

    $files = @()
    $rootLength = $InstallDir.Length
    foreach ($file in (Get-ChildItem -LiteralPath $InstallDir -Recurse -File -Force -ErrorAction Stop)) {
        if ($file.DirectoryName -eq $InstallDir -and $file.Name -eq $script:ManifestName) { continue }
        $relative = $file.FullName.Substring($rootLength).TrimStart('\')
        $files += $relative
    }

    $manifest = [ordered]@{
        schemaVersion        = 1
        product              = $script:ProductName
        installerVersion     = $script:InstallerVersion
        version              = $Version
        scrcpyZipSha256      = $ZipSha256
        source               = $Source
        branch               = $Branch
        installedAt          = (Get-Date).ToString('o')
        previousInstallBackup = $BackupPath
        files                = @($files)
    }

    $json = $manifest | ConvertTo-Json -Depth 5
    $manifestPath = Join-Path $InstallDir $script:ManifestName
    [IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $manifestPath
}

function New-DesktopShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [string]$DesktopDir = ''
    )

    if ([string]::IsNullOrWhiteSpace($DesktopDir)) {
        $DesktopDir = [Environment]::GetFolderPath('Desktop')
    }
    if ([string]::IsNullOrWhiteSpace($DesktopDir)) {
        $DesktopDir = Join-Path $env:USERPROFILE 'Desktop'
    }
    if (-not (Test-Path -LiteralPath $DesktopDir -PathType Container)) {
        throw "桌面目录不存在：$DesktopDir"
    }

    $shortcutPath = Join-Path $DesktopDir $script:ShortcutName
    $iconPath = Join-Path $InstallDir 'scrcpy.png'
    if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
        $iconPath = Join-Path $InstallDir 'scrcpy.exe'
    }

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $LauncherPath
        $shortcut.WorkingDirectory = $InstallDir
        $shortcut.Description = 'scrcpy WiFi 启动器'
        if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
            if ([IO.Path]::GetExtension($iconPath) -ieq '.png') {
                $shortcut.IconLocation = $iconPath
            } else {
                $shortcut.IconLocation = "$iconPath,0"
            }
        }
        $shortcut.WindowStyle = 1
        $shortcut.Save()
        return $shortcutPath
    } finally {
        if ($shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        if ($shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

function Invoke-Install {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$Version,
        [switch]$Force,
        [switch]$NoShortcut,
        [string]$Offline = '',
        [string]$Mirror = '',
        [string]$Branch = 'main',
        [string]$LocalSource = ''
    )

    $ErrorActionPreference = 'Stop'
    $tempRoot = $null
    $backupPath = ''
    $createdBackup = $false
    $targetCreated = $false
    $shortcutPath = $null

    try {
        Write-InstallLog "scrcpy WiFi 中文启动器安装器 v$script:InstallerVersion" -Level STEP

        # 1. 环境检查
        Write-InstallLog '[1/7] 检查系统环境...' -Level STEP
        if ($env:OS -ne 'Windows_NT') {
            throw '此安装器仅支持 Windows。'
        }
        if (-not [Environment]::Is64BitOperatingSystem) {
            throw 'scrcpy 官方包仅提供 64 位版本，当前系统不是 64 位 Windows。'
        }
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        } catch {
            throw "无法启用 TLS 1.2：$($_.Exception.Message)"
        }
        Write-InstallLog '系统架构：64 位 Windows'
        if (-not [Environment]::Is64BitProcess) {
            Write-InstallLog '当前 PowerShell 是 32 位进程；安装过程本身不依赖进程位数。' -Level WARN
        }

        # 2. 版本与哈希
        Write-InstallLog '[2/7] 解析版本与校验信息...' -Level STEP
        $resolved = Resolve-ScrcpyVersion -Version $Version
        $expectedHash = Get-ExpectedSha256 -Version $resolved.Version
        Write-InstallLog "目标版本：$($resolved.Version)（$($resolved.Tag)）"

        # 3. 安装目录
        Write-InstallLog '[3/7] 检查安装目录...' -Level STEP
        $installPath = Assert-SafeInstallDir -Path $InstallDir
        if (Test-Path -LiteralPath $installPath) {
            if (-not (Test-Path -LiteralPath $installPath -PathType Container)) {
                throw "安装路径已存在且不是目录：$installPath"
            }
            if (-not $Force) {
                $existingVersion = Get-InstalledVersion -InstallDir $installPath
                if ($existingVersion) {
                    Write-InstallLog "已检测到已安装版本：$existingVersion"
                }
                Write-InstallLog "安装目录已存在：$installPath"
                Write-InstallLog '未做任何更改。如需覆盖安装，请加 -Force（旧目录会先备份为 .bak-时间戳）。'
                return 0
            }
        }
        if (-not (Test-DirectoryWritable -Path $installPath)) {
            throw "安装目录不可写：$installPath`n请改用 -InstallDir 指向可写目录（例如 `$env:LOCALAPPDATA 下）。不需要管理员权限。"
        }
        Write-InstallLog "安装目录：$installPath"

        # 已确认要安装后再校验离线包，保证重复运行可以幂等退出。
        $offlineZip = Resolve-OfflineZip -Path $Offline
        if ($offlineZip) {
            Write-InstallLog "离线安装包：$offlineZip"
        }

        # 4. 启动器文件
        Write-InstallLog '[4/7] 准备启动器文件...' -Level STEP
        if ($Branch -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or
            $Branch -match '\.\.' -or
            $Branch.Contains('//') -or
            $Branch.EndsWith('/')) {
            throw "分支名无效：$Branch"
        }

        $localSourcePath = ''
        if (-not [string]::IsNullOrWhiteSpace($LocalSource)) {
            $localSourcePath = (Resolve-Path -LiteralPath $LocalSource -ErrorAction Stop).Path
            Write-InstallLog "使用本地启动器文件：$localSourcePath"
        } elseif ($PSScriptRoot) {
            # 从完整仓库运行时自动使用本地文件，避免拉取到不一致的 main 分支。
            $candidateBat = Join-Path $PSScriptRoot 'src\start-scrcpy.bat'
            $candidateUninstall = Join-Path $PSScriptRoot 'uninstall.ps1'
            if ((Test-Path -LiteralPath $candidateBat -PathType Leaf) -and
                (Test-Path -LiteralPath $candidateUninstall -PathType Leaf)) {
                $localSourcePath = $PSScriptRoot
                Write-InstallLog "检测到完整仓库，使用本地启动器文件：$localSourcePath"
            }
        }

        # 临时目录：GetTempPath + GUID，失败时在 finally 中清理。
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('scrcpy-install-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force -ErrorAction Stop | Out-Null
        Write-InstallLog "临时目录：$tempRoot"

        # 离线安装若没有本地 payload，会在下载启动器脚本时才报错，
        # 那时用户已经等了一次 11MB 下载。这里提前失败，给出可执行的修法。
        if ($offlineZip -and -not $localSourcePath) {
            throw "离线安装需要 -LocalSource <仓库路径>，或使用含 src\ 与 uninstall.ps1 的完整发布包。`n当前只找到 install.ps1，无法取得启动器脚本。"
        }

        $payload = Get-LauncherPayload -TempDir $tempRoot -LocalSource $localSourcePath -Branch $Branch

        # 5. 下载 scrcpy
        Write-InstallLog '[5/7] 获取 scrcpy 安装包...' -Level STEP
        if ($offlineZip) {
            $zipPath = $offlineZip
            $sourceLabel = '离线包'
        } else {
            $zipPath = Join-Path $tempRoot $resolved.ZipName
            $sourceLabel = Get-ScrcpyZip -ResolvedVersion $resolved -Destination $zipPath -Mirror $Mirror
        }

        Write-InstallLog '校验安装包 SHA256...'
        try {
            $actualHash = Assert-FileSha256 -Path $zipPath -ExpectedHash $expectedHash
        } catch {
            if (-not $offlineZip -and (Test-Path -LiteralPath $zipPath)) {
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
                Write-InstallLog '已删除校验失败的临时文件。' -Level WARN
            }
            throw
        }
        Write-InstallLog "SHA256 校验通过：$actualHash"

        # 6. 解压并部署
        Write-InstallLog '[6/7] 解压并部署...' -Level STEP
        $extractDir = Join-Path $tempRoot 'extract'
        $extractedRoot = Expand-ScrcpyZip -ZipPath $zipPath -Destination $extractDir -ExpectedTopDir $resolved.TopDir
        Write-InstallLog "解压完成：$extractedRoot"

        if (Test-Path -LiteralPath $installPath) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupPath = "$installPath.bak-$stamp"
            $index = 1
            while (Test-Path -LiteralPath $backupPath) {
                $backupPath = "$installPath.bak-$stamp-$index"
                $index++
            }
            Write-InstallLog "备份旧安装：$installPath -> $backupPath"
            Move-Item -LiteralPath $installPath -Destination $backupPath -ErrorAction Stop
            $createdBackup = $true
        }

        try {
            # 先标记，确保移动一半失败时也能清理目标目录。
            $targetCreated = $true
            Move-DirectoryContent -Source $extractedRoot -Destination $installPath
            Copy-LauncherPayload -InstallDir $installPath -Payload $payload
            $manifestPath = Write-InstallManifest -InstallDir $installPath `
                -Version $resolved.Version -ZipSha256 $actualHash -Source $sourceLabel `
                -Branch $Branch -BackupPath $backupPath
            Write-InstallLog "已写入安装清单：$manifestPath"

            if (-not $NoShortcut) {
                try {
                    $shortcutPath = New-DesktopShortcut `
                        -InstallDir $installPath `
                        -LauncherPath (Join-Path $installPath '启动scrcpy.bat') `
                        -DesktopDir ([Environment]::GetFolderPath('Desktop'))
                    Write-InstallLog "已创建桌面快捷方式：$shortcutPath"
                } catch {
                    Write-InstallLog "桌面快捷方式创建失败（不影响启动器使用）：$($_.Exception.Message)" -Level WARN
                    $shortcutPath = $null
                }
            } else {
                Write-InstallLog '已按 -NoShortcut 跳过桌面快捷方式。'
            }
        } catch {
            Write-InstallLog '部署失败，开始回滚...' -Level WARN
            if ($targetCreated -and (Test-Path -LiteralPath $installPath)) {
                Remove-Item -LiteralPath $installPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($createdBackup -and $backupPath -and (Test-Path -LiteralPath $backupPath)) {
                if (Test-Path -LiteralPath $installPath) {
                    Remove-Item -LiteralPath $installPath -Recurse -Force -ErrorAction SilentlyContinue
                }
                Move-Item -LiteralPath $backupPath -Destination $installPath -ErrorAction Stop
                Write-InstallLog "已恢复旧安装：$installPath" -Level WARN
            }
            throw
        }

        # 7. 结果
        Write-InstallLog '[7/7] 安装完成。' -Level STEP
        Write-InstallLog "安装目录：$installPath"
        Write-InstallLog "scrcpy 版本：$($resolved.Version)"
        Write-InstallLog "启动命令：`"$installPath\启动scrcpy.bat`""
        if ($shortcutPath) {
            Write-InstallLog "桌面快捷方式：$shortcutPath"
        } else {
            Write-InstallLog '桌面快捷方式：未创建'
        }
        if ($backupPath) {
            Write-InstallLog "旧版本备份：$backupPath（确认新版本可用后可手动删除）"
        }

        $uninstallPath = Join-Path $installPath 'uninstall.ps1'
        Write-InstallLog "卸载：powershell -NoProfile -ExecutionPolicy Bypass -File `"$uninstallPath`""
        Write-InstallLog '后续步骤：'
        Write-InstallLog '  1. 手机开启开发者选项与 USB 调试，先用 USB 连接一次并授权。'
        if ($shortcutPath) {
            Write-InstallLog '  2. 双击“启动 scrcpy”桌面快捷方式，启动器会自动尝试 WiFi 连接。'
        } else {
            Write-InstallLog "  2. 运行 `"$installPath\启动scrcpy.bat`"，启动器会自动尝试 WiFi 连接。"
        }
        return 0
    } finally {
        if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 入口保护：dot-source 时只加载函数，方便 tests\install.Tests.ps1 测试。
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $exitCode = Invoke-Install `
            -InstallDir $InstallDir `
            -Version $Version `
            -Force:$Force `
            -NoShortcut:$NoShortcut `
            -Offline $Offline `
            -Mirror $Mirror `
            -Branch $Branch `
            -LocalSource $LocalSource
        exit $exitCode
    } catch {
        Write-InstallLog $_.Exception.Message -Level ERROR
        exit 1
    }
}
