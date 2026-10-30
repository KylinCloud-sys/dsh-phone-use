# dsh-phone-use 推送脚本（自动排除 DEVLOG.md）
#
# 背景：DEVLOG.md 允许本地追踪（git add/commit 留痕），但不允许推送到远端。
# Git 本身没有「按文件排除推送」的能力，所以这里用：
#   1. 临时把 DEVLOG.md 从索引移除并提交一个「推送用」提交
#   2. 推送（此时远端树里没有 DEVLOG.md）
#   3. 本地软回退那个提交，并把 DEVLOG.md 重新加回索引
# 这样本地始终保留 DEVLOG 的完整版本历史，远端永远拿不到它。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts/push-public.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/push-public.ps1 -Branch master -Remote origin

param(
  [string]$Remote = 'origin',
  [string]$Branch = 'master',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $repoRoot
try {
  $devlog = 'DEVLOG.md'

  # --- 检查工作区 ---
  $dirty = git status --porcelain
  if ($dirty) {
    Write-Host '工作区有未提交改动，先提交再推送：' -ForegroundColor Red
    $dirty | ForEach-Object { Write-Host "  $_" }
    exit 1
  }

  if (-not (Test-Path $devlog)) {
    Write-Host "警告：$devlog 不存在，可能是首次 clone。将直接推送。" -ForegroundColor Yellow
    if (-not $DryRun) { git push $Remote $Branch }
    exit 0
  }

  $tracked = (git ls-files -- $devlog)
  if (-not $tracked) {
    Write-Host "$devlog 未被追踪，直接推送。" -ForegroundColor DarkGray
    if (-not $DryRun) { git push $Remote $Branch }
    exit 0
  }

  Write-Host "1) 临时把 $devlog 移出版本索引..." -ForegroundColor Cyan
  git rm --cached --quiet -- $devlog
  git commit --quiet -m 'chore: 推送用临时提交（排除 DEVLOG.md）'
  $tempCommit = (git rev-parse HEAD).Trim()
  Write-Host "   临时提交: $tempCommit" -ForegroundColor DarkGray

  try {
    if ($DryRun) {
      Write-Host "2) [DryRun] 将要推送 $tempCommit -> $Remote/$Branch" -ForegroundColor Yellow
    } else {
      Write-Host "2) 推送 $tempCommit -> $Remote/$Branch ..." -ForegroundColor Cyan
      git push $Remote $Branch
      if ($LASTEXITCODE -ne 0) { throw "推送失败（exit $LASTEXITCODE）" }
    }
  } finally {
    Write-Host "3) 本地回退临时提交，恢复 $devlog 追踪..." -ForegroundColor Cyan
    git reset --soft --quiet HEAD~1
    git add --quiet -- $devlog
    Write-Host "   已还原，$devlog 仍在本地索引中" -ForegroundColor DarkGray
  }

  # --- 验证远端确实没有 DEVLOG ---
  if (-not $DryRun) {
    git fetch --quiet $Remote 2>$null
    $remoteHas = (git ls-tree "$Remote/$Branch" --name-only | Select-String -SimpleMatch $devlog)
    if ($remoteHas) {
      Write-Host "验证失败：远端仍存在 $devlog ！" -ForegroundColor Red
      exit 1
    }
    Write-Host '验证通过：远端不含 DEVLOG.md' -ForegroundColor Green
  }
} finally {
  Pop-Location
}
