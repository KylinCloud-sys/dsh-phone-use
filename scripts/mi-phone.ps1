<#
.SYNOPSIS
  dsh-mi-phone-use 底层执行器：小米互联（跨屏协作）手机窗口的全后台操控。

.DESCRIPTION
  设计参照 D:\Bullet-Trader\phone_trader\delta_trader\window.py 与 background_capture.py
  （只读参考，未修改其任何文件）：
    - 父窗口按标题「跨屏协作 / 妙享桌面」定位；
    - 画面子窗口取可见面积最大、层级最深的子孙（默认 kMiChildSharedWindow）；
    - 坐标基准 = 子窗口 client 区（就是标定 GUI 里「不带边框」的那个尺寸）；
    - 点击/滑动/按键全部走窗口消息，不抢前台、不移动鼠标。

  调用方式（结果写文件，避免中文走控制台编码）：
    powershell -NoProfile -ExecutionPolicy Bypass -File mi-phone.ps1 -RequestFile req.json -ResultFile res.json

  请求 JSON：
    {"action":"info"}
    {"action":"capture","out":"...png","prev":"...png","region":[x,y,w,h],"maxWidth":0}
    {"action":"tap","x":50,"y":88}            # 百分比
    {"action":"swipe","from":[50,95],"to":[50,40],"ms":300}
    {"action":"text","value":"你好 abc"}
    {"action":"key","name":"backspace","n":3}
    {"action":"restore"}
#>
param(
  [Parameter(Mandatory = $true)][string]$RequestFile,
  [string]$ResultFile
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# 原生层
# ---------------------------------------------------------------------------
$source = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace MiPhone
{
    public class Native
    {
        public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);

        [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion U; }
        [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
        public const uint INPUT_KEYBOARD = 1, KEYEVENTF_UNICODE = 0x0004, KEYEVENTF_KEYUP = 0x0002;

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
        [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint map);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern short VkKeyScan(char ch);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

        public static string ClassOf(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
        public static string TitleOf(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }

        // 父窗口：class 命中优先，其次标题精确，再次标题前缀（「妙享桌面-设备名」会变长）
        public static IntPtr FindParent(string[] titles, string className)
        {
            IntPtr best = IntPtr.Zero;
            int bestScore = 0;
            EnumWindows((h, l) =>
            {
                if (!IsWindowVisible(h)) return true;
                string cls = ClassOf(h);
                string title = TitleOf(h);
                int score = 0;
                if (!string.IsNullOrEmpty(className) && cls == className) score = 5;
                foreach (var t in titles)
                {
                    if (string.IsNullOrEmpty(t)) continue;
                    if (title == t) score = Math.Max(score, 4);
                    else if (title.StartsWith(t, StringComparison.Ordinal)) score = Math.Max(score, 3);
                }
                if (score > bestScore) { bestScore = score; best = h; }
                return true;
            }, IntPtr.Zero);
            return bestScore >= 3 ? best : IntPtr.Zero;
        }

        // 画面子窗口：可见面积最大，面积相同取层级更深的
        public static IntPtr FindChild(IntPtr parent, string childClass)
        {
            IntPtr best = IntPtr.Zero;
            long bestArea = 0;
            int bestDepth = -1;
            EnumChildWindows(parent, (h, l) =>
            {
                if (!IsWindowVisible(h)) return true;
                string cls = ClassOf(h);
                if (!string.IsNullOrEmpty(childClass) && cls != childClass) return true;
                RECT r;
                if (!GetClientRect(h, out r)) return true;
                int w = r.Right - r.Left, hgt = r.Bottom - r.Top;
                if (w <= 0 || hgt <= 0) return true;
                long area = (long)w * hgt;
                int depth = 0;
                IntPtr cur = h;
                var seen = new HashSet<IntPtr>();
                while (cur != IntPtr.Zero && cur != parent && seen.Add(cur)) { cur = GetParent(cur); depth++; }
                if (area > bestArea || (area == bestArea && depth > bestDepth))
                { best = h; bestArea = area; bestDepth = depth; }
                return true;
            }, IntPtr.Zero);
            return best;
        }
    }

    public class Img
    {
        public static string Hash(Bitmap bmp)
        {
            var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
            var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            byte[] buf;
            try
            {
                int len = Math.Abs(data.Stride) * data.Height;
                buf = new byte[len];
                Marshal.Copy(data.Scan0, buf, 0, len);
            }
            finally { bmp.UnlockBits(data); }
            using (var sha = System.Security.Cryptography.SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(buf)).Replace("-", "").ToLowerInvariant();
        }

        // 按 block 分块、带容差比较（投屏是视频流，逐像素必然有噪声）。
        // 块内「明显不同」的像素占比超过 blockRatio 才记为变化块。
        // 返回 {x, y, w, h, changedBlocks}，无变化返回 null。
        public static int[] DiffBox(Bitmap a, Bitmap b, int block, int tol, double blockRatio)
        {
            if (a.Width != b.Width || a.Height != b.Height) return new int[] { 0, 0, a.Width, a.Height };
            int w = a.Width, h = a.Height;
            var rect = new Rectangle(0, 0, w, h);
            var da = a.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            var db = b.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                int stride = da.Stride;
                var ba = new byte[stride * h];
                var bb = new byte[stride * h];
                Marshal.Copy(da.Scan0, ba, 0, ba.Length);
                Marshal.Copy(db.Scan0, bb, 0, bb.Length);
                int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
                int changedBlocks = 0;
                for (int by = 0; by < h; by += block)
                {
                    int yEnd = Math.Min(by + block, h);
                    for (int bx = 0; bx < w; bx += block)
                    {
                        int xEnd = Math.Min(bx + block, w);
                        int total = (xEnd - bx) * (yEnd - by);
                        int diff = 0;
                        for (int y = by; y < yEnd; y++)
                        {
                            int row = y * stride;
                            for (int x = bx; x < xEnd; x++)
                            {
                                int i = row + x * 4;
                                int d0 = ba[i] - bb[i]; if (d0 < 0) d0 = -d0;
                                if (d0 > tol) { diff++; continue; }
                                int d1 = ba[i + 1] - bb[i + 1]; if (d1 < 0) d1 = -d1;
                                if (d1 > tol) { diff++; continue; }
                                int d2 = ba[i + 2] - bb[i + 2]; if (d2 < 0) d2 = -d2;
                                if (d2 > tol) diff++;
                            }
                        }
                        if (diff > total * blockRatio)
                        {
                            changedBlocks++;
                            if (bx < minX) minX = bx;
                            if (xEnd > maxX) maxX = xEnd;
                            if (by < minY) minY = by;
                            if (yEnd > maxY) maxY = yEnd;
                        }
                    }
                }
                if (maxX < 0) return null;
                int pad = block;
                minX = Math.Max(0, minX - pad); minY = Math.Max(0, minY - pad);
                maxX = Math.Min(w, maxX + pad); maxY = Math.Min(h, maxY + pad);
                return new int[] { minX, minY, maxX - minX, maxY - minY, changedBlocks };
            }
            finally
            {
                a.UnlockBits(da);
                b.UnlockBits(db);
            }
        }

        // 在一张差分框里找「最宽的那条横向条带」：弹出菜单是实心大块，
        // 而光标拖柄只是窄窄一条；用行覆盖率把两者分开，避免点进两者之间的空隙。
        // 返回 {top, height}（绝对坐标），找不到返回 null。
        public static int[] WidestRowBand(Bitmap a, Bitmap b, int x0, int y0, int w0, int h0, int tol, double rowRatio)
        {
            if (a.Width != b.Width || a.Height != b.Height) return null;
            int w = a.Width, h = a.Height;
            var rect = new Rectangle(0, 0, w, h);
            var da = a.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            var db = b.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                var ba = new byte[da.Stride * h];
                var bb = new byte[db.Stride * h];
                Marshal.Copy(da.Scan0, ba, 0, ba.Length);
                Marshal.Copy(db.Scan0, bb, 0, bb.Length);

                int yEnd0 = Math.Min(h, y0 + h0);
                int yStart0 = Math.Max(0, y0);
                int xStart = Math.Max(0, x0);
                int xEnd = Math.Min(w, x0 + w0);
                int span = Math.Max(1, xEnd - xStart);
                int need = (int)Math.Ceiling(span * rowRatio);

                int bestTop = -1, bestLen = 0, curTop = -1, curLen = 0;
                for (int y = yStart0; y < yEnd0; y++)
                {
                    int row = y * da.Stride;
                    int cnt = 0;
                    for (int x = xStart; x < xEnd; x++)
                    {
                        int i = row + x * 4;
                        int d0 = ba[i] - bb[i]; if (d0 < 0) d0 = -d0;
                        if (d0 > tol) { cnt++; continue; }
                        int d1 = ba[i + 1] - bb[i + 1]; if (d1 < 0) d1 = -d1;
                        if (d1 > tol) { cnt++; continue; }
                        int d2 = ba[i + 2] - bb[i + 2]; if (d2 < 0) d2 = -d2;
                        if (d2 > tol) cnt++;
                    }
                    if (cnt >= need)
                    {
                        if (curTop < 0) { curTop = y; curLen = 0; }
                        curLen++;
                    }
                    else if (curTop >= 0)
                    {
                        if (curLen > bestLen) { bestLen = curLen; bestTop = curTop; }
                        curTop = -1;
                    }
                }
                if (curTop >= 0 && curLen > bestLen) { bestLen = curLen; bestTop = curTop; }
                if (bestTop < 0 || bestLen < 10) return null;
                return new int[] { bestTop, bestLen };
            }
            finally
            {
                a.UnlockBits(da);
                b.UnlockBits(db);
            }
        }
    }
}
'@

