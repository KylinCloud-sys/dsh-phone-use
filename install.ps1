# dsh-phone-use 安装脚本
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Profile desktop
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#
# 做的事：把插件按 link 方式挂进 DSH profile（package.json 的 dependencies + dsh.profile.bundles），
# 然后跑 pnpm install 建链接。全程只改这一个 profile 的两处 JSON 片段，可重复执行。

param(
  [string]$Profile = '',
  [switch]$Uninstall,
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$pkgDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgJsonPath = Join-Path $pkgDir 'package.json'
if (-not (Test-Path $pkgJsonPath)) { throw "找不到 package.json：$pkgJsonPath" }
$pkgName = (Get-Content -LiteralPath $pkgJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json).name
Write-Host "插件: $pkgName" -ForegroundColor Cyan
Write-Host "目录: $pkgDir"

# --- 定位 profile ---
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$profilesRoot = Join-Path $dshHome 'profiles'
if (-not (Test-Path $profilesRoot)) { throw "没找到 DSH profiles 目录：$profilesRoot（DSH 装好并至少启动过一次才会生成）" }

if (-not $Profile) {
  $candidates = Get-ChildItem $profilesRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'package.json') }
  if ($candidates.Count -eq 0) { throw "在 $profilesRoot 下没有找到带 package.json 的 profile" }
  $desktop = $candidates | Where-Object { $_.Name -eq 'desktop' }
  if ($desktop) { $Profile = 'desktop' } else { $Profile = $candidates[0].Name }
  $names = ($candidates | ForEach-Object { $_.Name }) -join ', '
  Write-Host "自动选择 profile: $Profile（可选: $names）" -ForegroundColor Yellow
}

$profDir = Join-Path $profilesRoot $Profile
$profJson = Join-Path $profDir 'package.json'
if (-not (Test-Path $profJson)) { throw "profile 不存在：$profDir" }

$raw = [System.IO.File]::ReadAllText($profJson, [System.Text.Encoding]::UTF8)
$linkSpec = 'link:' + ($pkgDir -replace '\\', '/')

if ($Uninstall) {
  # 从 dependencies 删掉
  $raw = [regex]::Replace($raw, '(?m)^\s*"' + [regex]::Escape($pkgName) + '"\s*:\s*"[^"]*",?\s*\r?\n', '')
  # 从 bundles 删掉
  $raw = [regex]::Replace($raw, '(?m)^\s*"' + [regex]::Escape($pkgName) + '",?\s*\r?\n', '')
  [System.IO.File]::WriteAllText($profJson, $raw, (New-Object System.Text.UTF8Encoding($false)))
  $nm = Join-Path $profDir "node_modules\$pkgName"
  if (Test-Path $nm) { Remove-Item $nm -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Host "已从 profile [$Profile] 卸载 $pkgName" -ForegroundColor Green
  Write-Host "重启 DSH 后生效。" -ForegroundColor Yellow
  exit 0
}

# --- 写 dependencies ---
$depLine = '    "' + $pkgName + '": "' + $linkSpec + '",'
if ($raw -match ('(?m)^\s*"' + [regex]::Escape($pkgName) + '"\s*:')) {
  $raw = [regex]::Replace($raw, '(?m)^(\s*"' + [regex]::Escape($pkgName) + '"\s*:\s*)"[^"]*"', ('$1"' + $linkSpec + '"'))
  Write-Host "dependencies 已存在，更新链接路径" -ForegroundColor DarkGray
} else {
  $idx = $raw.IndexOf('"dependencies"')
  if ($idx -lt 0) { throw 'profile package.json 里没有 dependencies 段，无法自动安装' }
  $brace = $raw.IndexOf('{', $idx)
  $raw = $raw.Insert($brace + 1, "`r`n" + $depLine)
  Write-Host "dependencies 已添加" -ForegroundColor DarkGray
}

# --- 写 bundles ---
if ($raw -match ('(?m)^\s*"' + [regex]::Escape($pkgName) + '"\s*,?\s*$')) {
  Write-Host "bundles 已存在，跳过" -ForegroundColor DarkGray
} else {
  $bi = $raw.IndexOf('"bundles"')
  if ($bi -lt 0) { throw 'profile package.json 里没有 dsh.profile.bundles 段，无法自动安装' }
  $close = $raw.IndexOf(']', $bi)
  if ($close -lt 0) { throw 'bundles 数组没有闭合' }
  # 补到上一个元素后面，逗号处理
  $before = $raw.Substring(0, $close).TrimEnd()
  $needsComma = -not $before.EndsWith('[') -and -not $before.EndsWith(',')
  $insert = ($(if ($needsComma) { ',' } else { '' })) + "`r`n        `"$pkgName`"`r`n      "
  $raw = $raw.Substring(0, $close) + $insert + $raw.Substring($close)
  Write-Host "bundles 已添加" -ForegroundColor DarkGray
}

[System.IO.File]::WriteAllText($profJson, $raw, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "已写入 $profJson" -ForegroundColor Green

# --- pnpm install ---
if (-not $SkipInstall) {
  $pm = $null
  if (Get-Command pnpm -ErrorAction SilentlyContinue) { $pm = 'pnpm' }
  elseif (Get-Command npm -ErrorAction SilentlyContinue) { $pm = 'npm' }
  if (-not $pm) { Write-Host "既没有 pnpm 也没有 npm，请手动在 $profDir 里安装依赖" -ForegroundColor Red; exit 1 }
  Push-Location $profDir
  try {
    Write-Host "执行 $pm install ..."
    if ($pm -eq 'pnpm') {
      & pnpm install --reporter=append-only 2>&1 | Select-Object -Last 6
    } else {
      & npm install --no-audit --no-fund 2>&1 | Select-Object -Last 6
    }
  } finally { Pop-Location }
}

$linked = Join-Path $profDir "node_modules\$pkgName\index.js"
if (Test-Path $linked) {
  Write-Host "链接就绪: $linked" -ForegroundColor Green
} else {
  Write-Host "链接未建立，请手动在 $profDir 里跑 pnpm install" -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "下一步：重启 DSH。启动后应出现 phone_wake / phone_info / phone_see / phone_do 四个工具与技能 phone。" -ForegroundColor Cyan
Write-Host "自检日志: $env:TEMP\dsh-phone-use\plugin-boot.log"
Write-Host "权限档位: 改 $pkgDir\config.json 里的 permission，即时生效无需重启。"
