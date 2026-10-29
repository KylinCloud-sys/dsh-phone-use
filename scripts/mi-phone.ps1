<#
.SYNOPSIS
  dsh-mi-phone-use 底层执行器：小米互联（跨屏协作）手机窗口的全后台操控。

.DESCRIPTION
  设计参照同类 Windows 窗口后台操控实现
  （只读参考，未修改外部文件）：
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
    {"action":"longpress","x":40,"y":96,"ms":900}
    {"action":"text","value":"hello","at":"40,96","menu":"38,18"}   # ASCII 直接打，含中文时必须给 menu（粘贴坐标）
    {"action":"openmenu","at":"40,96","value":"要粘贴的文字"}        # 只弹菜单 + 出图，不点任何菜单项
    {"action":"clip","value":"..."}         # 写剪贴板；value 为 "@restore" 时还原
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

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
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
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
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
        // includeHidden=true 时把不可见/最小化窗口也纳入（唤醒场景需要找回被推到屏幕外的窗口）
        public static IntPtr FindParent(string[] titles, string className) { return FindParent(titles, className, false); }
        public static IntPtr FindParent(string[] titles, string className, bool includeHidden)
        {
            IntPtr best = IntPtr.Zero;
            int bestScore = 0;
            EnumWindows((h, l) =>
            {
                if (!includeHidden && !IsWindowVisible(h)) return true;
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

        // 纯后台恢复：不激活、不抢焦点、不动鼠标。返回是否做过恢复动作。
        public static bool RestoreNoActivate(IntPtr h)
        {
            bool acted = false;
            if (IsIconic(h)) { ShowWindow(h, 4); acted = true; }   // SW_SHOWNOACTIVATE
            // 纯隐藏（非最小化、坐标正常但不可见）也必须显示出来，否则 PrintWindow 拿不到画面
            if (!IsWindowVisible(h)) { ShowWindow(h, 4); acted = true; }
            RECT r;
            GetWindowRect(h, out r);
            int sw = GetSystemMetrics(0), sh = GetSystemMetrics(1);
            int w = r.Right - r.Left, hgt = r.Bottom - r.Top;
            if (w <= 0 || hgt <= 0) { w = 1024; hgt = 640; }        // 最小化状态的 rect 不可信
            if (!acted && r.Left > -30000 && r.Top > -30000 && w > 0 && hgt > 0) return false;
            // 被推到屏幕外（如 -21333,-21333）时挪回可见区中心，仍不激活
            const uint SWP_NOACTIVATE = 0x0010, SWP_NOZORDER = 0x0004, SWP_SHOWWINDOW = 0x0040;
            int x = Math.Max(0, (sw - w) / 2), y = Math.Max(0, (sh - hgt) / 2);
            SetWindowPos(h, IntPtr.Zero, x, y, w, hgt, SWP_NOACTIVATE | SWP_NOZORDER | SWP_SHOWWINDOW);
            return true;
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
  # 主人点任务栏「妙享桌面-<设备名>」图标后，窗口会先以一个自绘窗口类出现（过渡态、无子窗口），
  # 随后演变成「跨屏协作」kMiScreenShareMainWindow（正式投屏窗口，带 kMiChildSharedWindow 子窗口）。
  # 因此两个标题都要认，按实际形态择优选：有子窗口的优先，其次是当前可见且有内容的。
  WindowTitles = @('跨屏协作', '妙享桌面')
  ParentClass  = ''
  ChildClass   = 'kMiChildSharedWindow'
}

# ---------------------------------------------------------------------------
# 基础
# ---------------------------------------------------------------------------
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
    # 窗口被收起/推到屏幕外时也能找回；纯后台恢复，不激活、不抢焦点。
    $parent = [MiPhone.Native]::FindParent($spec.Titles, $spec.ParentClass, $true)
  }
  if ($parent -eq [IntPtr]::Zero) {
    $hint = ($spec.Titles -join ' / ')
    throw "window not found: $hint（请先打开小米互联的手机画面）"
  }
  if ([MiPhone.Native]::IsIconic($parent)) {
    [void][MiPhone.Native]::RestoreNoActivate($parent)
    Start-Sleep -Milliseconds 300
  }
  $child = [MiPhone.Native]::FindChild($parent, $spec.ChildClass)
  if ($child -eq [IntPtr]::Zero) {
    $child = [MiPhone.Native]::FindChild($parent, '')
  }
  if ($child -eq [IntPtr]::Zero) {
    # 部分版本把手机画面直接画在「妙享桌面」自身，没有子窗口。
    $self = Get-ClientInfo $parent
    if ($self.W -ge 100 -and $self.H -ge 100) { $child = $parent }
  }
  if ($child -eq [IntPtr]::Zero) {
    throw 'content child not found: 父窗口下没有可见子窗口（手机画面可能未投出来）'
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

  # 空白检测：主色占比过高 → 投屏没真正建立（实测加载态 97% 纯白，颜色数 32 却仍是空的）
  try {
    $stepX = [math]::Max(1, [int]($crop.Width / 96))
    $stepY = [math]::Max(1, [int]($crop.Height / 96))
    $colors = New-Object 'System.Collections.Generic.HashSet[string]'
    $colorCount = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $sum = 0.0; $sum2 = 0.0; $n = 0; $darkCount = 0; $blueCount = 0
    $blueMinX = [int]::MaxValue; $blueMinY = [int]::MaxValue; $blueMaxX = -1; $blueMaxY = -1
    for ($sy = 0; $sy -lt $crop.Height; $sy += $stepY) {
      for ($sx = 0; $sx -lt $crop.Width; $sx += $stepX) {
        $c = $crop.GetPixel($sx, $sy)
        $v = ($c.R + $c.G + $c.B) / 3.0
        $sum += $v; $sum2 += $v * $v; $n++
        $key = "$([int]($c.R / 16)):$([int]($c.G / 16)):$([int]($c.B / 16))"
        [void]$colors.Add($key)
        if ($colorCount.ContainsKey($key)) { $colorCount[$key]++ } else { $colorCount[$key] = 1 }
        if ($c.R -lt 60 -and $c.G -lt 60 -and $c.B -lt 60) { $darkCount++ }
        if ($c.B -gt 150 -and ($c.B - $c.R) -gt 80) {
          $blueCount++
          if ($sx -lt $blueMinX) { $blueMinX = $sx }
          if ($sx -gt $blueMaxX) { $blueMaxX = $sx }
          if ($sy -lt $blueMinY) { $blueMinY = $sy }
          if ($sy -gt $blueMaxY) { $blueMaxY = $sy }
        }
      }
    }
    if ($n -gt 0) {
      $mean = $sum / $n
      $sd = [math]::Sqrt([math]::Max(0.0, ($sum2 / $n) - ($mean * $mean)))
      # 主色占比：投屏未建立时画面几乎被单一底色占满（实测加载态 97% 纯白）。
      # 真实手机画面即使背景素，也总有文字/图标把主色压到 90% 以下。
      $top = 0
      foreach ($kv in $colorCount.GetEnumerator()) { if ($kv.Value -gt $top) { $top = $kv.Value } }
      $dominant = [double]$top / [double]$n
      $result.colors = $colors.Count
      $result.dominant = [math]::Round($dominant, 3)
      $result.stdev = [math]::Round($sd, 2)
      # 占位页判定：单一主色占满（加载/失败/解锁页几乎全白），
      # 或整屏过暗（窗口刚创建、内容未渲染的黑屏，实测 dominant=0.74 且 74% 是黑）。
      $darkRatio = $darkCount / [double]$n
      $result.blank = (($dominant -ge 0.94) -or ($darkRatio -ge 0.60))
      $result.dark = [math]::Round($darkCount / [double]$n, 4)
      $result.blue = [math]::Round($blueCount / [double]$n, 4)
      # 蓝色元素包围盒占比：解锁提示页有一整幅蓝色手绘插图（占宽 54%、占高 31%），
      # 加载失败页只有一行蓝色小字（包围盒极小）。用这个区分"已连上待解锁"和"连不上"。
      $blueWide = 0.0; $blueTall = 0.0
      if ($blueCount -gt 0 -and $blueMaxX -ge $blueMinX -and $blueMaxY -ge $blueMinY) {
        $blueWide = ($blueMaxX - $blueMinX + 1) / [double]$crop.Width
        $blueTall = ($blueMaxY - $blueMinY + 1) / [double]$crop.Height
      }
      $result.blueWide = [math]::Round($blueWide, 3)
      $result.blueTall = [math]::Round($blueTall, 3)
      # 解锁提示页：蓝色插图够大 + 有黑色标题字
      $result.unlockPage = ($result.blank -and $blueWide -ge 0.30 -and $blueTall -ge 0.15 -and ($darkCount / [double]$n) -gt 0.001)
      # 加载失败页：有蓝字但没有大插图
      $result.errorPage = $result.blank -and (-not $result.unlockPage) -and (($darkCount / [double]$n) -gt 0.001) -and (($blueCount / [double]$n) -gt 0.0002)
    }
  } catch { }

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

# 已知「粘贴」坐标时的一步式粘贴：写剪贴板 → 长按输入框 → 点给定坐标 → 校验 → 还原剪贴板。
# 坐标哪来的？由 openmenu 出图、调用方看图算出来的（菜单样式每个 App 都不一样，不能写死）。
function Invoke-PasteAt($target, [string]$text, [string]$at, [string]$menu, [int]$holdMs) {
  $client = Get-ClientInfo $target.Child
  $ptA = ConvertTo-Point $at $client
  $ptM = ConvertTo-Point $menu $client
  if ($holdMs -le 0) { $holdMs = 800 }
  $shotDir = Join-Path $env:TEMP 'dsh-mi-phone-use'
  if (-not (Test-Path $shotDir)) { New-Item -ItemType Directory -Path $shotDir -Force | Out-Null }
  $preShot = Join-Path $shotDir 'paste-pre.png'
  $afterShot = Join-Path $shotDir 'paste-after.png'

  $prevText = $null
  $hadPrev = $false
  try { $prevText = Get-Clipboard -Raw -ErrorAction Stop; $hadPrev = $true } catch { $hadPrev = $false }

  Set-Clipboard -Value $text -ErrorAction Stop
  Start-Sleep -Milliseconds 2000        # 等互联同步剪贴板（实测可能要 3s+，见 DEVLOG D4b）

  try { Invoke-Capture $target $preShot $null $null 0 | Out-Null } catch { }
  Invoke-LongPress $target $ptA[0] $ptA[1] $holdMs
  Start-Sleep -Milliseconds 700
  Invoke-Tap $target $ptM[0] $ptM[1]
  Start-Sleep -Milliseconds 800

  # 校验：输入框那条横带应该出现新字（比较基准是长按前那张，那时菜单还没出来）
  $rh = [int][math]::Ceiling($client.H * 0.10)
  $ry = [int][math]::Max(0, [math]::Min($client.H - $rh, $ptA[1] - [int]($rh / 2)))
  $fieldRect = @(2, [int]($ry * 100.0 / $client.H), 96, [int]($rh * 100.0 / $client.H))
  $inserted = $null
  try {
    Invoke-Capture $target $afterShot $null $null 0 | Out-Null
    $inserted = Test-RegionChanged $preShot $afterShot $fieldRect $client
  } catch { $inserted = $null }

  $restored = 'none'
  if ($hadPrev) {
    try { Set-Clipboard -Value $prevText -ErrorAction Stop; $restored = $true }
    catch { $restored = $false }
  }
  return @{ mode = 'paste-menu'; n = $text.Length; clip = $restored; at = $at; menu = 'given'; menuAt = $menu; inserted = $inserted }
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
      return (Invoke-OpenMenu $target $at 800 $text)
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
# 调用方看这张图确认「粘贴」在哪，再用 {"tap":"x,y"} 点；点完用 {"clip":"@restore"} 还原剪贴板。
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
# 唤起 / 恢复小米互联
# ---------------------------------------------------------------------------
function Resolve-XiaomiExecutable([string]$launchPath) {
  if ($launchPath) {
    $candidate = [IO.Path]::GetFullPath($launchPath)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    throw "找不到指定的小米互联程序：$candidate"
  }

  # 优先使用已经运行的进程路径；否则在常见安装位置找官方客户端。
  try {
    $running = Get-Process -Name 'XiaomiPcManager' -ErrorAction SilentlyContinue |
      Where-Object { $_.Path } | Select-Object -First 1
    if ($running -and (Test-Path -LiteralPath $running.Path -PathType Leaf)) { return $running.Path }
  } catch { }
  $patterns = @(
    (Join-Path ${env:ProgramFiles} 'MI\XiaomiPCManager\*\XiaomiPcManager.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'MI\XiaomiPCManager\*\XiaomiPcManager.exe'),
    (Join-Path $env:LOCALAPPDATA 'MI\XiaomiPCManager\*\XiaomiPcManager.exe')
  )
  foreach ($pattern in $patterns) {
    if (-not $pattern) { continue }
    $found = Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
  }
  return $null
}

# 判定"这是不是真实手机画面"：不看尺寸（横竖屏会互换、缩放会改分辨率），
# 只看宽高比是否像一块手机屏，以及画面是否有内容。
function Test-PhoneAspect([int]$w, [int]$h) {
  if ($w -le 0 -or $h -le 0) { return $false }
  $ratio = [double]$w / [double]$h
  if ($ratio -lt 1.0) { $ratio = 1.0 / $ratio }   # 横屏时取倒数，两种朝向都接受
  # 常见手机屏 16:9(1.78) ~ 21:9(2.33)，留点余量
  return ($ratio -ge 1.55 -and $ratio -le 2.45)
}

# 在进程里按类名找窗口（含隐藏），用于找 MiScreenShare 自己建的投屏窗口。
function Find-WindowByClassInProcess([int]$procId, [string]$className) {
  $found = [IntPtr]::Zero
  $cb = [MiPhone.Native+EnumProc]{
    param($h, $l)
    $owner = 0
    [void][MiPhone.Native]::GetWindowThreadProcessId($h, [ref]$owner)
    if ($owner -eq $procId -and [MiPhone.Native]::ClassOf($h) -eq $className) {
      $script:wakeFound = $h
    }
    return $true
  }
  [void][MiPhone.Native]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:wakeFound
}

# 找 MiScreenShare.exe 的位置（它才是真正建「跨屏协作」窗口的进程）。
function Resolve-ScreenShareExecutable([string]$exeName = 'MiSmartShareHandoff.exe') {
  if (-not $exeName) { $exeName = 'MiSmartShareHandoff.exe' }
  $baseName = [IO.Path]::GetFileNameWithoutExtension($exeName)
  $proc = Get-Process -Name $baseName -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
  if ($proc) { return $proc.Path }
  $manager = Get-Process -Name 'XiaomiPcManager' -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
  if ($manager) {
    $cand = Join-Path (Split-Path -Parent $manager.Path) $exeName
    if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
  }
  $patterns = @(
    (Join-Path ${env:ProgramFiles} ("MI\XiaomiPCManager\*\" + $exeName)),
    (Join-Path ${env:ProgramFiles(x86)} ("MI\XiaomiPCManager\*\" + $exeName)),
    (Join-Path $env:LOCALAPPDATA ("MI\XiaomiPCManager\*\" + $exeName))
  )
  foreach ($p in $patterns) {
    if (-not $p) { continue }
    $hit = Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return $null
}

# 画面是不是"空壳"：纯色/近纯色说明投屏还没真正开始。
function Get-SurfaceStats($target) {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mi-surface-' + [guid]::NewGuid().ToString('N') + '.png')
  try {
    $null = Invoke-Capture $target $tmp $null $null 0
    if (-not (Test-Path -LiteralPath $tmp)) { return $null }
    $bmp = [System.Drawing.Bitmap]::FromFile($tmp)
    try {
      $stepX = [math]::Max(1, [int]($bmp.Width / 96))
      $stepY = [math]::Max(1, [int]($bmp.Height / 96))
      $colorCount = New-Object 'System.Collections.Generic.Dictionary[string,int]'
      $sum = 0.0; $sum2 = 0.0; $n = 0; $darkCount = 0; $blueCount = 0
    $blueMinX = [int]::MaxValue; $blueMinY = [int]::MaxValue; $blueMaxX = -1; $blueMaxY = -1
      for ($y = 0; $y -lt $bmp.Height; $y += $stepY) {
        for ($x = 0; $x -lt $bmp.Width; $x += $stepX) {
          $c = $bmp.GetPixel($x, $y)
          $v = ($c.R + $c.G + $c.B) / 3.0
          $sum += $v; $sum2 += $v * $v; $n++
          $key = "$([int]($c.R / 16)):$([int]($c.G / 16)):$([int]($c.B / 16))"
          if ($colorCount.ContainsKey($key)) { $colorCount[$key]++ } else { $colorCount[$key] = 1 }
          if ($c.R -lt 60 -and $c.G -lt 60 -and $c.B -lt 60) { $darkCount++ }
          if ($c.B -gt 150 -and ($c.B - $c.R) -gt 80) {
            $blueCount++
            if ($x -lt $blueMinX) { $blueMinX = $x }
            if ($x -gt $blueMaxX) { $blueMaxX = $x }
            if ($y -lt $blueMinY) { $blueMinY = $y }
            if ($y -gt $blueMaxY) { $blueMaxY = $y }
          }
        }
      }
      if ($n -eq 0) { return $null }
      $mean = $sum / $n
      $sd = [math]::Sqrt([math]::Max(0.0, ($sum2 / $n) - ($mean * $mean)))
      $top = 0
      foreach ($kv in $colorCount.GetEnumerator()) { if ($kv.Value -gt $top) { $top = $kv.Value } }
      $dominant = [double]$top / [double]$n
      $bw2 = 0.0; $bt2 = 0.0
      if ($blueCount -gt 0 -and $blueMaxX -ge $blueMinX -and $blueMaxY -ge $blueMinY) {
        $bw2 = ($blueMaxX - $blueMinX + 1) / [double]$bmp.Width
        $bt2 = ($blueMaxY - $blueMinY + 1) / [double]$bmp.Height
      }
      return @{
        colors   = $colorCount.Count
        mean     = [math]::Round($mean, 1)
        stdev    = [math]::Round($sd, 2)
        dominant = [math]::Round($dominant, 3)
        blank    = (($dominant -ge 0.94) -or (($darkCount / [double]$n) -ge 0.60))
        hash     = [MiPhone.Img]::Hash($bmp)
        # 失败页特征（主人实测）：黑字标题 + 蓝色链接同时存在。
        # 连接页是彩色圆点，黑字极少，可据此区分。
        dark  = [math]::Round($darkCount / [double]$n, 4)
        blue  = [math]::Round($blueCount / [double]$n, 4)
        blueWide = [math]::Round($bw2, 3)
        blueTall = [math]::Round($bt2, 3)
        unlockPage = (($dominant -ge 0.94) -and $bw2 -ge 0.30 -and $bt2 -ge 0.15 -and ($darkCount / [double]$n) -gt 0.001)
        errorPage = (($dominant -ge 0.94) -and -not ($bw2 -ge 0.30 -and $bt2 -ge 0.15)) -and (($darkCount / [double]$n) -gt 0.001) -and (($blueCount / [double]$n) -gt 0.0002)
      }
    } finally { $bmp.Dispose() }
  } catch {
    return $null
  } finally {
    try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } } catch { }
  }
}

# 全后台唤醒：只用窗口 API 与进程启动，不点任务栏/托盘、不 SendInput、不动鼠标、不激活窗口。
# 区分"正在连接"和"加载失败"：不靠 OCR，靠画面有没有在动。
# 主人实测：连接中有三个跳动的彩色圆点（画面持续变化）；加载失败是静态错误页（画面完全不动）。
#
# 重要边界：本函数只在「主色占比 >= 0.94（blank）」的前提下才有判别意义。
# 手机桌面静止时画面也不动，但桌面不可能 94% 以上是同一主色，所以不会走到这里；
# 绝不可把「静止」单独当作失败判据。
function Test-SurfaceAnimating($target, [int]$samples = 3, [int]$gapMs = 900) {
  $hashes = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $samples; $i++) {
    $st = Get-SurfaceStats $target
    if ($null -ne $st -and $st.hash) { $hashes.Add([string]$st.hash) }
    if ($i -lt $samples - 1) { Start-Sleep -Milliseconds $gapMs }
  }
  if ($hashes.Count -lt 2) { return $null }
  $distinct = ($hashes | Select-Object -Unique).Count
  return @{
    samples  = $hashes.Count
    distinct = $distinct
    animating = ($distinct -gt 1)
  }
}
# 以指定进程为父进程启动子进程。
# 关键：管家派生 MiSmartShareHandoff 时，子进程能继承管家的管道/句柄，投屏握手才成立；
# 由 PowerShell 直接启动会变成孤儿进程（ppid=shell），表现为加载页长时间不结束。
function Start-ProcessWithParent([int]$parentPid, [string]$exePath, [string]$cmdLine) {
  if (-not ([System.Management.Automation.PSTypeName]'MiPhone.Spawner').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace MiPhone {
  public class Spawner {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
      public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
      public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
      public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] public struct STARTUPINFOEX { public STARTUPINFO si; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr l, int c, int f, ref IntPtr s);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr l, uint f, IntPtr a, IntPtr v, IntPtr cb, IntPtr p, IntPtr r);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool DeleteProcThreadAttributeList(IntPtr l);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inh, uint flags, IntPtr env, string dir, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);

    public static string Spawn(int parentPid, string exe, string cmd) {
      IntPtr hp = OpenProcess(0x0080, false, parentPid);
      if (hp == IntPtr.Zero) return "ERR|OpenProcess " + Marshal.GetLastWin32Error();
      IntPtr al = IntPtr.Zero;
      try {
        IntPtr sz = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref sz);
        al = Marshal.AllocHGlobal(sz);
        if (!InitializeProcThreadAttributeList(al, 1, 0, ref sz)) return "ERR|Init " + Marshal.GetLastWin32Error();
        IntPtr v = Marshal.AllocHGlobal(IntPtr.Size);
        Marshal.WriteIntPtr(v, hp);
        bool ok = UpdateProcThreadAttribute(al, 0, (IntPtr)0x00020000, v, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero);
        Marshal.FreeHGlobal(v);
        if (!ok) return "ERR|Attr " + Marshal.GetLastWin32Error();
        var si = new STARTUPINFOEX();
        si.si.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        si.lpAttributeList = al;
        PROCESS_INFORMATION pi;
        if (!CreateProcess(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, 0x08080000, IntPtr.Zero, null, ref si, out pi))
          return "ERR|Create " + Marshal.GetLastWin32Error();
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        return "OK|" + pi.dwProcessId;
      } finally {
        if (al != IntPtr.Zero) { DeleteProcThreadAttributeList(al); Marshal.FreeHGlobal(al); }
        CloseHandle(hp);
      }
    }
  }
}
"@ -ErrorAction Stop
  }
  return [MiPhone.Spawner]::Spawn($parentPid, $exePath, $cmdLine)
}
# 后台点击窗口客户区某点（PostMessage，不移动鼠标、不抢焦点）。
function Invoke-BackgroundClick([IntPtr]$hwnd, [int]$x, [int]$y) {
  $lp = [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))
  [void][MiPhone.Native]::PostMessage($hwnd, 0x0201, [IntPtr]1, $lp)   # WM_LBUTTONDOWN
  Start-Sleep -Milliseconds 80
  [void][MiPhone.Native]::PostMessage($hwnd, 0x0202, [IntPtr]0, $lp)   # WM_LBUTTONUP
}

# 「妙享桌面」是启动器：窗口出现后需要点一下才会拉起「跨屏协作」。
# 若窗口内容是纯色（还没渲染出按钮），点了也没用，先等它渲染。
function Invoke-LauncherClick([IntPtr]$hwnd) {
  # 启动器窗口常是自绘 + 最小化/屏幕外，先纯后台恢复出有效客户区，否则点是空坐标。
  if ([MiPhone.Native]::IsIconic($hwnd) -or -not [MiPhone.Native]::IsWindowVisible($hwnd)) {
    [void][MiPhone.Native]::RestoreNoActivate($hwnd)
    Start-Sleep -Milliseconds 400
  }
  $client = Get-ClientInfo $hwnd
  if ($client.W -lt 100 -or $client.H -lt 100) { return $false }

  # 关键：这个自绘窗口必须先收到 WM_ACTIVATE，随后的鼠标消息才会被处理。
  # 实测只发 WM_LBUTTONDOWN/UP 完全无效；补一条 WM_ACTIVATE 就能拉起「跨屏协作」。
  # 注意 WM_ACTIVATE 只是投递窗口消息，不会把窗口提到前台、不动鼠标。
  [void][MiPhone.Native]::PostMessage($hwnd, 0x0006, [IntPtr]1, [IntPtr]0)   # WM_ACTIVATE(WA_ACTIVE)
  Start-Sleep -Milliseconds 200

  # 窗口内容全白也照样有效——主人实测点哪里都能拉起，所以不做内容判断。
  Invoke-BackgroundClick $hwnd ([int]($client.W / 2)) ([int]($client.H / 2))
  return $true
}
function Invoke-Wake($spec, $req) {
  $timeoutMs = 15000
  if ($null -ne $req.timeoutMs) { $timeoutMs = [int]$req.timeoutMs }
  $timeoutMs = [int][math]::Max(3000, [math]::Min(60000, $timeoutMs))
  $launchPath = [string]$req.launchPath
  $started = $false
  $restored = $false
  $launchError = $null

  # 1) 管家客户端要在跑，否则投屏无从谈起。
  $clientRunning = $false
  try {
    $clientRunning = $null -ne (Get-Process -Name 'XiaomiPcManager' -ErrorAction SilentlyContinue | Select-Object -First 1)
  } catch { $clientRunning = $false }
  if (-not $clientRunning) {
    $exe = Resolve-XiaomiExecutable $launchPath
    if (-not $exe) {
      return @{
        ok = $false; action = 'wake'; state = 'client-not-found'; deviceState = 'unknown'
        unlockRequired = $false
        userActionRequired = '电脑上没找到小米互联客户端。请安装并登录小米电脑管家。'
        error = '找不到小米互联客户端。'
      }
    }
    try {
      Start-Process -FilePath $exe -WindowStyle Minimized | Out-Null
      $started = $true
      Start-Sleep -Milliseconds 1200
    } catch { $launchError = $_.Exception.Message }
  }

  # 2) 正确唤起方式（主人实测）：只启动「妙享桌面」(MiSmartShareHandoff)，
  #    它会自己拉起「跨屏协作」(MiScreenShare)，随后妙享桌面自行关闭，最终只剩一个窗口。
  #    ⚠ 绝不能同时启动 MiScreenShare.exe：那样会多弹一个独立窗口，破坏握手，
  #    表现为加载页长时间不结束、最后报「无法连接」。
  $castRunning = $null -ne (Get-Process -Name 'MiSmartShareHandoff' -ErrorAction SilentlyContinue | Select-Object -First 1)
  if (-not $castRunning) {
    $hoExe = Resolve-ScreenShareExecutable 'MiSmartShareHandoff.exe'
    if ($hoExe) {
      $devName = [string]$req.deviceName
      $devId = [string]$req.deviceId
      # 没显式传就回退到 config.json 的 cast.deviceName / cast.deviceId（本机私有，不入库）
      if (-not $devId -or -not $devName) {
        try {
          $cfgPath = Join-Path $PSScriptRoot '..\config.local.json'
          if (Test-Path -LiteralPath $cfgPath) {
            $cfg = [IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
            if (-not $devId -and $cfg.cast -and $cfg.cast.deviceId) { $devId = [string]$cfg.cast.deviceId }
            if (-not $devName -and $cfg.cast -and $cfg.cast.deviceName) { $devName = [string]$cfg.cast.deviceName }
          }
        } catch { }
      }
      if ($devId) {
        $hoArgs = @("--CastBusinessType=`"1`"")
        if ($devName) { $hoArgs += "--DeviceName=`"$devName`"" }
        $hoArgs += "--DeviceID=`"$devId`""
        try {
          $mgrPid = 0
          try {
            $m = Get-Process -Name 'XiaomiPcManager' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($m) { $mgrPid = [int]$m.Id }
          } catch { }
          $cmdLine = '"' + $hoExe + '" ' + ($hoArgs -join ' ')
          $spawnResult = $null
          if ($mgrPid -gt 0) {
            # 以管家为父进程启动：子进程能继承管家的管道/句柄，投屏握手才成立。
            # 直接由 PowerShell 启动会变成孤儿进程，窗口虽在但内容渲染不出来、点也没反应。
            try { $spawnResult = Start-ProcessWithParent $mgrPid $hoExe $cmdLine } catch { $spawnResult = $null }
          }
          if (-not ($spawnResult -like 'OK|*')) {
            # 回退：普通启动（可能不完整，但至少给主人一个窗口去点）
            Start-Process -FilePath $hoExe -ArgumentList $hoArgs -WindowStyle Minimized | Out-Null
          }
          $started = $true
        } catch { $launchError = $_.Exception.Message }
      } else {
        # 没有设备信息就交给管家 UI，不盲启动
        $launchError = '缺少 deviceId，无法后台发起投屏；请主人点一次任务栏「妙享桌面」图标。'
      }
    }
  }

  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  $blankOnce = $false
  $aspectReject = $false
  $lastTarget = $null
  $lastStats = $null
  $launcherClicked = $false
  while ((Get-Date) -lt $deadline) {
    $parent = [MiPhone.Native]::FindParent($spec.Titles, $spec.ParentClass, $true)
    if ($parent -eq [IntPtr]::Zero) {
      # 退回按类名在本进程内找（MiScreenShare 自建的窗口可能还没标题）
      $ssProc = Get-Process -Name 'MiScreenShare' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($ssProc) {
        $script:wakeFound = [IntPtr]::Zero
        $parent = Find-WindowByClassInProcess $ssProc.Id $spec.ParentClass
      }
    }
    if ($parent -ne [IntPtr]::Zero) {
      # 隐藏窗口要显示出来才能截图；SW_SHOWNOACTIVATE 不激活、不抢焦点
      if ([MiPhone.Native]::RestoreNoActivate($parent)) { $restored = $true; Start-Sleep -Milliseconds 250 }

      # 「妙享桌面」是启动器：必须点一下才会拉起「跨屏协作」。每轮最多点一次，避免刷点击。
      if (-not $launcherClicked -and [MiPhone.Native]::TitleOf($parent) -like '妙享桌面*') {
        $launcherClicked = Invoke-LauncherClick $parent
      }
      $child = [MiPhone.Native]::FindChild($parent, $spec.ChildClass)
      if ($child -eq [IntPtr]::Zero) { $child = [MiPhone.Native]::FindChild($parent, '') }
      if ($child -eq [IntPtr]::Zero) { $child = $parent }
      if ($child -ne [IntPtr]::Zero) {
        $client = Get-ClientInfo $child
        if (Test-PhoneAspect $client.W $client.H) {
          $target = @{ Parent = $parent; Child = $child }
          # 画面会经历 黑屏 → 加载页 → 解锁页/失败页 的快速过渡，单次采样容易误判。
          # 连续采样到状态稳定（连续 2 次判定一致）或超时，再下结论。
          $stats = $null
          $prevKey = $null
          $stableCount = 0
          for ($probe = 0; $probe -lt 8; $probe++) {
            $s = Get-SurfaceStats $target
            if ($null -ne $s) {
              $key = if ($s.unlockPage) { 'unlock' } elseif ($s.blank) { 'placeholder' } else { 'content' }
              if ($key -eq $prevKey) { $stableCount++ } else { $stableCount = 0 }
              $prevKey = $key
              $stats = $s
              # 连续两次一致即认为稳定；真实内容也要求稳定，避免把过渡帧当成 ready
              if ($stableCount -ge 1) { break }
            }
            Start-Sleep -Milliseconds 500
          }
          # 「手机解锁」提示页 = 投屏已连上、只差主人解锁，属于成功唤起。
          $isUnlockPage = ($null -ne $stats -and $stats.unlockPage -eq $true)
          if ($isUnlockPage) {
            $info = Get-WindowInfo $target
            $info.action = 'wake'
            $info.state = 'awaiting-unlock'
            $info.surface = 'unlock-prompt'
            $info.started = $started
            $info.restored = $restored
            $info.aspect = [math]::Round([double]$client.W / [double]$client.H, 3)
            $info.unlockRequired = $true
            $info.unlockState = 'locked'
            $info.ok = $true
            $info.userPrompt = '小米互联已连上，手机处于锁屏状态。请主人在手机上手动完成指纹解锁；解锁完成并确认后再继续操作。插件不会代为解锁。'
            return $info
          }
          if ($null -ne $stats -and -not $stats.blank) {
            $info = Get-WindowInfo $target
            $info.action = 'wake'
            $info.state = if ($started) { 'started' } elseif ($restored) { 'restored' } else { 'ready' }
            $info.surface = 'ready'
            $info.started = $started
            $info.restored = $restored
            $info.aspect = [math]::Round([double]$client.W / [double]$client.H, 3)
            # 画面已有真实内容（不是解锁提示页）说明手机已解锁可直接操作；
            # 但仍无法 100% 排除锁屏壁纸等情形，故标记 unknown 并在需要时提示。
            $info.unlockRequired = $false
            $info.unlockState = 'unlocked'
            $info.userPrompt = '小米互联画面已就绪，手机看起来已解锁，可以继续操作。若发现画面仍是锁屏，请主人手动指纹解锁。插件不会代为解锁。'
            return $info
          }
          $blankOnce = $true
          $lastTarget = $target
          $lastStats = $stats
        } elseif ($client.W -gt 0 -and $client.H -gt 0) {
          $aspectReject = $true
        }
      }
    }
    Start-Sleep -Milliseconds 500
  }

  if ($launchError) {
    return @{
      ok = $false; action = 'wake'; state = 'launch-failed'; started = $started
      unlockRequired = $false; error = "启动小米互联失败：$launchError"
    }
  }
  if ($blankOnce) {
    # 判"连接中"还是"已失败"，按可靠性排序：
    # 1) 失败页颜色特征（黑字标题 + 蓝链接，主人实测）—— 最可靠
    # 2) 画面是否在动 —— 连接中有跳动圆点；注意桌面静止时也不动，故只作兜底
    $motion = $null
    if ($lastTarget) { $motion = Test-SurfaceAnimating $lastTarget 3 900 }
    $isErrorPage = ($null -ne $lastStats -and $lastStats.errorPage -eq $true)
    $connecting = (-not $isErrorPage) -and ($null -ne $motion -and $motion.animating)
    return @{
      ok = $false; action = 'wake'
      state = if ($connecting) { 'connecting' } else { 'connect-failed' }
      deviceState = 'not-connected'
      started = $started; restored = $restored
      animating = if ($null -ne $motion) { $motion.animating } else { $null }
      unlockRequired = $false
      userActionRequired = if ($connecting) {
        '投屏正在连接中，请稍等片刻再让我唤醒一次。此时不需要指纹解锁。'
      } elseif ($isErrorPage) {
        '投屏没连上，画面停在「加载失败」页。请确认手机和电脑在同一局域网、手机端小米互联已开启，然后重新发起投屏。此时不需要指纹解锁。'
      } else {
        '投屏没连上，画面停在加载页且没有任何变化。请确认手机和电脑在同一局域网、手机端小米互联已开启，然后重新发起投屏。此时不需要指纹解锁。'
      }
      error = if ($connecting) { '投屏仍在连接中。' } elseif ($isErrorPage) { '投屏连接失败（加载失败页）。' } else { '投屏连接失败（画面无变化）。' }
      errorPage = $isErrorPage
    }
  }
  if ($aspectReject) {
    return @{
      ok = $false; action = 'wake'; state = 'surface-not-phone'; deviceState = 'not-connected'
      started = $started; restored = $restored
      unlockRequired = $false
      userActionRequired = '找到了窗口，但画面宽高比不像手机屏（可能是空壳或缩放中的过渡态）。请确认手机端已投屏。'
      error = '窗口宽高比不像手机画面。'
    }
  }
  return @{
    ok = $false; action = 'wake'; state = 'phone-not-found'; deviceState = 'not-connected'
    started = $started; restored = $restored
    unlockRequired = $false
    userActionRequired = '没找到跨屏协作窗口，通常表示手机不在身边或不在同一局域网。'
    error = '没有找到手机画面窗口。'
  }
}
# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
$result = $null
try {
  $raw = [System.IO.File]::ReadAllText($RequestFile, [System.Text.Encoding]::UTF8)
  $req = $raw | ConvertFrom-Json
  $action = [string]$req.action
  $spec = Resolve-WindowSpec $req.win

  if ($action -eq 'wake') {
    $result = Invoke-Wake $spec $req
  } else {
    $target = Resolve-Target $spec

    switch ($action) {
    'info' { $result = Get-WindowInfo $target }
    'restore' {
      # 同样走全后台恢复：不激活窗口、不抢焦点、不动鼠标。
      $wasIconic = [MiPhone.Native]::IsIconic($target.Parent)
      $moved = [MiPhone.Native]::RestoreNoActivate($target.Parent)
      if ($moved) { Start-Sleep -Milliseconds 250 }
      $info = Get-WindowInfo $target
      $info.restored = ($wasIconic -or $moved)
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
      $bak = Join-Path $env:TEMP 'dsh-mi-phone-use\clip-backup.txt'
      if ($null -ne $req.value) {
        if (-not (Test-Path $bak)) {
          try {
            $prev = Get-Clipboard -Raw -ErrorAction Stop
            [IO.File]::WriteAllText($bak, $prev, [System.Text.UTF8Encoding]::new($false))
          } catch { }
        }
        Set-Clipboard -Value ([string]$req.value) -ErrorAction Stop
        $result = @{ ok = $true; clip = 'set'; n = ([string]$req.value).Length }
      } else {
        $text = $null
        try { $text = Get-Clipboard -Raw -ErrorAction Stop } catch { $text = '' }
        $result = @{ ok = $true; clip = 'read'; n = $text.Length; head = $text.Substring(0, [math]::Min(40, $text.Length)) }
      }
    }
    'openmenu' {
      $hold = 900
      if ($null -ne $req.ms) { $hold = [int]$req.ms }
      $r = Invoke-OpenMenu $target ([string]$req.at) $hold ([string]$req.value)
      $result = Get-WindowInfo $target
      $result.did = $r
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
  }
} catch {
  $result = @{ ok = $false; error = $_.Exception.Message; type = $_.Exception.GetType().Name }
}

$json = $result | ConvertTo-Json -Depth 10 -Compress
if ($ResultFile) {
  [System.IO.File]::WriteAllText($ResultFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}
if (-not $ResultFile) { $json }
