#requires -Version 5.1
<#
.SYNOPSIS
  通过 adb 发现可用的 scrcpy WiFi 端点。

.DESCRIPTION
  发现顺序：
    1. 复用 "adb devices" 中已在线的 TCP/IP 设备。
    2. 连接 "adb mdns services" 广播的端点
       （优先 _adb-tls-connect._tcp，其次 _adb._tcp）。
    3. 若有 USB 设备，读取其 WiFi IP 并启用 adb tcpip。
    4. 扫描本机 /24 网段，寻找开放的 adb 端口。

  成功时脚本向 stdout 只写两行：
    WIFI_ENDPOINT=host:port
    WIFI_SOURCE=<source>
  然后退出码 0。失败时向 stderr 写一条简短消息并退出码 1。

.PARAMETER AdbPath
  adb.exe 路径。默认使用 PATH 中的 adb.exe。

.PARAMETER Port
  USB 辅助与局域网扫描使用的 WiFi adb 端口。省略时依次使用
  SCRCPY_WIFI_PORT 环境变量，最后回退 5555。

.PARAMETER TimeoutSec
  单条 adb 命令的超时秒数。默认 8。
#>
[CmdletBinding()]
param(
    [string]$AdbPath = 'adb.exe',
    [int]$Port = 0,
    [int]$TimeoutSec = 8
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:AdbExePath = $null
$script:AdbTimeoutMs = 8000
$script:ScanBudgetMs = 2800
$script:TotalBudgetMs = 13000
$script:Deadline = [System.Diagnostics.Stopwatch]::StartNew()
$script:VirtualAdapterPattern = '(?i)(WSL|Hyper-V|vEthernet|VMware|VirtualBox|Loopback|Teredo|isatap|Docker|podman|Wintun|Tailscale|ZeroTier|VPN|TAP-|Npcap|Bluetooth|Wi-Fi Direct)'

function Get-RemainingMs {
    $remaining = $script:TotalBudgetMs - [int]$script:Deadline.ElapsedMilliseconds
    if ($remaining -lt 0) {
        return 0
    }
    return $remaining
}

function Write-Stderr {
    param([string]$Message)
    try {
        [Console]::Error.WriteLine('[wifi] ' + $Message)
    } catch {
    }
}

function Resolve-AdbPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    $candidate = $Path
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $localCandidate = Join-Path (Get-Location).Path $candidate
        if (Test-Path -LiteralPath $localCandidate -PathType Leaf) {
            $candidate = $localCandidate
        } else {
            $command = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($null -ne $command) {
                $candidate = $command.Source
            }
        }
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return $null
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Invoke-Adb {
    param(
        [string[]]$Arguments,
        [int]$TimeoutMs = 0
    )
    if ($TimeoutMs -le 0) {
        $TimeoutMs = $script:AdbTimeoutMs
    }
    $remaining = Get-RemainingMs
    if ($remaining -le 0) {
        return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = '总超时时间已用尽'; TimedOut = $true }
    }
    if ($TimeoutMs -gt $remaining) {
        $TimeoutMs = $remaining
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:AdbExePath
    $info.Arguments = ($Arguments -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    try {
        $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    } catch {
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        $started = $process.Start()
        if (-not $started) {
            return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'adb 启动失败'; TimedOut = $false }
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit($TimeoutMs)
        if (-not $exited) {
            try {
                $process.Kill()
            } catch {
            }
            try {
                [void]$process.WaitForExit(1000)
            } catch {
            }
            return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'adb 命令超时'; TimedOut = $true }
        }
        $stdout = ''
        $stderr = ''
        try {
            $stdout = $stdoutTask.Result
        } catch {
        }
        try {
            $stderr = $stderrTask.Result
        } catch {
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr; TimedOut = $false }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = $_.Exception.Message; TimedOut = $false }
    } finally {
        try {
            $process.Dispose()
        } catch {
        }
    }
}