[void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')

$dllDir = Join-Path $env:TEMP 'dsh-mi-phone-use'
if (-not (Test-Path $dllDir)) { New-Item -ItemType Directory -Path $dllDir -Force | Out-Null }

# DLL 按源码内容 hash 命名：改过 C# 就自动换新文件，不用再手工 bump 版本号
$sha = [System.Security.Cryptography.SHA256]::Create()
$srcHash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($source))).Replace('-', '').Substring(0, 12).ToLowerInvariant()
$sha.Dispose()
$dll = Join-Path $dllDir "MiPhone-$srcHash.dll"

$loaded = $false
if (Test-Path $dll) {
  try { Add-Type -Path $dll; $loaded = $true } catch { $loaded = $false }
}
if (-not $loaded) {
  try {
    Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Drawing' -OutputAssembly $dll -ErrorAction Stop
    Add-Type -Path $dll
  } catch {
    Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Drawing'
  }
}

# 只留当前 hash 的编译产物，旧的（改过 C# 之后留下的）顺手删掉，避免一直堆积
try {
  Get-ChildItem $dllDir -Filter 'MiPhone-*.dll' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $dll } |
    ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch { } }
} catch { }

[void][MiPhone.Native]::SetProcessDPIAware()

$VT = @{
  WindowTitles = @('跨屏协作', '妙享桌面')
  ParentClass  = 'kMiScreenShareMainWindow'
  ChildClass   = 'kMiChildSharedWindow'
}

# ---------------------------------------------------------------------------
# 基础
# ---------------------------------------------------------------------------
function Get-BitmapStream($bitmap, $format) {
  $ms = New-Object System.IO.MemoryStream
  $bitmap.Save($ms, $format)
  $ms.Position = 0
  return $ms
}

function Resolve-WindowSpec($win) {
  $spec = @{
    Titles      = $VT.WindowTitles
    ParentClass = $VT.ParentClass
    ChildClass  = $VT.ChildClass
  }
  if ($null -ne $win) {
    if ($win.titles) { $spec.Titles = @($win.titles | ForEach-Object { [string]$_ }) }
    if ($win.parentClass) { $spec.ParentClass = [string]$win.parentClass }
    if ($win.childClass) { $spec.ChildClass = [string]$win.childClass }
  }
  return $spec
}

function Resolve-Target($spec) {
  if ($null -eq $spec) { $spec = Resolve-WindowSpec $null }
  $parent = [MiPhone.Native]::FindParent($spec.Titles, $spec.ParentClass)
  if ($parent -eq [IntPtr]::Zero) {
    $hint = ($spec.Titles -join ' / ')
    throw "window not found: $hint（请先打开小米互联的手机画面）"
  }
  $child = [MiPhone.Native]::FindChild($parent, $spec.ChildClass)
  if ($child -eq [IntPtr]::Zero) {
    $child = [MiPhone.Native]::FindChild($parent, '')
    if ($child -eq [IntPtr]::Zero) { throw 'content child not found: 父窗口下没有可见子窗口（手机画面可能未投出来）' }
  }
  return @{ Parent = $parent; Child = $child }
}

function Get-ClientInfo([IntPtr]$child) {
  $cr = New-Object 'MiPhone.Native+RECT'
  [void][MiPhone.Native]::GetClientRect($child, [ref]$cr)
  $pt = New-Object 'MiPhone.Native+POINT'
  $pt.X = 0; $pt.Y = 0
  [void][MiPhone.Native]::ClientToScreen($child, [ref]$pt)
  return @{
    X = $pt.X
    Y = $pt.Y
    W = ($cr.Right - $cr.Left)
    H = ($cr.Bottom - $cr.Top)
  }
}

function Get-WindowInfo($target) {
  $parent = $target.Parent
  $child = $target.Child
  $client = Get-ClientInfo $child
  return @{
    ok     = $true
    parent = @{
      hwnd  = [int64]$parent
      cls   = [MiPhone.Native]::ClassOf($parent)
      title = [MiPhone.Native]::TitleOf($parent)
      iconic = [MiPhone.Native]::IsIconic($parent)
      visible = [MiPhone.Native]::IsWindowVisible($parent)
    }
    screen = @{
      x = $client.X; y = $client.Y; w = $client.W; h = $client.H
    }
    child  = @{
      hwnd = [int64]$child
      cls  = [MiPhone.Native]::ClassOf($child)
    }
  }
}

