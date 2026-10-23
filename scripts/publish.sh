#!/usr/bin/env bash
# 一键把本仓库发布到 GitHub（WSL / Linux / macOS 版）
# 依赖：git、gh（GitHub CLI，已登录）
# 用法：
#   ./scripts/publish.sh                      # 默认 public，仓库名取目录名
#   ./scripts/publish.sh --private            # 私有仓库
#   ./scripts/publish.sh --name my-launcher   # 自定义仓库名
#   ./scripts/publish.sh --dry-run            # 只打印将执行的命令
set -euo pipefail

REPO_NAME="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
VISIBILITY="public"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) REPO_NAME="$2"; shift 2 ;;
    --private) VISIBILITY="private"; shift ;;
    --public) VISIBILITY="public"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    echo "[run] $*"
    "$@"
  fi
}

echo "== 前置检查 =="
command -v git >/dev/null || { echo "缺少 git" >&2; exit 1; }
command -v gh  >/dev/null || {
  cat >&2 <<'EOF'
缺少 GitHub CLI（gh）。三种装法任选：
  Ubuntu/WSL: sudo apt install gh
  macOS:      brew install gh
  Windows:    winget install --id GitHub.cli
装完执行 gh auth login 登录后再跑本脚本。
EOF
  exit 1
}
gh auth status >/dev/null 2>&1 || {
  echo "gh 未登录。先执行：gh auth login --hostname github.com --git-protocol ssh --web" >&2
  exit 1
}

OWNER="$(gh api user --jq .login)"
echo "账号：$OWNER"
echo "仓库：$OWNER/$REPO_NAME（$VISIBILITY）"

if gh repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  echo "仓库已存在，跳过创建，直接推送。"
  if ! git remote get-url origin >/dev/null 2>&1; then
    run git remote add origin "git@github.com:$OWNER/$REPO_NAME.git"
  fi
  run git push -u origin HEAD:main
else
  run gh repo create "$OWNER/$REPO_NAME" \
    "--$VISIBILITY" --source . --remote origin --push \
    --description "Windows 下 scrcpy 5.0.1 中文启动器：双击即自动连 WiFi / USB，零配置"
fi

echo "== 设置 topics =="
run gh repo edit "$OWNER/$REPO_NAME" \
  --add-topic scrcpy --add-topic adb --add-topic wifi \
  --add-topic android --add-topic windows --add-topic powershell

echo "== 完成 =="
echo "https://github.com/$OWNER/$REPO_NAME"