function Get-AdbDevices {
    $result = Invoke-Adb -Arguments @('devices')
    $devices = New-Object System.Collections.ArrayList
    if ($null -eq $result -or $result.ExitCode -ne 0) {
        return @()
    }
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        $text = $line.Trim()
        if ($text -eq '' -or $text -like 'List of devices*' -or $text -like '*daemon*') {
            continue
        }
        $match = [regex]::Match($text, '^(\S+)\s+(device|offline|unauthorized|recovery|sideload|bootloader)\b')
        if ($match.Success) {
            [void]$devices.Add([pscustomobject]@{
                Serial = $match.Groups[1].Value
                State  = $match.Groups[2].Value
            })
        }
    }
    return @($devices)
}

function Test-Endpoint {
    param(
        [string]$Endpoint,
        [int]$TimeoutMs = 0
    )
    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        return $false
    }
    $result = Invoke-Adb -Arguments @('-s', $Endpoint, 'get-state') -TimeoutMs $TimeoutMs
    if ($null -eq $result -or $result.ExitCode -ne 0) {
        return $false
    }
    return ($result.StdOut.Trim() -eq 'device')
}

function Connect-Endpoint {
    param(
        [string]$Endpoint,
        [int]$TimeoutMs = 0,
        [switch]$NoRetry
    )
    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        return $false
    }
    $null = Invoke-Adb -Arguments @('connect', $Endpoint) -TimeoutMs $TimeoutMs
    if (Test-Endpoint -Endpoint $Endpoint -TimeoutMs $TimeoutMs) {
        return $true
    }
    if ($NoRetry -or (Get-RemainingMs) -lt 400) {
        return $false
    }
    Start-Sleep -Milliseconds 250
    return (Test-Endpoint -Endpoint $Endpoint -TimeoutMs $TimeoutMs)
}

function ConvertTo-Endpoint {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $null
    }
    $value = $Raw.Trim().TrimEnd('.')
    $index = $value.LastIndexOf(':')
    if ($index -le 0 -or $index -ge ($value.Length - 1)) {
        return $null
    }
    $hostPart = $value.Substring(0, $index)
    $portPart = $value.Substring($index + 1)
    if ($portPart -notmatch '^\d{1,5}$') {
        return $null
    }
    $portNumber = [int]$portPart
    if ($portNumber -lt 1 -or $portNumber -gt 65535) {
        return $null
    }
    if ($hostPart.StartsWith('[') -and $hostPart.EndsWith(']')) {
        $hostPart = $hostPart.Substring(1, $hostPart.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($hostPart)) {
        return $null
    }
    if ($hostPart.Contains(':')) {
        return ('[' + $hostPart + ']:' + $portNumber)
    }
    return ($hostPart + ':' + $portNumber)
}

function Get-MdnsCandidates {
    $result = Invoke-Adb -Arguments @('mdns', 'services')
    $candidates = New-Object System.Collections.ArrayList
    if ($null -eq $result -or $result.ExitCode -ne 0) {
        return @()
    }
    $order = 0
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        $text = $line.Trim()
        if ($text -eq '' -or $text -like 'List of discovered*') {
            continue
        }
        $parts = @($text -split '\s+')
        if ($parts.Count -lt 3) {
            continue
        }
        $service = $parts[1]
        $priority = -1
        if ($service -ieq '_adb-tls-connect._tcp') {
            $priority = 0
        } elseif ($service -ieq '_adb._tcp') {
            $priority = 1
        }
        if ($priority -lt 0) {
            continue
        }
        $endpoint = ConvertTo-Endpoint -Raw $parts[$parts.Count - 1]
        if ($null -eq $endpoint) {
            continue
        }
        [void]$candidates.Add([pscustomobject]@{
            Endpoint = $endpoint
            Service  = $service
            Priority = $priority
            Order    = $order
        })
        $order++
    }
    return @($candidates | Sort-Object Priority, Order)
}

function Test-PrivateIPv4 {
    param([string]$Ip)
    $address = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$address)) {
        return $false
    }
    $bytes = $address.GetAddressBytes()
    if ($bytes.Length -ne 4) {
        return $false
    }
    if ($bytes[0] -eq 10) {
        return $true
    }
    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) {
        return $true
    }
    if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) {
        return $true
    }
    return $false
}