# ---------------------------------------------------------------------------
# 截图
# ---------------------------------------------------------------------------
function Invoke-Capture($target, [string]$out, [string]$prev, $region, [int]$maxWidth) {
  $parent = $target.Parent
  $child = $target.Child

  if ([MiPhone.Native]::IsIconic($parent)) { throw 'window-minimized: 窗口已最小化，需要先 restore' }
  if (-not [MiPhone.Native]::IsWindowVisible($parent)) { throw 'window-hidden: 窗口不可见' }

  $wr = New-Object 'MiPhone.Native+RECT'
  [void][MiPhone.Native]::GetWindowRect($parent, [ref]$wr)
  $ww = $wr.Right - $wr.Left
  $wh = $wr.Bottom - $wr.Top
  if ($ww -le 0 -or $wh -le 0) { throw "invalid window rect: ${ww}x${wh}" }

  $bmp = New-Object System.Drawing.Bitmap($ww, $wh)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  $pwOk = $false
  try { $pwOk = [MiPhone.Native]::PrintWindow($parent, $hdc, 2) }
  finally { $g.ReleaseHdc($hdc); $g.Dispose() }

  if (-not $pwOk) { $bmp.Dispose(); throw 'PrintWindow failed' }

  $client = Get-ClientInfo $child
  $cx = $client.X - $wr.Left
  $cy = $client.Y - $wr.Top
  if ($cx -lt 0) { $cx = 0 }
  if ($cy -lt 0) { $cy = 0 }
  if ($cx + $client.W -gt $ww) { $client.W = $ww - $cx }
  if ($cy + $client.H -gt $wh) { $client.H = $wh - $cy }
  if ($client.W -le 0 -or $client.H -le 0) { $bmp.Dispose(); throw 'invalid client rect inside window' }

  $crop = $bmp.Clone((New-Object System.Drawing.Rectangle($cx, $cy, $client.W, $client.H)), $bmp.PixelFormat)
  $bmp.Dispose()

  # 百分比区域裁剪
  if ($null -ne $region -and $region.Count -eq 4) {
    $rx = [int][math]::Floor($crop.Width * $region[0] / 100.0)
    $ry = [int][math]::Floor($crop.Height * $region[1] / 100.0)
    $rw = [int][math]::Ceiling($crop.Width * $region[2] / 100.0)
    $rh = [int][math]::Ceiling($crop.Height * $region[3] / 100.0)
    if ($rx -lt 0) { $rx = 0 }
    if ($ry -lt 0) { $ry = 0 }
    if ($rx + $rw -gt $crop.Width) { $rw = $crop.Width - $rx }
    if ($ry + $rh -gt $crop.Height) { $rh = $crop.Height - $ry }
    if ($rw -gt 0 -and $rh -gt 0 -and ($rw -ne $crop.Width -or $rh -ne $crop.Height)) {
      $sub = $crop.Clone((New-Object System.Drawing.Rectangle($rx, $ry, $rw, $rh)), $crop.PixelFormat)
      $crop.Dispose()
      $crop = $sub
    }
  }

  # 等比缩小（只影响图片，不影响坐标百分比）
  if ($maxWidth -gt 0 -and $crop.Width -gt $maxWidth) {
    $ratio = $maxWidth / $crop.Width
    $nw = [int][math]::Round($crop.Width * $ratio)
    $nh = [int][math]::Round($crop.Height * $ratio)
    $small = New-Object System.Drawing.Bitmap($nw, $nh)
    $sg = [System.Drawing.Graphics]::FromImage($small)
    $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $sg.DrawImage($crop, 0, 0, $nw, $nh)
    $sg.Dispose()
    $crop.Dispose()
    $crop = $small
  }

  $hash = [MiPhone.Img]::Hash($crop)

  $result = @{ w = $crop.Width; h = $crop.Height; hash = $hash; changed = $true; box = $null }

  if ($prev -and (Test-Path $prev) -and (-not $region)) {
    try {
      $prevBmp = [System.Drawing.Bitmap]::FromFile($prev)
      $box = [MiPhone.Img]::DiffBox($prevBmp, $crop, 16, 12, 0.25)
      $prevBmp.Dispose()
      if ($null -eq $box) {
        $result.changed = $false
        $result.blocks = 0
      } else {
        $result.box = @($box[0], $box[1], $box[2], $box[3])
        $result.blocks = $box[4]
        $total = [math]::Max(1, [math]::Ceiling($crop.Width / 16) * [math]::Ceiling($crop.Height / 16))
        $result.ratio = [math]::Round([double]$box[4] / $total, 3)
        # 大面积变化时按整屏报告，裁图意义不大
        if ($box[4] -ge $total * 0.75) { $result.box = @(0, 0, $crop.Width, $crop.Height) }
      }
    } catch { $result.note = 'diff-failed' }
  }

  if ($out) {
    $dir = Split-Path -Parent $out
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $crop.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $result.path = $out

    # 变化区域够小就额外产一张裁图：调一次拿两样，省 token
    if ($result.box -and -not $region) {
      $bw = [int]$result.box[2]
      $bh = [int]$result.box[3]
      $areaRatio = ($bw * $bh) / [double]($crop.Width * $crop.Height)
      if ($areaRatio -lt 0.45 -and $bw -gt 8 -and $bh -gt 8) {
        $pad = 12
        $bx = [math]::Max(0, [int]$result.box[0] - $pad)
        $by = [math]::Max(0, [int]$result.box[1] - $pad)
        $bwid = [math]::Min($crop.Width - $bx, $bw + 2 * $pad)
        $bhei = [math]::Min($crop.Height - $by, $bh + 2 * $pad)
        $cropPath = ($out -replace '\.png$', '') + '.crop.png'
        $sub = $crop.Clone((New-Object System.Drawing.Rectangle($bx, $by, $bwid, $bhei)), $crop.PixelFormat)
        $sub.Save($cropPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $sub.Dispose()
        $result.cropPath = $cropPath
        $result.cropBox = @($bx, $by, $bwid, $bhei)
      }
    }
  }
  $crop.Dispose()
  return $result
}

# 在两张同尺寸截图里比一块百分比区域，返回该区域是否真的变了（点击验证用）
function Test-RegionChanged([string]$a, [string]$b, $rectPct, $client) {
  if (-not $a -or -not $b -or -not (Test-Path $a) -or -not (Test-Path $b)) { return $null }
  $ba = [System.Drawing.Bitmap]::FromFile($a)
  $bb = [System.Drawing.Bitmap]::FromFile($b)
  try {
    $rx = [int][math]::Floor($client.W * $rectPct[0] / 100.0)
    $ry = [int][math]::Floor($client.H * $rectPct[1] / 100.0)
    $rw = [int][math]::Ceiling($client.W * $rectPct[2] / 100.0)
    $rh = [int][math]::Ceiling($client.H * $rectPct[3] / 100.0)
    if ($rx -lt 0) { $rx = 0 }
    if ($ry -lt 0) { $ry = 0 }
    if ($rx + $rw -gt $ba.Width) { $rw = $ba.Width - $rx }
    if ($ry + $rh -gt $ba.Height) { $rh = $ba.Height - $ry }
    if ($rw -le 2 -or $rh -le 2) { return $false }
    $rect = New-Object System.Drawing.Rectangle($rx, $ry, $rw, $rh)
    $ca = $ba.Clone($rect, $ba.PixelFormat)
    $cb = $bb.Clone($rect, $bb.PixelFormat)
    try { $box = [MiPhone.Img]::DiffBox($ca, $cb, 8, 12, 0.06) }
    finally { $ca.Dispose(); $cb.Dispose() }
    return ($null -ne $box)
  } finally { $ba.Dispose(); $bb.Dispose() }
}

# 两张截图之间「新出现的浮层」框（百分比以外的像素坐标）；没有明显浮层返回 $null。
# 粘贴菜单的位置随输入框走（底部输入框菜单弹在上方、顶部搜索框弹在下方），不能写死坐标。
function Get-PopupBox([string]$a, [string]$b, $client) {
  if (-not (Test-Path $a) -or -not (Test-Path $b)) { return $null }
  $ba = [System.Drawing.Bitmap]::FromFile($a)
  $bb = [System.Drawing.Bitmap]::FromFile($b)
  try {
    if ($ba.Width -ne $bb.Width -or $ba.Height -ne $bb.Height) { return $null }
    $box = [MiPhone.Img]::DiffBox($ba, $bb, 8, 12, 0.06)
    if ($null -eq $box) { return $null }
    $w = [int]$box[2]; $h = [int]$box[3]
    # 浮层不会占满整屏，也不会细成一条：超出这个范围的当噪声丢掉
    if ($w -lt 40 -or $h -lt 30) { return $null }
    if ($w -gt $ba.Width * 0.95 -or $h -gt $ba.Height * 0.5) { return $null }
    # 差分框可能把光标拖柄和菜单框在一起：取其中最宽的那条横向条带当菜单本体
    $band = [MiPhone.Img]::WidestRowBand($ba, $bb, [int]$box[0], [int]$box[1], $w, $h, 12, 0.25)
    if ($null -ne $band) {
      return @{ x = [int]$box[0]; y = [int]$band[0]; w = $w; h = [int]$band[1]; banded = $true }
    }
    return @{ x = [int]$box[0]; y = [int]$box[1]; w = $w; h = $h; banded = $false }
  } finally { $ba.Dispose(); $bb.Dispose() }
}

# ---------------------------------------------------------------------------
# 输入（全部后台）
# ---------------------------------------------------------------------------
function Parse-Pct($value, [double]$size) {
  return [int][math]::Round($size * ([double]$value) / 100.0)
}

function ConvertTo-Point($pct, $client) {
  $parts = ([string]$pct) -split ','
  if ($parts.Count -lt 2) { throw "坐标格式错误，应为 x,y 百分比：$pct" }
  return @(
    (Parse-Pct $parts[0].Trim() $client.W),
    (Parse-Pct $parts[1].Trim() $client.H)
  )
}

function New-LParam([int]$x, [int]$y) {
  return [IntPtr](($x -band 0xFFFF) -bor (($y -band 0xFFFF) -shl 16))
}

function Invoke-Tap($target, [int]$x, [int]$y) {
  $child = $target.Child
  $lp = New-LParam $x $y
  [void][MiPhone.Native]::SendMessage($child, 0x0200, [IntPtr]::Zero, $lp)   # WM_MOUSEMOVE
  Start-Sleep -Milliseconds 20
  [void][MiPhone.Native]::SendMessage($child, 0x0201, [IntPtr]1, $lp)        # WM_LBUTTONDOWN
  Start-Sleep -Milliseconds 45
  [void][MiPhone.Native]::SendMessage($child, 0x0202, [IntPtr]::Zero, $lp)   # WM_LBUTTONUP
}

function Invoke-Swipe($target, [int]$x1, [int]$y1, [int]$x2, [int]$y2, [int]$ms) {
  $child = $target.Child
  if ($ms -lt 60) { $ms = 60 }
  $steps = [int][math]::Max(6, [math]::Round($ms / 16.0))
  $lp = New-LParam $x1 $y1
  [void][MiPhone.Native]::SendMessage($child, 0x0200, [IntPtr]::Zero, $lp)
  [void][MiPhone.Native]::SendMessage($child, 0x0201, [IntPtr]1, $lp)
  $delay = [int][math]::Max(4, [math]::Floor($ms / $steps))
  for ($i = 1; $i -le $steps; $i++) {
    $t = $i / [double]$steps
    $mx = [int][math]::Round($x1 + ($x2 - $x1) * $t)
    $my = [int][math]::Round($y1 + ($y2 - $y1) * $t)
    [void][MiPhone.Native]::SendMessage($child, 0x0200, [IntPtr]1, (New-LParam $mx $my))
    Start-Sleep -Milliseconds $delay
  }
  [void][MiPhone.Native]::SendMessage($child, 0x0202, [IntPtr]::Zero, (New-LParam $x2 $y2))
}

# 长按：按住 ms 毫秒（手机端用于唤出上下文菜单，例如「粘贴」）
function Invoke-LongPress($target, [int]$x, [int]$y, [int]$ms) {
  $child = $target.Child
  if ($ms -lt 200) { $ms = 700 }
  $lp = New-LParam $x $y
  [void][MiPhone.Native]::SendMessage($child, 0x0200, [IntPtr]::Zero, $lp)
  Start-Sleep -Milliseconds 30
  [void][MiPhone.Native]::SendMessage($child, 0x0201, [IntPtr]1, $lp)
  # 远端投屏控件可能依赖 MOVE/心跳来维持手势捕获；只 Sleep 后 UP 会被当成普通点击。
  $steps = [int][math]::Max(1, [math]::Floor($ms / 80.0))
  for ($i = 1; $i -le $steps; $i++) {
    Start-Sleep -Milliseconds ([int][math]::Floor($ms / $steps))
    [void][MiPhone.Native]::SendMessage($child, 0x0200, [IntPtr]1, $lp)
  }
  [void][MiPhone.Native]::SendMessage($child, 0x0202, [IntPtr]::Zero, $lp)
}

function Send-KeyMessage([IntPtr]$child, [int]$vk, [bool]$withChar) {  $scan = [MiPhone.Native]::MapVirtualKey([uint32]$vk, 0) -band 0xFF
  $down = [IntPtr](1 -bor ($scan -shl 16))
  $up = [IntPtr]((1 -bor ($scan -shl 16)) -bor 0xC0000000)
  [void][MiPhone.Native]::PostMessage($child, 0x0100, [IntPtr]$vk, $down)
  if ($withChar) { [void][MiPhone.Native]::PostMessage($child, 0x0102, [IntPtr]$vk, $down) }
  [void][MiPhone.Native]::PostMessage($child, 0x0101, [IntPtr]$vk, $up)
}

function Send-AsciiChar([IntPtr]$child, [char]$ch) {
  $vk = [MiPhone.Native]::VkKeyScan([char]$ch)
  if ($vk -eq -1) {
    [void][MiPhone.Native]::PostMessage($child, 0x0102, [IntPtr][int][char]$ch, [IntPtr]::Zero)
    return
  }
  $v = [int]$vk
  $virtualKey = $v -band 0xFF
  $shift = (($v -shr 8) -band 0x01) -eq 1
  $scan = [MiPhone.Native]::MapVirtualKey([uint32]$virtualKey, 0) -band 0xFF
  $down = [IntPtr](1 -bor ($scan -shl 16))
  $up = [IntPtr]((1 -bor ($scan -shl 16)) -bor 0xC0000000)
  $shiftDown = [IntPtr](1 -bor ((0x2A) -shl 16))
  $shiftUp = [IntPtr]((1 -bor ((0x2A) -shl 16)) -bor 0xC0000000)
  if ($shift) { [void][MiPhone.Native]::PostMessage($child, 0x0100, [IntPtr]0x10, $shiftDown) }
  [void][MiPhone.Native]::PostMessage($child, 0x0100, [IntPtr]$virtualKey, $down)
  [void][MiPhone.Native]::PostMessage($child, 0x0102, [IntPtr][int][char]$ch, $down)
  [void][MiPhone.Native]::PostMessage($child, 0x0101, [IntPtr]$virtualKey, $up)
  if ($shift) { [void][MiPhone.Native]::PostMessage($child, 0x0101, [IntPtr]0x10, $shiftUp) }
}

function Send-Combo([IntPtr]$child, [int[]]$vks, [int]$gapMs) {
  if ($gapMs -lt 5) { $gapMs = 15 }
  foreach ($vk in $vks) {
    $scan = [MiPhone.Native]::MapVirtualKey([uint32]$vk, 0) -band 0xFF
    [void][MiPhone.Native]::PostMessage($child, 0x0100, [IntPtr]$vk, [IntPtr](1 -bor ($scan -shl 16)))
    Start-Sleep -Milliseconds $gapMs
  }
  for ($i = $vks.Count - 1; $i -ge 0; $i--) {
    $vk = $vks[$i]
    $scan = [MiPhone.Native]::MapVirtualKey([uint32]$vk, 0) -band 0xFF
    [void][MiPhone.Native]::PostMessage($child, 0x0101, [IntPtr]$vk, [IntPtr]((1 -bor ($scan -shl 16)) -bor 0xC0000000))
    Start-Sleep -Milliseconds $gapMs
  }
}

# 长按唤出菜单 → 点「粘贴」。全程纯鼠标消息，不碰全局键盘状态，不与用户冲突。
# 菜单坐标不再写死：长按前后各截一张，用差分找到新弹出的浮层，点它中心。
# 传了 menu 就仍按给定坐标点（老行为，兼容特殊 App）。
function Invoke-PasteAt($target, [string]$text, [string]$at, [string]$menu, [int]$holdMs) {
  $client = Get-ClientInfo $target.Child
  $ptA = ConvertTo-Point $at $client
  $ptM = $null
  if ($menu) { $ptM = ConvertTo-Point $menu $client }
  if ($holdMs -le 0) { $holdMs = 800 }
  $shotDir = Join-Path $env:TEMP 'dsh-mi-phone-use'
  if (-not (Test-Path $shotDir)) { New-Item -ItemType Directory -Path $shotDir -Force | Out-Null }
  $preShot = Join-Path $shotDir 'paste-pre.png'
  $postShot = Join-Path $shotDir 'paste-post.png'

  $prevText = $null
  $hadPrev = $false
  try {
    $prevText = Get-Clipboard -Raw -ErrorAction Stop
    $hadPrev = $true
  } catch { $hadPrev = $false }

  Set-Clipboard -Value $text -ErrorAction Stop
  Start-Sleep -Milliseconds 1500         # 等互联把剪贴板同步到手机（太快会只有「AI写作/常用语」，没有「粘贴」）

  $menuHit = 'given'
  $box = $null
  $probeLog = New-Object System.Collections.ArrayList
  $inserted = $null
  $afterShot = Join-Path $shotDir 'paste-after.png'

  # 输入框那条横带（校验「字有没有真的进去」用）
  $rh = [int][math]::Ceiling($client.H * 0.10)
  $ry = [int][math]::Max(0, [math]::Min($client.H - $rh, $ptA[1] - [int]($rh / 2)))
  $fieldRect = @(2, [int]($ry * 100.0 / $client.H), 96, [int]($rh * 100.0 / $client.H))

  if (-not $ptM) {
    try { Invoke-Capture $target $preShot $null $null 0 | Out-Null } catch { }
    Invoke-LongPress $target $ptA[0] $ptA[1] $holdMs
    # 菜单是带动画弹出来的：多等几轮再抓；抓到的浮层太小就继续等（最多 3 轮）
    for ($r = 1; $r -le 3; $r++) {
      Start-Sleep -Milliseconds 700
      try {
        Invoke-Capture $target $postShot $null $null 0 | Out-Null
        $probe = Get-PopupBox $preShot $postShot $client
        if ($probe -and $probe.w -ge 100 -and $probe.h -ge 40) { $box = $probe; break }
        if ($probe -and -not $box) { $box = $probe }
      } catch { }
    }

    if ($box) {
      $menuHit = 'auto'
      # 不同 App / 不同页面的菜单项数、顺序、宽度都不一样，「粘贴」不一定在正中。
      # 没办法读字（投屏中文 OCR 不可用），所以改成「按比例试 → 立刻校验 → 不对且菜单还在就试下一个」。
      $cands = @(0.5, 0.36, 0.64, 0.22, 0.78)
      $boxRect = @(
        [int]($box.x * 100.0 / $client.W),
        [int]($box.y * 100.0 / $client.H),
        [int]($box.w * 100.0 / $client.W),
        [int]($box.h * 100.0 / $client.H)
      )
      foreach ($f in $cands) {
        $cx = [int]($box.x + $box.w * $f)
        $cy = [int]($box.y + $box.h / 2)
        Invoke-Tap $target $cx $cy
        Start-Sleep -Milliseconds 800
        try { Invoke-Capture $target $afterShot $null $null 0 | Out-Null } catch { }
        $inserted = Test-RegionChanged $preShot $afterShot $fieldRect $client
        [void]$probeLog.Add(@{ at = "$f"; inserted = $inserted })
        $ptM = @($cx, $cy)
        if ($inserted -eq $true) { break }
        # 没粘进去：菜单还在就继续试下一项；菜单没了说明点到别的功能，按一次返回撤掉后停手
        $menuStill = Test-RegionChanged $postShot $afterShot $boxRect $client
        if ($menuStill -ne $true) {
          try { Invoke-Key $target 'esc' 1 | Out-Null } catch { }
          Start-Sleep -Milliseconds 600
          break
        }
      }
    } else {
      # 完全没抓到浮层：按输入框位置退化成「上方还是下方」的经验值，点完同样校验
      $menuHit = 'guess'
      $guessY = if ($ptA[1] -gt ($client.H / 2)) { $ptA[1] - [int]($client.H * 0.10) } else { $ptA[1] + [int]($client.H * 0.10) }
      $ptM = @($ptA[0], $guessY)
      Invoke-Tap $target $ptM[0] $ptM[1]
      Start-Sleep -Milliseconds 800
      try { Invoke-Capture $target $afterShot $null $null 0 | Out-Null } catch { }
      $inserted = Test-RegionChanged $preShot $afterShot $fieldRect $client
    }
  } else {
    Invoke-LongPress $target $ptA[0] $ptA[1] $holdMs
    Start-Sleep -Milliseconds 700
    Invoke-Tap $target $ptM[0] $ptM[1]
    Start-Sleep -Milliseconds 800
    try {
      Invoke-Capture $target $afterShot $null $null 0 | Out-Null
      $inserted = Test-RegionChanged $preShot $afterShot $fieldRect $client
    } catch { $inserted = $null }
  }

  $restored = 'none'
  if ($hadPrev) {
    try { Set-Clipboard -Value $prevText -ErrorAction Stop; $restored = $true }
    catch { $restored = $false }
  }
  $boxInfo = $null
  if ($box) { $boxInfo = @{ x = [int]$box.x; y = [int]$box.y; w = [int]$box.w; h = [int]$box.h; banded = [bool]$box.banded } }
  return @{ mode = 'paste-menu'; n = $text.Length; clip = $restored; at = $at; menu = $menuHit; menuAt = "$([int]($ptM[0] * 100.0 / $client.W)),$([int]($ptM[1] * 100.0 / $client.H))"; inserted = $inserted; box = $boxInfo; probes = @($probeLog) }
}

# 通过共用剪贴板把文本送进手机：写剪贴板 -> 等互联同步 -> 触发粘贴 -> 还原剪贴板
# 注意：ctrlstate 会注入全局 Ctrl 按键状态，可能与用户的物理键盘冲突，
#       **默认不使用**；只有用户明确同意时才走这条。
function Send-UnicodeInput([string]$text) {
  if ([string]::IsNullOrEmpty($text)) { return @{ sent = 0; mode = 'unicode-sendinput' } }
  $inputs = New-Object 'MiPhone.Native+INPUT[]' ($text.Length * 2)
  $i = 0
  foreach ($u in $text.ToCharArray()) {
    $inputs[$i].type = [MiPhone.Native]::INPUT_KEYBOARD
    $inputs[$i].U.ki = New-Object 'MiPhone.Native+KEYBDINPUT'
    $inputs[$i].U.ki.wScan = [uint16][int]$u
    $inputs[$i].U.ki.dwFlags = [MiPhone.Native]::KEYEVENTF_UNICODE
    $i++
    $inputs[$i].type = [MiPhone.Native]::INPUT_KEYBOARD
    $inputs[$i].U.ki = New-Object 'MiPhone.Native+KEYBDINPUT'
    $inputs[$i].U.ki.wScan = [uint16][int]$u
    $inputs[$i].U.ki.dwFlags = [MiPhone.Native]::KEYEVENTF_UNICODE -bor [MiPhone.Native]::KEYEVENTF_KEYUP
    $i++
  }
  $sent = [MiPhone.Native]::SendInput([uint32]$inputs.Length, $inputs, [Runtime.InteropServices.Marshal]::SizeOf([type]'MiPhone.Native+INPUT'))
  if ($sent -ne $inputs.Length) { throw "SendInput Unicode failed: $sent/$($inputs.Length)" }
  return @{ mode = 'unicode-sendinput'; sent = $text.Length }
}

function Invoke-Paste($target, [string]$text, [string]$method) {
  $child = $target.Child
  $prevText = $null
  $hadPrev = $false
  try {
    $prevText = Get-Clipboard -Raw -ErrorAction Stop
    $hadPrev = $true
  } catch { $hadPrev = $false }

  Set-Clipboard -Value $text -ErrorAction Stop
  # 给互联同步剪贴板的时间：全局按键路径可以短，WM_PASTE 需要在同步之后才有效
  if ($method -eq 'wmpaste') { Start-Sleep -Milliseconds 900 } else { Start-Sleep -Milliseconds 400 }

  if ($method -eq 'wmpaste') {
    [void][MiPhone.Native]::SendMessage($child, 0x0302, [IntPtr]::Zero, [IntPtr]::Zero)
  } elseif ($method -eq 'shiftinsert') {
    Send-Combo $child @(0x10, 0x2D) 20
  } elseif ($method -eq 'ctrlstate') {
    # 投屏控件转发按键时会读真实修饰键状态（GetKeyState），
    # 所以必须把 Ctrl 真的按下去（只注入按键，不动鼠标、不切焦点）。
    [MiPhone.Native]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)   # Ctrl down
    try {
      Start-Sleep -Milliseconds 30
      Send-Combo $child @(0x56) 15                               # 只发 V
      Start-Sleep -Milliseconds 60
    } finally {
      [MiPhone.Native]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero) # Ctrl up
    }
  } else {
    Send-Combo $child @(0x11, 0x56) 20    # Ctrl+V
  }
  if ($method -eq 'wmpaste') { Start-Sleep -Milliseconds 700 } else { Start-Sleep -Milliseconds 350 }

  $restored = 'none'
  if ($hadPrev) {
    try { Set-Clipboard -Value $prevText -ErrorAction Stop; $restored = $true }
    catch { $restored = $false }
  }
  return @{ mode = "paste-$method"; n = $text.Length; clip = $restored }
}

