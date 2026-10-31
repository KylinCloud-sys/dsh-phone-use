# dsh-phone-use 安装脚本
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Profile desktop
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Link      # 开发时用软链接
#
# 做的事：把插件文件**复制**到 DSH profile 的 node_modules 目录下，
# 再登记到 profile 的 package.json（dependencies + dsh.profile.bundles）。
# 复制式安装不依赖源目录位置，装完源目录可以删掉/移动。
#
# 想改代码即时生效（开发模式）：加 -Link 参数，会改用 link: 软链接。

param(
  [string]$Profile = '',
  [switch]$Uninstall,
  [switch]$Link,
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

# 安全删除目录/链接：Junction / SymbolicLink 只删链接本身，绝不追进去删目标
function Remove-PackageDir([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  $item = Get-Item -LiteralPath $path -Force
  if ($item.LinkType -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    # 链接：用 .NET 删除，避免 PowerShell 追进目标目录
    try { [System.IO.Directory]::Delete($path, $false) }
    catch { cmd /c rmdir "$path" 2>$null }
  } else {
    Remove-Item -LiteralPath $path -Recurse -Force
  }
}
$pkgDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkgJsonPath = Join-Path $pkgDir 'package.json'
if (-not (Test-Path $pkgJsonPath)) { throw "找不到 package.json：$pkgJsonPath" }
$pkg = Get-Content -LiteralPath $pkgJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pkgName = $pkg.name
Write-Host "插件: $pkgName" -ForegroundColor Cyan
Write-Host "源目录: $pkgDir"

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

$targetDir = Join-Path $profDir "node_modules\$pkgName"
$raw = [System.IO.File]::ReadAllText($profJson, [System.Text.Encoding]::UTF8)

# ---------------------------------------------------------------- 卸载
if ($Uninstall) {
  # 从 dependencies 删掉
  $raw = [regex]::Replace($raw, '(?m)^\s*"' + [regex]::Escape($pkgName) + '"\s*:\s*"[^"]*",?\s*\r?\n', '')
  # 从 bundles 删掉
  $raw = [regex]::Replace($raw, '(?m)^\s*"' + [regex]::Escape($pkgName) + '",?\s*\r?\n', '')
  [System.IO.File]::WriteAllText($profJson, $raw, (New-Object System.Text.UTF8Encoding($false)))
  Remove-PackageDir $targetDir
  Write-Host "已从 profile [$Profile] 卸载 $pkgName" -ForegroundColor Green
  Write-Host "重启 DSH 后生效。" -ForegroundColor Yellow
  exit 0
}

# ---------------------------------------------------------------- 复制 / 链接
if ($Link) {
  # ---- 开发模式：软链接，改源码即时生效 ----
  Write-Host "模式: 软链接（开发用，源目录必须在）" -ForegroundColor Yellow
  Remove-PackageDir $targetDir
  # 用 Junction，不需要管理员权限（SymbolicLink 需要提权）
  $null = New-Item -ItemType Junction -Path $targetDir -Target $pkgDir -Force -ErrorAction Stop
  $depSpec = 'link:' + ($pkgDir -replace '\\', '/')
} else {
  # ---- 常规安装：复制文件 ----
  Write-Host "模式: 复制安装（装完源目录可删）" -ForegroundColor Yellow
  Remove-PackageDir $targetDir
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

  # 只复制 npm 包里该有的内容：package.json 的 files 字段 + 必要元文件
  $include = @('package.json', 'README.md', 'CHANGELOG.md', 'LICENSE')
  if ($pkg.files) { $include += $pkg.files }
  # 排除开发期文件
  $excludePatterns = @('.git', 'node_modules', '.github', '.vscode', '.idea', 'DEVLOG.md', '*.log', '*.tmp')

  $copied = 0
  foreach ($entry in ($include | Select-Object -Unique)) {
    $src = Join-Path $pkgDir $entry
    if (-not (Test-Path $src)) { continue }
    $isDir = Test-Path $src -PathType Container
    if ($isDir) {
      $dirName = $entry.TrimEnd('/').TrimEnd('\')
      Get-ChildItem (Join-Path $pkgDir $dirName) -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($pkgDir.Length).TrimStart('\', '/')
        $skip = $false
        foreach ($pat in $excludePatterns) {
          if ($rel -like "*$pat*" -or $_.Name -like $pat) { $skip = $true; break }
        }
        if ($skip) { return }
        $dest = Join-Path $targetDir $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item $_.FullName $dest -Force
        $copied++
      }
    } else {
      Copy-Item $src (Join-Path $targetDir $entry) -Force
      $copied++
    }
  }
  Write-Host "已复制 $copied 个文件到 $targetDir" -ForegroundColor Green
  $depSpec = $pkg.version
}

# ---------------------------------------------------------------- 写 profile package.json
# --- dependencies ---
if ($raw -match ('(?m)^\s*"' + [regex]::Escape($pkgName) + '"\s*:')) {
  $raw = [regex]::Replace($raw, '(?m)^(\s*"' + [regex]::Escape($pkgName) + '"\s*:\s*)"[^"]*"', ('$1"' + $depSpec + '"'))
  Write-Host "dependencies 已存在，更新为 $depSpec" -ForegroundColor DarkGray
} else {
  $idx = $raw.IndexOf('"dependencies"')
  if ($idx -lt 0) { throw 'profile package.json 里没有 dependencies 段，无法自动安装' }
  $brace = $raw.IndexOf('{', $idx)
  $depLine = "`r`n    `"$pkgName`": `"$depSpec`","
  $raw = $raw.Insert($brace + 1, $depLine)
  Write-Host "dependencies 已添加: $depSpec" -ForegroundColor DarkGray
}

# --- bundles ---
if ($raw -match ('(?m)^\s*"' + [regex]::Escape($pkgName) + '"\s*,?\s*$')) {
  Write-Host "bundles 已存在，跳过" -ForegroundColor DarkGray
} else {
  $bi = $raw.IndexOf('"bundles"')
  if ($bi -lt 0) { throw 'profile package.json 里没有 dsh.profile.bundles 段，无法自动安装' }
  $close = $raw.IndexOf(']', $bi)
  if ($close -lt 0) { throw 'bundles 数组没有闭合' }
  $before = $raw.Substring(0, $close).TrimEnd()
  $needsComma = -not $before.EndsWith('[') -and -not $before.EndsWith(',')
  $insert = ($(if ($needsComma) { ',' } else { '' })) + "`r`n        `"$pkgName`"`r`n      "
  $raw = $raw.Substring(0, $close) + $insert + $raw.Substring($close)
  Write-Host "bundles 已添加" -ForegroundColor DarkGray
}

# --- 校验 JSON 合法性再落盘 ---
try { $null = $raw | ConvertFrom-Json } catch {
  throw "生成的 profile package.json 不是合法 JSON，已中止写入。请手动检查 $profJson"
}
[System.IO.File]::WriteAllText($profJson, $raw, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "已写入 $profJson" -ForegroundColor Green

# ---------------------------------------------------------------- pnpm install（仅装其他依赖）
if (-not $SkipInstall -and -not $Link) {
  # 复制模式下插件本体已在 node_modules，但 profile 的其他依赖可能还没装
  $pm = $null
  if (Get-Command pnpm -ErrorAction SilentlyContinue) { $pm = 'pnpm' }
  elseif (Get-Command npm -ErrorAction SilentlyContinue) { $pm = 'npm' }
  if (-not $pm) {
    Write-Host "既没有 pnpm 也没有 npm，跳过依赖安装（插件本体已复制，通常不影响使用）" -ForegroundColor Yellow
  } else {
    Push-Location $profDir
    try {
      Write-Host "执行 $pm install（补齐 profile 依赖，可能需要一两分钟）..."
      # --ignore-scripts 避免重装时把已复制目录清掉；失败不致命
      if ($pm -eq 'pnpm') {
        & pnpm install --reporter=append-only 2>&1 | Select-Object -Last 6
      } else {
        & npm install --no-audit --no-fund 2>&1 | Select-Object -Last 6
      }
    } catch {
      Write-Host "依赖安装有告警（插件本体已就位）：$($_.Exception.Message)" -ForegroundColor Yellow
    } finally { Pop-Location }
  }
}

# ---------------------------------------------------------------- 校验
$check = Join-Path $targetDir 'index.js'
if (Test-Path $check) {
  Write-Host "安装就绪: $(Join-Path $targetDir 'index.js')" -ForegroundColor Green
} else {
  Write-Host "安装异常：$targetDir 下找不到 index.js" -ForegroundColor Red
  exit 1
}
$cpu = Join-Path $targetDir 'client\permission-switch.js'
if (Test-Path $cpu) { Write-Host "客户端 UI 已就位: $cpu" -ForegroundColor Green }

Write-Host ""
Write-Host "下一步：重启 DSH，然后新建一个会话。" -ForegroundColor Cyan
Write-Host "应出现六个工具 mcp__phone__phone_wake / phone_info / phone_see / phone_panel / phone_back / phone_do，" -ForegroundColor Cyan
Write-Host "技能 phone，以及输入框右下角的「手机权限」三档下拉。" -ForegroundColor Cyan
Write-Host "权限档位: 改 $targetDir\config.json 里的 permission，即时生效无需重启。"