function Add-Subnet {
    param(
        [System.Collections.ArrayList]$Subnets,
        [hashtable]$Seen,
        [string]$Ip,
        [string]$Alias
    )
    if (-not (Test-PrivateIPv4 -Ip $Ip)) {
        return
    }
    $octets = $Ip.Split('.')
    if ($octets.Count -ne 4) {
        return
    }
    $prefix = $octets[0] + '.' + $octets[1] + '.' + $octets[2]
    if ($Seen.ContainsKey($prefix)) {
        return
    }
    $Seen[$prefix] = $true
    [void]$Subnets.Add([pscustomobject]@{
        Prefix  = $prefix
        LocalIp = $Ip
        Alias   = $Alias
    })
}

function Get-LocalSubnets {
    $subnets = New-Object System.Collections.ArrayList
    $seen = @{}

    # 优先用 .NET API：速度快，且不用加载 NetTCPIP 模块。
    try {
        $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
        foreach ($nic in $nics) {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
                continue
            }
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) {
                continue
            }
            if ($nic.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211 -and $nic.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Ethernet) {
                continue
            }
            $nicText = [string]$nic.Name + ' ' + [string]$nic.Description
            if ($nicText -match $script:VirtualAdapterPattern) {
                continue
            }
            foreach ($unicast in $nic.GetIPProperties().UnicastAddresses) {
                if ($unicast.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    continue
                }
                if ($null -eq $unicast.IPv4Mask) {
                    continue
                }
                $mask = $unicast.IPv4Mask.GetAddressBytes()
                if ($mask.Length -ne 4 -or $mask[0] -ne 255 -or $mask[1] -ne 255 -or $mask[2] -ne 255 -or $mask[3] -ne 0) {
                    continue
                }
                Add-Subnet -Subnets $subnets -Seen $seen -Ip $unicast.Address.ToString() -Alias $nic.Name
            }
        }
    } catch {
    }

    # 回退方案：.NET 枚举不完整时使用。
    if ($subnets.Count -eq 0 -and $null -ne (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue)) {
        try {
            $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)
            foreach ($address in $addresses) {
                if ($address.PrefixLength -ne 24) {
                    continue
                }
                if ($address.AddressState -ne 'Preferred') {
                    continue
                }
                if ($address.SkipAsSource) {
                    continue
                }
                if ($address.IPAddress -like '127.*' -or $address.IPAddress -like '169.254.*') {
                    continue
                }
                $adapter = Get-NetAdapter -InterfaceIndex $address.InterfaceIndex -ErrorAction SilentlyContinue
                if ($null -eq $adapter) {
                    continue
                }
                if ($adapter.Status -ne 'Up') {
                    continue
                }
                if ($adapter.Virtual) {
                    continue
                }
                $adapterText = [string]$adapter.Name + ' ' + [string]$adapter.InterfaceDescription
                if ($adapterText -match $script:VirtualAdapterPattern) {
                    continue
                }
                Add-Subnet -Subnets $subnets -Seen $seen -Ip $address.IPAddress -Alias $adapter.Name
            }
        } catch {
        }
    }

    return @($subnets)
}

function Find-OpenHosts {
    param(
        [object[]]$Subnets,
        [int]$PortNumber,
        [int]$BudgetMs
    )
    $openHosts = New-Object System.Collections.ArrayList
    $probes = New-Object System.Collections.ArrayList
    $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
    $localIps = @{}
    foreach ($subnet in $Subnets) {
        $localIps[$subnet.LocalIp] = $true
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($subnet in $Subnets) {
        for ($hostNumber = 1; $hostNumber -le 254; $hostNumber++) {
            $ip = $subnet.Prefix + '.' + $hostNumber
            if ($localIps.ContainsKey($ip)) {
                continue
            }
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $client.NoDelay = $true
                $address = [System.Net.IPAddress]::Parse($ip)
                $task = $client.ConnectAsync($address, $PortNumber)
                [void]$tasks.Add($task)
                [void]$probes.Add([pscustomobject]@{
                    Ip     = $ip
                    Client = $client
                    Task   = $task
                })
            } catch {
                try {
                    $client.Dispose()
                } catch {
                }
            }
        }
    }

    $remaining = $BudgetMs - [int]$stopwatch.ElapsedMilliseconds
    if ($remaining -lt 0) {
        $remaining = 0
    }
    if ($tasks.Count -gt 0 -and $remaining -gt 0) {
        $pending = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
        foreach ($taskItem in $tasks) {
            [void]$pending.Add($taskItem)
        }
        while ($pending.Count -gt 0) {
            $remaining = $BudgetMs - [int]$stopwatch.ElapsedMilliseconds
            if ($remaining -le 0) {
                break
            }
            $index = -1
            try {
                $index = [System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), $remaining)
            } catch {
                break
            }
            if ($index -lt 0) {
                break
            }
            $pending.RemoveAt($index)
        }
    }

    foreach ($probe in $probes) {
        try {
            if ($probe.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and $probe.Client.Connected) {
                [void]$openHosts.Add($probe.Ip)
            }
        } catch {
        }
        try {
            $probe.Client.Dispose()
        } catch {
        }
    }
    return @($openHosts)
}