function Invoke-Text($target, [string]$text, [string]$at, [string]$menu) {
  $child = $target.Child
  if ([string]::IsNullOrEmpty($text)) { return @{ mode = 'noop'; n = 0; clip = 'untouched' } }

  $hasWide = $false
  foreach ($c in $text.ToCharArray()) { if ([int]$c -gt 0x7F) { $hasWide = $true; break } }

  if ($hasWide) {
    if (-not $at) {
      throw 'text 含中文/符号时必须提供输入框位置 at（百分比，如 "40,96"）'
    }
    if (-not $menu) {
      # 菜单项的个数、顺序、位置每个 App 都不一样（见过「AI写作/粘贴/常用语」，也见过「粘贴/常用语」）。
      # 不猜、不逐个试：只把菜单弹出来并回一张菜单截图，等人（或模型）看一眼「粘贴」在哪，再带 menu 点。
      return (Invoke-OpenMenu $target $at 800)
    }
    return (Invoke-PasteAt $target $text $at $menu 800)
  }

  foreach ($c in $text.ToCharArray()) {
    Send-AsciiChar $child $c
    Start-Sleep -Milliseconds 12
  }
  return @{ mode = 'keys'; n = $text.Length; clip = 'untouched' }
}

# 只弹菜单，不点任何东西：写剪贴板 -> 等同步 -> 长按 -> 找出菜单框 -> 把它裁出来存成图。
# 调用方看这张图确认「粘贴」在哪，再用 {"tap":"x,y"} 点；点完用 {"restoreclip":true} 还原剪贴板。
function Invoke-OpenMenu($target, [string]$at, [int]$holdMs, [string]$text) {
  $client = Get-ClientInfo $target.Child
  $ptA = ConvertTo-Point $at $client
  if ($holdMs -le 0) { $holdMs = 800 }
  $shotDir = Join-Path $env:TEMP 'dsh-mi-phone-use'
  if (-not (Test-Path $shotDir)) { New-Item -ItemType Directory -Path $shotDir -Force | Out-Null }
  $bakPath = Join-Path $shotDir 'clip-backup.txt'

  # 先备份原剪贴板（只在还没有备份时存，避免把中间态当原件），再写入要粘贴的文字
  if (-not (Test-Path $bakPath)) {
    try {
      $prev = Get-Clipboard -Raw -ErrorAction Stop
      [IO.File]::WriteAllText($bakPath, $prev, [System.Text.UTF8Encoding]::new($false))
    } catch { }
  }
  if (-not [string]::IsNullOrEmpty($text)) {
    Set-Clipboard -Value $text -ErrorAction Stop
    Start-Sleep -Milliseconds 1500     # 等互联把剪贴板同步到手机，否则菜单里没有「粘贴」
  }

  $preShot = Join-Path $shotDir 'menu-pre.png'
  $postShot = Join-Path $shotDir 'menu-post.png'
  try { Invoke-Capture $target $preShot $null $null 0 | Out-Null } catch { }
  Invoke-LongPress $target $ptA[0] $ptA[1] $holdMs

  $box = $null
  for ($r = 1; $r -le 3; $r++) {
    Start-Sleep -Milliseconds 700
    try {
      Invoke-Capture $target $postShot $null $null 0 | Out-Null
      $probe = Get-PopupBox $preShot $postShot $client
      if ($probe -and $probe.w -ge 100 -and $probe.h -ge 40) { $box = $probe; break }
      if ($probe -and -not $box) { $box = $probe }
    } catch { }
  }

  $cropPath = $null
  $boxInfo = $null
  if ($box) {
    # 差分只覆盖「变了字的地方」，白底菜单的边框常常看不见，所以四周留白再裁，
    # 保证整条菜单（含最右一项）都进图，便于判断「粘贴」到底在第几个。
    $padX = 48; $padY = 34
    $cx = [int][math]::Max(0, $box.x - $padX)
    $cy = [int][math]::Max(0, $box.y - $padY)
    $cw = [int][math]::Min($client.W - $cx, $box.w + 2 * $padX)
    $ch = [int][math]::Min($client.H - $cy, $box.h + 2 * $padY)
    $scale = 2
    try {
      $src = [System.Drawing.Bitmap]::FromFile($postShot)
      $rect = New-Object System.Drawing.Rectangle($cx, $cy, $cw, $ch)
      $sub = $src.Clone($rect, $src.PixelFormat)
      $big = New-Object System.Drawing.Bitmap(($cw * $scale), ($ch * $scale))
      $g = [System.Drawing.Graphics]::FromImage($big)
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.DrawImage($sub, 0, 0, $big.Width, $big.Height)
      $g.Dispose(); $sub.Dispose(); $src.Dispose()
      $cropPath = Join-Path $shotDir 'menu.png'
      $big.Save($cropPath, [System.Drawing.Imaging.ImageFormat]::Png)
      $big.Dispose()
    } catch { $cropPath = $null }
    # 给出裁剪图与画面区的换算关系：图上像素 / scale + 原点 = 画面区像素
    $boxInfo = @{
      x = $cx; y = $cy; w = $cw; h = $ch; scale = $scale
      pct = @(
        [math]::Round($cx * 100.0 / $client.W, 2), [math]::Round($cy * 100.0 / $client.H, 2),
        [math]::Round($cw * 100.0 / $client.W, 2), [math]::Round($ch * 100.0 / $client.H, 2)
      )
      screen = @{ w = $client.W; h = $client.H }
    }
  }

  return @{
    mode = 'menu-open'; opened = [bool]$box; box = $boxInfo; crop = $cropPath
    hint = '看菜单图找「粘贴」：图上坐标 / scale + box.x/y 得到画面区像素，再除以 box.screen 换成百分比，然后 {"tap":"x,y"}；最后 {"clip":"@restore"} 还原剪贴板'
  }
}

