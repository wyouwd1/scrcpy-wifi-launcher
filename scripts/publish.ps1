#Requires -Version 5.1
<#
.SYNOPSIS
    一键将 scrcpy-wifi-launcher 发布到 GitHub。

.DESCRIPTION
    检查 git、gh、登录状态与工作区，创建初始 commit 和 GitHub 仓库，
    设置 topics 并打印仓库 URL。

    没有 gh 或 gh 未登录时，只打印“网页建仓 + git remote add + git push”的
    手动兜底步骤，不会尝试安装 gh，也不会索要 token。

.PARAMETER RepoName
    GitHub 仓库名，默认 scrcpy-wifi-launcher。

.PARAMETER Visibility
    仓库可见性，public 或 private，默认 public。

.PARAMETER Owner
    仓库所有者（用户或组织），默认取 gh 当前登录用户。

.PARAMETER DryRun
    只打印将执行的命令，不修改本地仓库，也不创建远程仓库。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\publish.ps1 -DryRun

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\publish.ps1 -Visibility private
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$RepoName = 'scrcpy-wifi-launcher',

    [ValidateSet('public', 'private')]
    [string]$Visibility = 'public',

    [string]$Owner,

    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------- 输出辅助 ----------
function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[信息] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[完成] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[警告] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[错误] $Message" -ForegroundColor Red
}

function Write-CommandLine {
    param([Parameter(Mandatory = $true)][string]$Command)
    Write-Host "  > $Command" -ForegroundColor DarkGray
}

function Test-CommandAvailable {
    param([Parameter(Mandatory = $true)][string]$Name)
    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    return ($null -ne $command)
}

function Show-ManualFallback {
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][string]$TargetOwner
    )
    Write-Warn -Message $Reason
    Write-Host ''
    Write-Host '可按以下步骤手动发布（不需要 gh，也不需要 token）：' -ForegroundColor Yellow
    Write-Host '  1. 打开 https://github.com/new 创建仓库'
    Write-Host "     仓库名：$RepoName    可见性：$Visibility"
    Write-Host '     不要勾选 README、.gitignore、license，保持空仓库'
    Write-Host '  2. 在项目根目录执行：'
    if (-not $script:IsRepo) {
        Write-Host '     git init -b main'
        Write-Host '     git add -A'
        Write-Host '     git commit -m "chore: 初始化 scrcpy-wifi-launcher"'
    } elseif (-not $script:HasCommit) {
        Write-Host '     git add -A'
        Write-Host '     git commit -m "chore: 初始化 scrcpy-wifi-launcher"'
    }
    Write-Host "     git remote add origin https://github.com/$TargetOwner/$RepoName.git"
    Write-Host '     git push -u origin main'
    Write-Host '  3. 打开仓库 Settings -> Topics，添加：'
    Write-Host '     scrcpy adb wifi android windows powershell'
    Write-Host ''
    Write-Host '如果 origin 已存在，改用：'
    Write-Host "     git remote set-url origin https://github.com/$TargetOwner/$RepoName.git"
}

# ---------- 参数与项目根目录 ----------
if ([string]::IsNullOrWhiteSpace($RepoName)) {
    Write-Fail -Message 'RepoName 不能为空。'
    exit 1
}
if (-not [string]::IsNullOrWhiteSpace($Owner) -and $Owner -notmatch '^[A-Za-z0-9-]+$') {
    Write-Fail -Message "Owner 含非法字符：$Owner（只允许字母、数字和连字符）。"
    exit 1
}

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'src'))) {
    Write-Fail -Message "未找到项目根目录（缺少 src/）：$($script:RepoRoot)"
    exit 1
}
Set-Location -LiteralPath $script:RepoRoot
Write-Info -Message "项目根目录：$($script:RepoRoot)"

$script:IsRepo = $false
$script:HasCommit = $false

# ---------- 前置检查：git ----------
Write-Info -Message '检查 git / gh ...'
if (-not (Test-CommandAvailable -Name 'git')) {
    Write-Fail -Message '未找到 git，无法继续。请先安装 Git for Windows：https://git-scm.com/download/win'
    exit 1
}

# ---------- 前置检查：gh 与登录状态 ----------
$ghAvailable = Test-CommandAvailable -Name 'gh'
$ghAuthed = $false
$ghLogin = ''
if ($ghAvailable) {
    $authExit = 1
    try {
        & gh auth status 2>&1 | Out-Null
        $authExit = $LASTEXITCODE
    } catch {
        $authExit = 1
    }
    if ($authExit -eq 0) {
        $ghAuthed = $true
        try {
            $loginOutput = @(& gh api user --jq '.login' 2>$null)
            if ($LASTEXITCODE -eq 0 -and $loginOutput.Count -gt 0) {
                $ghLogin = ([string]$loginOutput[0]).Trim()
            }
        } catch {
            $ghLogin = ''
        }
    }
} else {
    Write-Warn -Message '未找到 GitHub CLI（gh）。'
}

if ([string]::IsNullOrWhiteSpace($Owner) -and -not [string]::IsNullOrWhiteSpace($ghLogin)) {
    $Owner = $ghLogin
}
$displayOwner = if ([string]::IsNullOrWhiteSpace($Owner)) { '<你的GitHub用户名>' } else { $Owner }

# ---------- 前置检查：工作区状态 ----------
& git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -eq 0) { $script:IsRepo = $true }

if ($script:IsRepo) {
    & git rev-parse --verify HEAD *> $null
    if ($LASTEXITCODE -eq 0) { $script:HasCommit = $true }
}