function Get-WifiIpFromUsb {
    param([string]$Serial)
    $route = Invoke-Adb -Arguments @('-s', $Serial, 'shell', 'ip', 'route')
    if ($null -ne $route -and $route.ExitCode -eq 0) {
        foreach ($line in ($route.StdOut -split "`r?`n")) {
            if ($line -notmatch '\bwlan\d+\b') {
                continue
            }
            $match = [regex]::Match($line, '\bsrc\s+(\d{1,3}(?:\.\d{1,3}){3})')
            if ($match.Success -and (Test-PrivateIPv4 -Ip $match.Groups[1].Value)) {
                return $match.Groups[1].Value
            }
        }
    }

    $address = Invoke-Adb -Arguments @('-s', $Serial, 'shell', 'ip', 'addr', 'show', 'wlan0')
    if ($null -ne $address -and $address.ExitCode -eq 0) {
        foreach ($line in ($address.StdOut -split "`r?`n")) {
            $match = [regex]::Match($line, '\binet\s+(\d{1,3}(?:\.\d{1,3}){3})/\d+')
            if ($match.Success -and (Test-PrivateIPv4 -Ip $match.Groups[1].Value)) {
                return $match.Groups[1].Value
            }
        }
    }
    return $null
}

function Try-UsbAssist {
    param(
        [object[]]$Devices,
        [int]$PortNumber
    )
    $usbDevice = @($Devices | Where-Object {
        $_.State -eq 'device' -and $_.Serial -notmatch ':' -and $_.Serial -notmatch '^emulator-'
    } | Select-Object -First 1)
    if ($usbDevice.Count -eq 0) {
        return $null
    }
    $serial = $usbDevice[0].Serial
    $wifiIp = Get-WifiIpFromUsb -Serial $serial
    if ([string]::IsNullOrWhiteSpace($wifiIp)) {
        return $null
    }
    $tcpip = Invoke-Adb -Arguments @('-s', $serial, 'tcpip', [string]$PortNumber)
    if ($null -eq $tcpip -or $tcpip.ExitCode -ne 0) {
        return $null
    }
    if ((Get-RemainingMs) -lt 2600) {
        return $null
    }
    Start-Sleep -Milliseconds 2000
    $endpoint = $wifiIp + ':' + $PortNumber
    if (Connect-Endpoint -Endpoint $endpoint) {
        return [pscustomobject]@{ Endpoint = $endpoint; Source = 'usb-tcpip' }
    }
    if ((Get-RemainingMs) -lt 1200) {
        return $null
    }
    Start-Sleep -Milliseconds 1000
    if (Connect-Endpoint -Endpoint $endpoint) {
        return [pscustomobject]@{ Endpoint = $endpoint; Source = 'usb-tcpip' }
    }
    return $null
}

# --- 主流程 -------------------------------------------------------------

$resolvedAdb = Resolve-AdbPath -Path $AdbPath
if ($null -eq $resolvedAdb) {
    Write-Stderr ('未找到 adb：' + $AdbPath)
    exit 1
}
$script:AdbExePath = $resolvedAdb

if ($TimeoutSec -lt 1) {
    $TimeoutSec = 1
}
if ($TimeoutSec -gt 60) {
    $TimeoutSec = 60
}
$script:AdbTimeoutMs = $TimeoutSec * 1000