function Invoke-Key($target, [string]$name, [int]$n) {
  $child = $target.Child
  $map = @{ backspace = 0x08; enter = 0x0D; esc = 0x1B; tab = 0x09; delete = 0x2E; space = 0x20 }
  $key = $name.ToLowerInvariant()
  if (-not $map.ContainsKey($key)) { throw "unknown key: $name" }
  if ($n -lt 1) { $n = 1 }
  if ($n -gt 200) { $n = 200 }
  for ($i = 0; $i -lt $n; $i++) {
    Send-KeyMessage $child $map[$key] ($key -eq 'backspace' -or $key -eq 'enter' -or $key -eq 'space')
    Start-Sleep -Milliseconds 30
  }
  return @{ key = $key; n = $n }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
$result = $null
try {
  $raw = [System.IO.File]::ReadAllText($RequestFile, [System.Text.Encoding]::UTF8)
  $req = $raw | ConvertFrom-Json
  $action = [string]$req.action

  $target = Resolve-Target (Resolve-WindowSpec $req.win)

  switch ($action) {
    'info' { $result = Get-WindowInfo $target }
    'restore' {
      $parent = $target.Parent
      $wasIconic = [MiPhone.Native]::IsIconic($parent)
      if ($wasIconic) {
        [void][MiPhone.Native]::ShowWindow($parent, 9)   # SW_RESTORE
        Start-Sleep -Milliseconds 300
      }
      $info = Get-WindowInfo $target
      $info.restored = $wasIconic
      $result = $info
    }
    'capture' {
      $out = [string]$req.out
      $prevPath = [string]$req.prev
      $region = $null
      if ($null -ne $req.region) { $region = @($req.region) }
      $maxWidth = 0
      if ($null -ne $req.maxWidth) { $maxWidth = [int]$req.maxWidth }
      $img = Invoke-Capture $target $out $prevPath $region $maxWidth
      $result = Get-WindowInfo $target
      $result.img = $img
    }
    'tap' {
      $client = Get-ClientInfo $target.Child
      $px = [int][math]::Round($client.W * ([double]$req.x) / 100.0)
      $py = [int][math]::Round($client.H * ([double]$req.y) / 100.0)
      Invoke-Tap $target $px $py
      $result = Get-WindowInfo $target
      $result.did = @{ action = 'tap'; px = $px; py = $py; pct = @([double]$req.x, [double]$req.y) }
    }
    'swipe' {
      $client = Get-ClientInfo $target.Child
      $fx = [int][math]::Round($client.W * ([double]$req.from[0]) / 100.0)
      $fy = [int][math]::Round($client.H * ([double]$req.from[1]) / 100.0)
      $tx = [int][math]::Round($client.W * ([double]$req.to[0]) / 100.0)
      $ty = [int][math]::Round($client.H * ([double]$req.to[1]) / 100.0)
      $ms = 300
      if ($null -ne $req.ms) { $ms = [int]$req.ms }
      Invoke-Swipe $target $fx $fy $tx $ty $ms
      $result = Get-WindowInfo $target
      $result.did = @{ action = 'swipe'; from = @($fx, $fy); to = @($tx, $ty); ms = $ms }
    }
    'text' {
      $r = Invoke-Text $target ([string]$req.value) ([string]$req.at) ([string]$req.menu)
      $result = Get-WindowInfo $target
      $result.did = $r
    }
    'paste' {
      $method = 'ctrlv'
      if ($null -ne $req.method -and [string]$req.method) { $method = [string]$req.method }
      $r = Invoke-Paste $target ([string]$req.value) $method
      $result = Get-WindowInfo $target
      $result.did = $r
    }
    'unicode' {
      $r = Send-UnicodeInput ([string]$req.value)
      $result = Get-WindowInfo $target
      $result.did = $r
    }
    'longpress' {
      $client = Get-ClientInfo $target.Child
      $px = [int][math]::Round($client.W * ([double]$req.x) / 100.0)
      $py = [int][math]::Round($client.H * ([double]$req.y) / 100.0)
      $ms = 700
      if ($null -ne $req.ms) { $ms = [int]$req.ms }
      Invoke-LongPress $target $px $py $ms
      $result = Get-WindowInfo $target
      $result.did = @{ action = 'longpress'; px = $px; py = $py; ms = $ms }
    }
    'clip' {
      # 只操作本机剪贴板（互联会同步到手机），不触发任何手机动作
      if ($null -ne $req.value) {
        Set-Clipboard -Value ([string]$req.value) -ErrorAction Stop
        $result = @{ ok = $true; clip = 'set'; n = ([string]$req.value).Length }
      } else {
        $text = $null
        try { $text = Get-Clipboard -Raw -ErrorAction Stop } catch { $text = '' }
        $result = @{ ok = $true; clip = 'read'; n = $text.Length; head = $text.Substring(0, [math]::Min(40, $text.Length)) }
      }
    }
    'openmenu' {
      $client = Get-ClientInfo $target.Child
      $hold = 800
      if ($null -ne $req.ms) { $hold = [int]$req.ms }
      $r = Invoke-OpenMenu $target ([string]$req.at) $hold
      $result = Get-WindowInfo $target
      $result.did = $r
    }
    'restoreclip' {
      $dir = Join-Path $env:TEMP 'dsh-mi-phone-use'
      $bak = Join-Path $dir 'clip-backup.txt'
      if (Test-Path $bak) {
        $prev = [IO.File]::ReadAllText($bak, [System.Text.UTF8Encoding]::new($false))
        Set-Clipboard -Value $prev -ErrorAction Stop
        Remove-Item $bak -Force -ErrorAction SilentlyContinue
        $result = @{ ok = $true; clip = 'restored'; n = $prev.Length }
      } else {
        $result = @{ ok = $true; clip = 'nothing-to-restore' }
      }
    }
    'key' {
      $n = 1
      if ($null -ne $req.n) { $n = [int]$req.n }
      $r = Invoke-Key $target ([string]$req.name) $n
      $result = Get-WindowInfo $target
      $result.did = $r
    }
    'batch' {
      $client = Get-ClientInfo $target.Child
      $log = New-Object System.Collections.ArrayList
      $lastTap = $null
      $preShot = $null
      $verify = $null
      if ($null -ne $req.verify) { $verify = @($req.verify) }
      # 要验证就先留一张「动作前」的底片，动作后再比同一块区域
      if ($null -ne $verify -and $req.capture) {
        $preShot = [System.IO.Path]::ChangeExtension([string]$req.out, '.pre.png')
        Invoke-Capture $target $preShot $null $null 0 | Out-Null
      }
      foreach ($st in @($req.steps)) {
        $op = [string]$st.op
        switch ($op) {
          'tap' {
            $pt2 = ConvertTo-Point $st.at $client
            Invoke-Tap $target $pt2[0] $pt2[1]
            $lastTap = @($pt2[0], $pt2[1])
            [void]$log.Add(@{ op = 'tap'; at = [string]$st.at; px = $pt2 })
            Start-Sleep -Milliseconds 120
          }
          'swipe' {
            $pa = ConvertTo-Point $st.from $client
            $pb = ConvertTo-Point $st.to $client
            $ms2 = 300
            if ($null -ne $st.ms) { $ms2 = [int]$st.ms }
            Invoke-Swipe $target $pa[0] $pa[1] $pb[0] $pb[1] $ms2
            [void]$log.Add(@{ op = 'swipe'; from = [string]$st.from; to = [string]$st.to; ms = $ms2 })
            Start-Sleep -Milliseconds 120
          }
          'key' {
            $nn = 1
            if ($null -ne $st.n) { $nn = [int]$st.n }
            Invoke-Key $target ([string]$st.name) $nn | Out-Null
            [void]$log.Add(@{ op = 'key'; name = [string]$st.name; n = $nn })
            Start-Sleep -Milliseconds 80
          }
          'text' {
            $rr = Invoke-Text $target ([string]$st.value) ([string]$st.at) ([string]$st.menu)
            [void]$log.Add(@{ op = 'text'; n = $rr.n; mode = $rr.mode; clip = $rr.clip; menu = $rr.menu; menuAt = $rr.menuAt; inserted = $rr.inserted; box = $rr.box })
            Start-Sleep -Milliseconds 120
          }
          'openmenu' {
            $po = ConvertTo-Point $st.at $client
            $mo = 900
            if ($null -ne $st.ms) { $mo = [int]$st.ms }
            $om = Invoke-OpenMenu $target ([string]$st.at) $mo ([string]$st.text)
            [void]$log.Add(@{ op = 'openmenu'; at = [string]$st.at; opened = $om.opened; box = $om.box; crop = $om.crop })
            Start-Sleep -Milliseconds 120
          }
          'longpress' {
            $pl = ConvertTo-Point $st.at $client
            $msl = 700
            if ($null -ne $st.ms) { $msl = [int]$st.ms }
            Invoke-LongPress $target $pl[0] $pl[1] $msl
            [void]$log.Add(@{ op = 'longpress'; at = [string]$st.at; ms = $msl })
            Start-Sleep -Milliseconds 120
          }
          'clip' {
            if ($null -ne $st.value -and ([string]$st.value) -eq '@restore') {
              # 约定值：还原 openmenu/写入前备份的原剪贴板
              $bak = Join-Path (Join-Path $env:TEMP 'dsh-mi-phone-use') 'clip-backup.txt'
              if (Test-Path $bak) {
                $prev = [IO.File]::ReadAllText($bak, [System.Text.UTF8Encoding]::new($false))
                Set-Clipboard -Value $prev -ErrorAction Stop
                Remove-Item $bak -Force -ErrorAction SilentlyContinue
                [void]$log.Add(@{ op = 'clip'; restored = $true; n = $prev.Length })
              } else {
                [void]$log.Add(@{ op = 'clip'; restored = $false; note = 'no backup' })
              }
            } elseif ($null -ne $st.value) {
              # 写入新内容前先备份一次原剪贴板（只在还没备份时存）
              $bak = Join-Path (Join-Path $env:TEMP 'dsh-mi-phone-use') 'clip-backup.txt'
              if (-not (Test-Path $bak)) {
                try {
                  $prev = Get-Clipboard -Raw -ErrorAction Stop
                  [IO.File]::WriteAllText($bak, $prev, [System.Text.UTF8Encoding]::new($false))
                } catch { }
              }
              Set-Clipboard -Value ([string]$st.value) -ErrorAction Stop
              [void]$log.Add(@{ op = 'clip'; set = $true; n = ([string]$st.value).Length })
            } else {
              $ctext = ''
              try { $ctext = Get-Clipboard -Raw -ErrorAction Stop } catch { $ctext = '' }
              [void]$log.Add(@{ op = 'clip'; read = $true; n = $ctext.Length; head = $ctext.Substring(0, [math]::Min(60, $ctext.Length)) })
            }
            Start-Sleep -Milliseconds 80
          }
          'wait' {
            $wm = 400
            if ($null -ne $st.ms) { $wm = [int]$st.ms }
            Start-Sleep -Milliseconds $wm
            [void]$log.Add(@{ op = 'wait'; ms = $wm })
          }
          default { throw "unknown step op: $op" }
        }
      }
      $result = Get-WindowInfo $target
      $result.steps = $log
      if ($req.capture) {
        $capOut = [string]$req.out
        $capPrev = [string]$req.prev
        $capRegion = $null
        if ($null -ne $req.region) { $capRegion = @($req.region) }
        $capMax = 0
        if ($null -ne $req.maxWidth) { $capMax = [int]$req.maxWidth }
        $img = Invoke-Capture $target $capOut $capPrev $capRegion $capMax

        # 点击验证：只比目标那块；没变就重试一次（只一次，不盲目重试）
        if ($null -ne $verify -and $preShot) {
          $hit = Test-RegionChanged $preShot $capOut $verify $client
          $tries = 1
          if ($hit -eq $false -and $null -ne $lastTap -and $req.retry -ne $false) {
            Start-Sleep -Milliseconds 450
            Invoke-Tap $target $lastTap[0] $lastTap[1]
            Start-Sleep -Milliseconds 550
            $img = Invoke-Capture $target $capOut $null $capRegion $capMax
            $hit = Test-RegionChanged $preShot $capOut $verify $client
            $tries = 2
          }
          $result.hit = $hit
          $result.tries = $tries
          # 顶部条带变了 → 多半弹了通知，页面可能被挤下去
          $result.banner = Test-RegionChanged $preShot $capOut @(0, 0, 100, 14) $client
          Remove-Item $preShot -Force -ErrorAction SilentlyContinue
        }
        $result.img = $img
      } elseif ($null -ne $verify) {
        $result.hit = $null
      }
    }
    default { throw "unknown action: $action" }
  }
} catch {
  $result = @{ ok = $false; error = $_.Exception.Message; type = $_.Exception.GetType().Name }
}

$json = $result | ConvertTo-Json -Depth 10 -Compress
if ($ResultFile) {
  [System.IO.File]::WriteAllText($ResultFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}
if (-not $ResultFile) { $json }