if ($script:IsRepo -and $script:HasCommit) {
    $changes = @(& git status --porcelain)
    if ($changes.Count -gt 0) {
        if ($DryRun) {
            Write-Warn -Message "工作区有 $($changes.Count) 项未提交改动；正式发布会中止，请先提交或 stash。"
        } else {
            Write-Fail -Message "工作区不干净（$($changes.Count) 项改动），请先提交或 stash 后再发布："
            $changes | ForEach-Object { Write-Host "  $_" }
            exit 1
        }
    }
}

$originUrl = ''
if ($script:IsRepo) {
    $remotes = @(& git remote)
    if ($remotes -contains 'origin') {
        $originUrl = (& git remote get-url origin)
        if ($DryRun) {
            Write-Warn -Message "已存在 origin（$originUrl）；正式发布会中止。"
        } else {
            Write-Fail -Message "已存在 origin 远程：$originUrl"
            Write-Info -Message '如果 origin 指向旧仓库，请先执行：git remote remove origin'
            exit 1
        }
    }
}

# ---------- gh 不可用时的手动兜底 ----------
if (-not ($ghAvailable -and $ghAuthed)) {
    $reason = if (-not $ghAvailable) {
        '未找到 gh，跳过自动建仓。'
    } else {
        'gh 未登录，跳过自动建仓。'
    }
    Show-ManualFallback -Reason $reason -TargetOwner $displayOwner
    if ($DryRun) {
        Write-Info -Message 'DryRun 结束：未执行任何修改。'
        exit 0
    }
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Owner)) {
    Write-Fail -Message '无法从 gh 获取当前登录用户，请用 -Owner 显式指定仓库所有者。'
    exit 1
}

$fullName = "$Owner/$RepoName"

# ---------- 远程仓库是否已存在 ----------
& gh repo view $fullName *> $null
if ($LASTEXITCODE -eq 0) {
    if ($DryRun) {
        Write-Warn -Message "远程仓库已存在：https://github.com/$fullName"
    } else {
        Write-Fail -Message "远程仓库已存在：https://github.com/$fullName"
        Write-Info -Message '如只想推送现有代码，请手动配置 origin 后执行：git push -u origin main'
        exit 1
    }
}

# ---------- 初始化仓库与初始 commit ----------
if (-not $script:IsRepo) {
    Write-Info -Message '初始化 git 仓库 ...'
    if ($DryRun) {
        Write-CommandLine -Command 'git init -b main'
    } else {
        & git init -b main | Out-Host
        if ($LASTEXITCODE -ne 0) {
            # 兼容不支持 -b 的旧版 git
            & git init | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'git init 失败' }
            & git symbolic-ref HEAD refs/heads/main | Out-Host
        }
        $script:IsRepo = $true
    }
}

if (-not $script:HasCommit) {
    Write-Info -Message '创建初始 commit ...'
    if ($DryRun) {
        Write-CommandLine -Command 'git add -A'
        Write-CommandLine -Command 'git commit -m "chore: 初始化 scrcpy-wifi-launcher"'
    } else {
        & git add -A | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'git add 失败' }
        & git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            $userName = (& git config user.name)
            $userEmail = (& git config user.email)
            if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($userEmail)) {
                Write-Fail -Message 'git 未配置 user.name / user.email，无法创建 commit。请先执行：'
                Write-Host '  git config --global user.name "你的名字"'
                Write-Host '  git config --global user.email "you@example.com"'
                exit 1
            }
            & git -c i18n.commitEncoding=UTF-8 commit -m 'chore: 初始化 scrcpy-wifi-launcher' | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'git commit 失败' }
        } else {
            Write-Warn -Message '没有可提交的文件，跳过初始 commit。'
        }
    }
}

# ---------- 创建远程仓库并推送 ----------
Write-Info -Message "创建 GitHub 仓库 $fullName（$Visibility）..."
if ($DryRun) {
    Write-CommandLine -Command "gh repo create $fullName --$Visibility --source . --remote origin --push"
} else {
    & gh repo create $fullName "--$Visibility" --source . --remote origin --push | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "gh repo create 失败（退出码 $LASTEXITCODE）"
    }
}

# ---------- 设置 topics ----------
$topics = @('scrcpy', 'adb', 'wifi', 'android', 'windows', 'powershell')
$topicList = $topics -join ','
if ($DryRun) {
    Write-CommandLine -Command "gh repo edit $fullName --add-topic $topicList"
} else {
    & gh repo edit $fullName --add-topic $topicList | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Warn -Message 'topics 设置失败，可稍后在仓库页面手动添加：scrcpy adb wifi android windows powershell'
    }
}

# ---------- 打印仓库 URL ----------
$repoUrl = "https://github.com/$fullName"
if (-not $DryRun) {
    $urlOutput = @(& gh repo view $fullName --json url --jq '.url' 2>$null)
    if ($LASTEXITCODE -eq 0 -and $urlOutput.Count -gt 0) {
        $repoUrl = ([string]$urlOutput[0]).Trim()
    }
}

Write-Host ''
Write-Ok -Message "仓库地址：$repoUrl"
if ($DryRun) {
    Write-Info -Message 'DryRun 结束：以上命令均未执行。'
    exit 0
}

Write-Info -Message '后续发布 tag 会自动触发 Release workflow：'
Write-Host '  git tag v1.0.0'
Write-Host '  git push origin v1.0.0'