$effectivePort = 5555
if ($PSBoundParameters.ContainsKey('Port') -and $Port -gt 0) {
    $effectivePort = $Port
} elseif ($env:SCRCPY_WIFI_PORT -match '^\d{1,5}$') {
    $envPort = [int]$env:SCRCPY_WIFI_PORT
    if ($envPort -ge 1 -and $envPort -le 65535) {
        $effectivePort = $envPort
    }
}
if ($effectivePort -lt 1 -or $effectivePort -gt 65535) {
    Write-Stderr ('WiFi 端口无效：' + $effectivePort)
    exit 1
}

$null = Invoke-Adb -Arguments @('start-server') -TimeoutMs 5000
$devices = @(Get-AdbDevices)

# 1）复用已在线的 TCP/IP 连接。
foreach ($device in @($devices | Where-Object { $_.State -eq 'device' -and $_.Serial -match ':' })) {
    if ((Get-RemainingMs) -lt 400) {
        break
    }
    if (Test-Endpoint -Endpoint $device.Serial) {
        Write-Output ('WIFI_ENDPOINT=' + $device.Serial)
        Write-Output 'WIFI_SOURCE=existing-tcp'
        exit 0
    }
}

# 2）查询 adb mDNS：先 TLS 连接端点，再经典 _adb._tcp。
$mdnsCandidates = @(Get-MdnsCandidates)
foreach ($candidate in $mdnsCandidates) {
    if ((Get-RemainingMs) -lt 600) {
        break
    }
    if (Connect-Endpoint -Endpoint $candidate.Endpoint) {
        $source = 'mdns-adb'
        if ($candidate.Service -ieq '_adb-tls-connect._tcp') {
            $source = 'mdns-tls-connect'
        }
        Write-Output ('WIFI_ENDPOINT=' + $candidate.Endpoint)
        Write-Output ('WIFI_SOURCE=' + $source)
        exit 0
    }
}

# 3）USB 辅助。仅在 TCP/mDNS 都未验证成功时执行。
$usbResult = Try-UsbAssist -Devices $devices -PortNumber $effectivePort
if ($null -ne $usbResult) {
    Write-Output ('WIFI_ENDPOINT=' + $usbResult.Endpoint)
    Write-Output ('WIFI_SOURCE=' + $usbResult.Source)
    exit 0
}

# 4）扫描活动物理网卡的 /24 网段，总耗时上限 3 秒。
#    企业网络/EDR 环境建议设 SCRCPY_NO_LAN_SCAN=1 关闭；只有老式 adb tcpip 5555 设备才需要这一级。
if ($env:SCRCPY_NO_LAN_SCAN -eq '1') {
    Write-Stderr '已跳过局域网扫描（SCRCPY_NO_LAN_SCAN=1）'
} else {
    # 4）扫描活动物理网卡的 /24 网段，总耗时上限 3 秒。
    $scanClock = [System.Diagnostics.Stopwatch]::StartNew()
    $subnets = @(Get-LocalSubnets)
    $remainingScan = $script:ScanBudgetMs - [int]$scanClock.ElapsedMilliseconds
    $totalRemaining = Get-RemainingMs
    if ($totalRemaining - 200 -lt $remainingScan) {
        $remainingScan = $totalRemaining - 200
    }
    if ($subnets.Count -gt 0 -and $remainingScan -gt 0) {
        $openHosts = @(Find-OpenHosts -Subnets $subnets -PortNumber $effectivePort -BudgetMs $remainingScan)
        $scanConnectTimeout = 2000
        if ($script:AdbTimeoutMs -lt $scanConnectTimeout) {
            $scanConnectTimeout = $script:AdbTimeoutMs
        }
        $scanAttempts = 0
        foreach ($ip in $openHosts) {
            if ($scanAttempts -ge 16) {
                break
            }
            $scanAttempts++
            $endpoint = $ip + ':' + $effectivePort
            if (Connect-Endpoint -Endpoint $endpoint -TimeoutMs $scanConnectTimeout -NoRetry) {
                Write-Output ('WIFI_ENDPOINT=' + $endpoint)
                Write-Output 'WIFI_SOURCE=lan-scan'
                exit 0
            }
        }
    }
}

Write-Stderr '未找到可用的 WiFi 端点：已尝试现有 TCP、mDNS、USB 辅助与局域网扫描'
exit 1
