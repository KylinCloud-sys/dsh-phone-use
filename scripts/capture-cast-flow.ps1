# 一次性取证脚本：主人手动发起投屏时，记录管家实际做了哪些事。
# 只做观测（进程快照 + 窗口快照 + 管道快照），不注入、不点击、不修改任何状态。
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File capture-cast-flow.ps1 -Seconds 90

param(
  [int]$Seconds = 90,
  [int]$IntervalMs = 700,
  [string]$OutFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'

if (-not $OutFile) {
  $OutFile = Join-Path $env:TEMP ('cast-flow-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
}

Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;

public class CastWatch
{
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public static List<string> SnapshotWindows()
    {
        var rows = new List<string>();
        EnumWindows((h, l) =>
        {
            string cls = ClassOf(h);
            string title = TitleOf(h);
            // 按标题/类名前缀匹配，不硬编码设备相关类名（该类名由设备 ID 派生）
            bool byTitle = title.StartsWith("妙享桌面") || title.StartsWith("跨屏协作");
            if (cls.StartsWith("kMi") || byTitle || cls.StartsWith("WinUIDesktop"))
            {
                uint pid; GetWindowThreadProcessId(h, out pid);
                RECT r; GetWindowRect(h, out r);
                rows.Add(string.Format("{0}|pid={1}|{2}|title={3}|vis={4}|{5}x{6}",
                    h, pid, cls, TitleOf(h), IsWindowVisible(h), r.Right - r.Left, r.Bottom - r.Top));
            }
            return true;
        }, IntPtr.Zero);
        rows.Sort(StringComparer.Ordinal);
        return rows;
    }

    static string ClassOf(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
    static string TitleOf(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
}
'@

function Get-PipeSnapshot {
  $names = @()
  try {
    $names = [IO.Directory]::GetFiles('\\.\pipe\') | ForEach-Object { $_.Substring(9) }
  } catch { }
  # 只看和投屏可能相关的，避免刷屏
  # mojo.* 是 Chromium 系内部管道，与投屏无关，过滤掉减少噪音
  $names | Where-Object { $_ -match 'mi|share|cast|screen|cont' } | Where-Object { $_ -notmatch 'mojo\.|crashpad_|AppContainerNamedObjects' } | Sort-Object -Unique
}

function Get-ProcSnapshot {
  Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match 'XiaomiPcManager|MiScreenShare|MiSmartShare|MiPlayCast|micont|MiService|distfile' } |
    Sort-Object ProcessId |
    ForEach-Object {
      $cmd = $_.CommandLine
      if ($cmd -and $cmd.Length -gt 220) { $cmd = $cmd.Substring(0, 220) + '...' }
      "{0}|{1}|ppid={2}|{3}" -f $_.ProcessId, $_.Name, $_.ParentProcessId, $cmd
    }
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# cast flow capture  started=$(Get-Date -Format 'HH:mm:ss.fff')  seconds=$Seconds  interval=${IntervalMs}ms")
$lines.Add('# 主人现在手动发起投屏；本脚本只观测，不点击、不注入。')
$lines.Add('')

$prevProc = @{}
$prevWin = @{}
$prevPipe = @{}
$deadline = (Get-Date).AddSeconds($Seconds)
$tick = 0

while ((Get-Date) -lt $deadline) {
  $tick++
  $stamp = (Get-Date).ToString('HH:mm:ss.fff')

  $proc = @{}
  foreach ($p in (Get-ProcSnapshot)) { $proc[$p] = $true }
  $win = @{}
  foreach ($w in ([CastWatch]::SnapshotWindows())) { $win[$w] = $true }
  $pipe = @{}
  foreach ($p in (Get-PipeSnapshot)) { $pipe[$p] = $true }

  $events = New-Object System.Collections.Generic.List[string]

  foreach ($k in $proc.Keys) { if (-not $prevProc.ContainsKey($k)) { $events.Add("  + PROC  $k") } }
  foreach ($k in $prevProc.Keys) { if (-not $proc.ContainsKey($k)) { $events.Add("  - PROC  $k") } }
  foreach ($k in $win.Keys) { if (-not $prevWin.ContainsKey($k)) { $events.Add("  + WIN   $k") } }
  foreach ($k in $prevWin.Keys) { if (-not $win.ContainsKey($k)) { $events.Add("  - WIN   $k") } }
  foreach ($k in $pipe.Keys) { if (-not $prevPipe.ContainsKey($k)) { $events.Add("  + PIPE  $k") } }
  foreach ($k in $prevPipe.Keys) { if (-not $pipe.ContainsKey($k)) { $events.Add("  - PIPE  $k") } }

  if ($events.Count -gt 0) {
    $lines.Add("[$stamp]")
    foreach ($e in $events) { $lines.Add($e) }
    $lines.Add('')
    # 有变化就落盘，避免中断丢数据
    [IO.File]::WriteAllLines($OutFile, $lines, (New-Object Text.UTF8Encoding($false)))
  }

  $prevProc = $proc
  $prevWin = $win
  $prevPipe = $pipe

  Start-Sleep -Milliseconds $IntervalMs
}

$lines.Add("# ended=$(Get-Date -Format 'HH:mm:ss.fff')  ticks=$tick")
[IO.File]::WriteAllLines($OutFile, $lines, (New-Object Text.UTF8Encoding($false)))
Write-Output "LOG=$OutFile"
Write-Output "TICKS=$tick"
