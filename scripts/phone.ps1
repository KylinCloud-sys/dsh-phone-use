<#
.SYNOPSIS
  dsh-phone-use 底层执行器：小米互联（跨屏协作）手机窗口的全后台操控。

.DESCRIPTION
  设计参照同类 Windows 窗口后台操控实现
  （只读参考，未修改外部文件）：
    - 父窗口按标题「跨屏协作 / 妙享桌面」定位；
    - 画面子窗口取可见面积最大、层级最深的子孙（默认 kMiChildSharedWindow）；
    - 坐标基准 = 子窗口 client 区（就是标定 GUI 里「不带边框」的那个尺寸）；
    - 点击/滑动/按键全部走窗口消息，不抢前台、不移动鼠标。

  调用方式（结果写文件，避免中文走控制台编码）：
    powershell -NoProfile -ExecutionPolicy Bypass -File phone.ps1 -RequestFile req.json -ResultFile res.json

  请求 JSON：
    {"action":"info"}
    {"action":"capture","out":"...png","prev":"...png","region":[x,y,w,h],"maxWidth":0}
    {"action":"capture","smart":true,"out":"...png","rawOut":"...png","mode":"auto|full|region","region":[x,y,w,h],"opsDelta":0,"commit":true}
    {"action":"batch","steps":[{"op":"wheel","wheel":"down","notches":3,"at":"50,60","wait":400}],"capture":true,"out":"...png","rawOut":"...png"}
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
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace MiPhone
{
    public class Native
    {
        public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);


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
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
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

        // 后台滚轮：只向投屏子窗口发 WM_MOUSEWHEEL，不移动真实鼠标、不抢焦点。
        // WM_MOUSEWHEEL 的 lParam 按 Win32 约定是「屏幕坐标」，但部分自绘控件按客户区坐标解析；
        // 这里先按屏幕坐标发送（标准路径），实测不行时由 PS 层回退客户区坐标模式。
        public static void SendWheel(IntPtr h, int delta, int clientX, int clientY, bool screenCoords)
        {
            POINT p;
            p.X = clientX; p.Y = clientY;
            ClientToScreen(h, ref p);
            int x = screenCoords ? p.X : clientX;
            int y = screenCoords ? p.Y : clientY;
            IntPtr wParam = (IntPtr)(delta << 16);
            IntPtr lParam = (IntPtr)((y & 0xFFFF) << 16 | (x & 0xFFFF));
            SendMessage(h, 0x020A, wParam, lParam);   // WM_MOUSEWHEEL
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

    // 整帧差异统计：返回真实像素差异率、变化包围盒、变化块聚类数、标题带差异率。
    // 顶部状态栏与底部手势区会被屏蔽，避免时钟/电量/手势条触发误判。
    public class DiffStatsResult
    {
        public int ChangedPixels;
        public int TotalPixels;
        public int MinX;
        public int MinY;
        public int MaxX;
        public int MaxY;
        public int ClusterCount;
        public int ChangedBlocks;
        public int TotalBlocks;
        public int HeaderChangedPixels;
        public int HeaderTotalPixels;
        public double ChangeRatio { get { return TotalPixels <= 0 ? 0.0 : (double)ChangedPixels / (double)TotalPixels; } }
        public double HeaderRatio { get { return HeaderTotalPixels <= 0 ? 0.0 : (double)HeaderChangedPixels / (double)HeaderTotalPixels; } }
    }

    public class ImgStats
    {
        public static DiffStatsResult DiffStats(Bitmap a, Bitmap b, int tol, int maskTopPct, int maskBottomPct, int block)
        {
            if (a.Width != b.Width || a.Height != b.Height) return null;
            int w = a.Width, h = a.Height;
            int top = Math.Max(0, Math.Min(h, (int)Math.Floor(h * maskTopPct / 100.0)));
            int bottom = Math.Max(top, Math.Min(h, h - (int)Math.Ceiling(h * maskBottomPct / 100.0)));
            if (bottom <= top) return null;

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

                int bw = (w + block - 1) / block;
                int bh = (h + block - 1) / block;
                int[] blockChanged = new int[bw * bh];
                int[] blockTotal = new int[bw * bh];
                var result = new DiffStatsResult();
                result.MinX = int.MaxValue; result.MinY = int.MaxValue;
                result.MaxX = -1; result.MaxY = -1;
                int headerEnd = Math.Min(bottom, Math.Max(top, (int)Math.Round(h * 0.14)));

                for (int y = top; y < bottom; y++)
                {
                    int row = y * stride;
                    int by = y / block;
                    bool inHeader = y < headerEnd;
                    for (int x = 0; x < w; x++)
                    {
                        int i = row + x * 4;
                        bool diff = false;
                        int d0 = ba[i] - bb[i]; if (d0 < 0) d0 = -d0;
                        int d1 = ba[i + 1] - bb[i + 1]; if (d1 < 0) d1 = -d1;
                        int d2 = ba[i + 2] - bb[i + 2]; if (d2 < 0) d2 = -d2;
                        if (d0 > tol || d1 > tol || d2 > tol) diff = true;
                        int bi = by * bw + (x / block);
                        blockTotal[bi]++;
                        if (diff)
                        {
                            result.ChangedPixels++;
                            if (inHeader) result.HeaderChangedPixels++;
                            if (x < result.MinX) result.MinX = x;
                            if (x > result.MaxX) result.MaxX = x;
                            if (y < result.MinY) result.MinY = y;
                            if (y > result.MaxY) result.MaxY = y;
                            blockChanged[bi]++;
                        }
                        if (inHeader) result.HeaderTotalPixels++;
                    }
                }
                result.TotalPixels = Math.Max(0, (bottom - top) * w);
                result.TotalBlocks = bw * bh;

                bool[] changed = new bool[bw * bh];
                int minBX = int.MaxValue, minBY = int.MaxValue, maxBX = -1, maxBY = -1;
                for (int i = 0; i < changed.Length; i++)
                {
                    if (blockTotal[i] > 0 && blockChanged[i] > blockTotal[i] * 0.10)
                    {
                        changed[i] = true;
                        result.ChangedBlocks++;
                        int bx = i % bw, by = i / bw;
                        if (bx < minBX) minBX = bx;
                        if (bx > maxBX) maxBX = bx;
                        if (by < minBY) minBY = by;
                        if (by > maxBY) maxBY = by;
                    }
                }
                // 变化包围盒按变化块计算，避免零散视频噪点把框撑满整屏。
                if (maxBX >= 0)
                {
                    result.MinX = Math.Max(0, minBX * block);
                    result.MinY = Math.Max(0, minBY * block);
                    result.MaxX = Math.Min(w, (maxBX + 1) * block);
                    result.MaxY = Math.Min(h, (maxBY + 1) * block);
                }
                else
                {
                    result.MinX = 0; result.MinY = 0; result.MaxX = 0; result.MaxY = 0;
                }
                // 变化块聚类：4 邻域连通；只统计 >=2 块的簇，过滤孤立噪声块。
                bool[] seen = new bool[bw * bh];
                var stack = new Stack<int>();
                for (int i = 0; i < changed.Length; i++)
                {
                    if (!changed[i] || seen[i]) continue;
                    int size = 0;
                    stack.Push(i);
                    seen[i] = true;
                    while (stack.Count > 0)
                    {
                        int cur = stack.Pop();
                        size++;
                        int cx = cur % bw, cy = cur / bw;
                        int[] nx = new int[] { cx - 1, cx + 1, cx, cx };
                        int[] ny = new int[] { cy, cy, cy - 1, cy + 1 };
                        for (int k = 0; k < 4; k++)
                        {
                            if (nx[k] < 0 || nx[k] >= bw || ny[k] < 0 || ny[k] >= bh) continue;
                            int n = ny[k] * bw + nx[k];
                            if (changed[n] && !seen[n]) { seen[n] = true; stack.Push(n); }
                        }
                    }
                    if (size >= 2) result.ClusterCount++;
                }
                if (result.MaxX < 0) { result.MinX = 0; result.MinY = 0; result.MaxX = 0; result.MaxY = 0; }
                return result;
            }
            finally
            {
                a.UnlockBits(da);
                b.UnlockBits(db);
            }
        }

        // 只比一块矩形区域，返回精确差异像素数（verify 用）
        public static DiffStatsResult RegionDiff(Bitmap a, Bitmap b, int x, int y, int w, int h, int tol)
        {
            if (x < 0) { w += x; x = 0; }
            if (y < 0) { h += y; y = 0; }
            if (x + w > a.Width) w = a.Width - x;
            if (y + h > a.Height) h = a.Height - y;
            if (w <= 0 || h <= 0) return null;
            using (var ca = a.Clone(new Rectangle(x, y, w, h), a.PixelFormat))
            using (var cb = b.Clone(new Rectangle(x, y, w, h), b.PixelFormat))
                return DiffStats(ca, cb, tol, 0, 0, 8);
        }
    }

    // 百分比标尺：内容零遮挡地放在中间，四边标尺按 shortSide 自适应。
    public class RulerResult
    {
        public Bitmap Image;
        public int MarginPx;
        public int FontPx;
        public double Step;
        public double Minor;
        public int BorderPx;
        public string Theme;
        public double X0, X1, Y0, Y1;
        public bool IsFull;
    }

    public class Ruler
    {
        private static int Clamp(int v, int lo, int hi)
        {
            if (v < lo) return lo;
            if (v > hi) return hi;
            return v;
        }

        private static double PickMajorStep(int px, double spanPct, int fontSize)
        {
            if (spanPct <= 0) return 10;
            double[] candidates;
            if (spanPct <= 10) candidates = new double[] { 1, 2, 5 };
            else if (spanPct <= 25) candidates = new double[] { 2, 5, 10 };
            else if (spanPct <= 50) candidates = new double[] { 5, 10 };
            else candidates = new double[] { 10 };
            double minSpacing = Math.Max(24.0, fontSize * 2.0);
            foreach (double s in candidates)
            {
                if (spanPct / s < 2.0) continue;
                if (px * s / spanPct >= minSpacing) return s;
            }
            for (int i = candidates.Length - 1; i >= 0; i--)
                if (spanPct / candidates[i] >= 2.0) return candidates[i];
            return candidates[candidates.Length - 1];
        }

        private static double PickMinorStep(double major)
        {
            if (major <= 1) return 0.5;
            if (major <= 2) return 1;
            if (major <= 5) return 1;
            return 2;
        }

        private static string Fmt(double p, double step)
        {
            if (Math.Abs(step - Math.Round(step)) < 1e-6) return ((int)Math.Round(p)).ToString();
            return p.ToString("0.0");
        }

        private static bool IsDark(Bitmap content)
        {
            int w = content.Width, h = content.Height;
            double sum = 0; int n = 0;
            for (int i = 0; i < 5; i++)
            {
                for (int j = 0; j < 5; j++)
                {
                    int x = Math.Min(w - 1, w * (i * 20 + 10) / 100);
                    int y = Math.Min(h - 1, h * (j * 20 + 10) / 100);
                    Color c = content.GetPixel(x, y);
                    sum += (c.R + c.G + c.B) / 3.0; n++;
                }
            }
            return n > 0 && (sum / n) < 80;
        }

        public static RulerResult Draw(Bitmap content, double x0, double x1, double y0, double y1, int screenW, int screenH, int gridStep, string theme)
        {
            int cw = content.Width, ch = content.Height;
            if (x1 <= x0) x1 = x0 + 0.001;
            if (y1 <= y0) y1 = y0 + 0.001;
            int shortSide = Math.Min(cw, ch);
            int margin = Clamp((int)Math.Round(shortSide * 0.05), 16, 64);
            int fontSize = Clamp((int)Math.Round(shortSide * 0.025), 9, 32);
            int minorLen = Clamp((int)Math.Round(margin * 0.25), 3, 16);
            int majorLen = Clamp((int)Math.Round(margin * 0.50), 5, 28);
            int borderW = Math.Max(1, (int)Math.Round(margin * 0.06));
            bool full = (Math.Abs(x0) < 0.001 && Math.Abs(x1 - 100) < 0.001 && Math.Abs(y0) < 0.001 && Math.Abs(y1 - 100) < 0.001);
            // 紧凑模式只用于极小的「全屏窗口」；区域图仍按裁剪范围自适应，否则 50–60 这种小区间只剩两个标签。
            bool compact = shortSide < 320 && full;
            if (compact) { fontSize = 8; }

            bool dark = false;
            if (theme == "dark") dark = true;
            else if (theme == "auto") dark = IsDark(content);
            double stepX, stepY, minorX, minorY;
            if (full)
            {
                stepX = (gridStep == 5 && cw * 5.0 / 100.0 >= 24.0) ? 5 : 10;
                stepY = (gridStep == 5 && ch * 5.0 / 100.0 >= 24.0) ? 5 : 10;
                minorX = stepX / 5.0;
                minorY = stepY / 5.0;
            }
            else
            {
                stepX = PickMajorStep(cw, x1 - x0, fontSize);
                stepY = PickMajorStep(ch, y1 - y0, fontSize);
                minorX = PickMinorStep(stepX);
                minorY = PickMinorStep(stepY);
            }
            if (compact) { stepX = 10; stepY = 10; minorX = 5; minorY = 5; }

            Color bg = dark ? Color.FromArgb(30, 30, 30) : Color.FromArgb(245, 245, 245);
            Color borderColor = dark ? Color.FromArgb(102, 102, 102) : Color.FromArgb(176, 176, 176);
            Color majorColor = dark ? Color.FromArgb(208, 208, 208) : Color.FromArgb(90, 90, 90);
            Color minorColor = dark ? Color.FromArgb(128, 128, 128) : Color.FromArgb(154, 154, 154);
            Color textColor = dark ? Color.FromArgb(208, 208, 208) : Color.FromArgb(51, 51, 51);

            var outBmp = new Bitmap(cw + 2 * margin, ch + 2 * margin, PixelFormat.Format32bppArgb);
            var g = Graphics.FromImage(outBmp);
            g.SmoothingMode = SmoothingMode.None;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            try
            {
                g.Clear(bg);
                // 先画外框、再把内容贴上去：内容像素覆盖任何边框溢出，保证内容区逐像素一致。
                using (var borderPen = new Pen(borderColor, borderW))
                    g.DrawRectangle(borderPen, margin - borderW, margin - borderW, cw + borderW * 2, ch + borderW * 2);
                g.DrawImage(content, new Rectangle(margin, margin, cw, ch));

                using (var majorPen = new Pen(majorColor, Math.Max(1, borderW)))
                using (var minorPen = new Pen(minorColor, 1))
                using (var font = new Font("Arial", fontSize, FontStyle.Regular, GraphicsUnit.Pixel))
                using (var vertFont = new Font("Arial", Math.Max(7, fontSize - 3), FontStyle.Regular, GraphicsUnit.Pixel))
                using (var textBrush = new SolidBrush(textColor))
                using (var labelBg = new SolidBrush(bg))
                {
                    var sf = new StringFormat();
                    sf.Alignment = StringAlignment.Center;
                    sf.LineAlignment = StringAlignment.Center;

                    // 横向标尺：顶部 + 底部
                    double pStartX = Math.Ceiling((x0 - 1e-9) / minorX) * minorX;
                    for (double p = pStartX; p <= x1 + 1e-9; p += minorX)
                    {
                        if (p < x0 - 1e-9) continue;
                        double rel = (p - x0) / (x1 - x0);
                        float px = (float)(margin + rel * cw);
                        bool major = Math.Abs(p / stepX - Math.Round(p / stepX)) < 1e-6;
                        float len = major ? majorLen : minorLen;
                        g.DrawLine(major ? majorPen : minorPen, px, margin - 1, px, margin - len);
                        g.DrawLine(major ? majorPen : minorPen, px, margin + ch, px, margin + ch + len);
                        if (major)
                        {
                            string label = Fmt(p, stepX);
                            float labelH = fontSize + 6;
                            var topRect = new RectangleF(px - 40, margin / 2.0f - labelH / 2.0f, 80, labelH);
                            var botRect = new RectangleF(px - 40, margin + ch + margin / 2.0f - labelH / 2.0f, 80, labelH);
                            g.FillRectangle(labelBg, topRect);
                            g.FillRectangle(labelBg, botRect);
                            g.DrawString(label, font, textBrush, topRect, sf);
                            g.DrawString(label, font, textBrush, botRect, sf);
                        }
                    }

                    // 纵向标尺：左侧 + 右侧
                    double pStartY = Math.Ceiling((y0 - 1e-9) / minorY) * minorY;
                    for (double p = pStartY; p <= y1 + 1e-9; p += minorY)
                    {
                        if (p < y0 - 1e-9) continue;
                        double rel = (p - y0) / (y1 - y0);
                        float py = (float)(margin + rel * ch);
                        bool major = Math.Abs(p / stepY - Math.Round(p / stepY)) < 1e-6;
                        float len = major ? majorLen : minorLen;
                        g.DrawLine(major ? majorPen : minorPen, margin - 1, py, margin - len, py);
                        g.DrawLine(major ? majorPen : minorPen, margin + cw, py, margin + cw + len, py);
                        if (major)
                        {
                            string label = Fmt(p, stepY);
                            float labelH = fontSize + 6;
                            var leftRect = new RectangleF(0, py - labelH / 2.0f, margin, labelH);
                            var rightRect = new RectangleF(margin + cw, py - labelH / 2.0f, margin, labelH);
                            g.FillRectangle(labelBg, leftRect);
                            g.FillRectangle(labelBg, rightRect);
                            g.DrawString(label, vertFont, textBrush, leftRect, sf);
                            g.DrawString(label, vertFont, textBrush, rightRect, sf);
                        }
                    }

                    // 区域裁剪图左下角标注坐标空间，避免被当成局部 0-100。
                    if (!full)
                    {
                        using (var smallFont = new Font("Arial", Math.Max(7, fontSize - 2), FontStyle.Regular, GraphicsUnit.Pixel))
                        using (var smallBrush = new SolidBrush(textColor))
                        using (var smallBg = new SolidBrush(bg))
                        {
                            var label = "screen %";
                            var size = g.MeasureString(label, smallFont);
                            float lx = 2;
                            float ly = outBmp.Height - size.Height - 3;
                            g.FillRectangle(smallBg, lx - 1, ly - 1, size.Width + 4, size.Height + 2);
                            g.DrawString(label, smallFont, smallBrush, new PointF(lx, ly));
                        }
                    }
                }
            }
            finally { g.Dispose(); }

            var rr = new RulerResult();
            rr.Image = outBmp;
            rr.MarginPx = margin;
            rr.FontPx = fontSize;
            rr.Step = stepX;
            rr.Minor = minorX;
            rr.BorderPx = borderW;
            rr.Theme = dark ? "dark" : "light";
            rr.X0 = x0; rr.X1 = x1; rr.Y0 = y0; rr.Y1 = y1; rr.IsFull = full;
            return rr;
        }
    }
}
'@

[void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')

$dllDir = Join-Path $env:TEMP 'dsh-phone-use'
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
  # 正式投屏窗口类。优先按类名命中，避免把「妙享桌面」启动器窗口当成手机画面
  # （曾出现 phone_info 报 1127×642、phone_see 却拿到 372×844 的不一致）。
  ParentClass  = 'kMiScreenShareMainWindow'
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
    # 只有正式投屏窗口才允许「画面直接画在父窗口自身」。
    # 「妙享桌面-设备」只是启动器（自绘、无子窗口、尺寸也不是手机画面），绝不能当截图目标。
    $parentTitle = [MiPhone.Native]::TitleOf($parent)
    $parentClass = [MiPhone.Native]::ClassOf($parent)
    $isLauncher = $parentTitle -like '妙享桌面*' -and $parentClass -ne 'kMiScreenShareMainWindow'
    if ($isLauncher) {
      throw 'phone-launcher-not-ready: 当前只有「妙享桌面」启动器窗口，还没有跨屏协作画面；请先调用 phone_wake 唤起真实投屏'
    }
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
# 抓取整帧原始画面（无标尺）。尺寸严格等于当前画面区 client 尺寸，
# 即使 PrintWindow 窗口位图与 client 有偏移，也会按 client 尺寸重建画布，保证 s == PNG 像素尺寸。
function Get-FullFrameBitmap($target) {
  $parent = $target.Parent
  $child = $target.Child

  if ([MiPhone.Native]::IsIconic($parent)) { throw 'window-minimized: 窗口已最小化，需要先 restore' }
  if (-not [MiPhone.Native]::IsWindowVisible($parent)) { throw 'window-hidden: 窗口不可见' }

  $wr = New-Object 'MiPhone.Native+RECT'
  [void][MiPhone.Native]::GetWindowRect($parent, [ref]$wr)
  $ww = $wr.Right - $wr.Left
  $wh = $wr.Bottom - $wr.Top
  if ($ww -le 0 -or $wh -le 0) { throw "invalid window rect: ${ww}x${wh}" }

  $windowBmp = New-Object System.Drawing.Bitmap($ww, $wh)
  $g = [System.Drawing.Graphics]::FromImage($windowBmp)
  $hdc = $g.GetHdc()
  $pwOk = $false
  try { $pwOk = [MiPhone.Native]::PrintWindow($parent, $hdc, 2) }
  finally { $g.ReleaseHdc($hdc); $g.Dispose() }
  if (-not $pwOk) { $windowBmp.Dispose(); throw 'PrintWindow failed' }

  $client = Get-ClientInfo $child
  if ($client.W -le 0 -or $client.H -le 0) { $windowBmp.Dispose(); throw 'invalid client rect' }
  $frame = New-Object System.Drawing.Bitmap($client.W, $client.H)
  $fg = [System.Drawing.Graphics]::FromImage($frame)
  try {
    $fg.Clear([System.Drawing.Color]::Black)
    $cx = $client.X - $wr.Left
    $cy = $client.Y - $wr.Top
    $sx = [math]::Max(0, $cx)
    $sy = [math]::Max(0, $cy)
    $sw = [math]::Min($client.W, $ww - $sx)
    $sh = [math]::Min($client.H, $wh - $sy)
    if ($sw -gt 0 -and $sh -gt 0) {
      $dstX = $sx - $cx
      $dstY = $sy - $cy
      $dstRect = New-Object System.Drawing.Rectangle($dstX, $dstY, $sw, $sh)
      $srcRect = New-Object System.Drawing.Rectangle($sx, $sy, $sw, $sh)
      $fg.DrawImage($windowBmp, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
    }
  } finally { $fg.Dispose(); $windowBmp.Dispose() }
  return $frame
}

# 把百分比 region 换算成像素矩形；小于最小裁剪尺寸时保持中心扩展并限制在画面内。
function Resolve-RegionRect([int]$screenW, [int]$screenH, $regionPct, [int]$minW = 160, [int]$minH = 120) {
  $rx = [int][math]::Floor($screenW * [double]$regionPct[0] / 100.0)
  $ry = [int][math]::Floor($screenH * [double]$regionPct[1] / 100.0)
  $rw = [int][math]::Ceiling($screenW * [double]$regionPct[2] / 100.0)
  $rh = [int][math]::Ceiling($screenH * [double]$regionPct[3] / 100.0)
  if ($rw -lt 1) { $rw = 1 }
  if ($rh -lt 1) { $rh = 1 }
  if ($rx -lt 0) { $rx = 0 }
  if ($ry -lt 0) { $ry = 0 }
  if ($rx -ge $screenW) { $rx = $screenW - 1 }
  if ($ry -ge $screenH) { $ry = $screenH - 1 }
  if ($rx + $rw -gt $screenW) { $rw = $screenW - $rx }
  if ($ry + $rh -gt $screenH) { $rh = $screenH - $ry }

  if ($rw -lt $minW -and $screenW -ge $minW) {
    $cx = $rx + [int][math]::Round($rw / 2.0)
    $rw = $minW
    $rx = $cx - [int][math]::Round($rw / 2.0)
    if ($rx -lt 0) { $rx = 0 }
    if ($rx + $rw -gt $screenW) { $rx = $screenW - $rw }
  }
  if ($rh -lt $minH -and $screenH -ge $minH) {
    $cy = $ry + [int][math]::Round($rh / 2.0)
    $rh = $minH
    $ry = $cy - [int][math]::Round($rh / 2.0)
    if ($ry -lt 0) { $ry = 0 }
    if ($ry + $rh -gt $screenH) { $ry = $screenH - $rh }
  }
  return @{ X = $rx; Y = $ry; W = $rw; H = $rh }
}

function Get-BlankStats($bmp) {
  $out = @{}
  try {
    $stepX = [math]::Max(1, [int]($bmp.Width / 96))
    $stepY = [math]::Max(1, [int]($bmp.Height / 96))
    $colors = New-Object 'System.Collections.Generic.HashSet[string]'
    $colorCount = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    $sum = 0.0; $sum2 = 0.0; $n = 0; $darkCount = 0
    for ($sy = 0; $sy -lt $bmp.Height; $sy += $stepY) {
      for ($sx = 0; $sx -lt $bmp.Width; $sx += $stepX) {
        $c = $bmp.GetPixel($sx, $sy)
        $v = ($c.R + $c.G + $c.B) / 3.0
        $sum += $v; $sum2 += $v * $v; $n++
        $key = "$([int]($c.R / 16)):$([int]($c.G / 16)):$([int]($c.B / 16))"
        [void]$colors.Add($key)
        if ($colorCount.ContainsKey($key)) { $colorCount[$key]++ } else { $colorCount[$key] = 1 }
        if ($c.R -lt 60 -and $c.G -lt 60 -and $c.B -lt 60) { $darkCount++ }
      }
    }
    if ($n -gt 0) {
      $mean = $sum / $n
      $sd = [math]::Sqrt([math]::Max(0.0, ($sum2 / $n) - ($mean * $mean)))
      $top = 0
      foreach ($kv in $colorCount.GetEnumerator()) { if ($kv.Value -gt $top) { $top = $kv.Value } }
      $out.colors = $colors.Count
      $out.dominant = [math]::Round([double]$top / [double]$n, 3)
      $out.stdev = [math]::Round($sd, 2)
      $out.dark = [math]::Round($darkCount / [double]$n, 4)
    }
  } catch { }
  return $out
}

# 单次截图：返回展示图（可带标尺）+ 原始整帧（可选落盘）。
# 关键约定：result.w/h 是「截图内容图」的实际像素尺寸；展示图尺寸是 imageW/imageH；
# contentBox 是内容在展示图中的位置 [left, top, right, bottom]。
function Invoke-Capture($target, [string]$out = '', [string]$prev = '', $region = $null, [int]$maxWidth = 0, [string]$rawOut = '', [bool]$drawRuler = $false, [int]$gridStep = 10, [string]$rulerTheme = 'light', $preFrame = $null) {
  $ownFull = $false
  if ($null -ne $preFrame) {
    $full = $preFrame
  } else {
    $full = Get-FullFrameBitmap $target
    $ownFull = $true
  }
  try {
    $screenW = $full.Width
    $screenH = $full.Height
    $hash = [MiPhone.Img]::Hash($full)
    $frameId = (Get-Date).ToString('yyyyMMddTHHmmssfff') + "-${screenW}x${screenH}"

    if ($rawOut) {
      $rawDir = Split-Path -Parent $rawOut
      if ($rawDir -and -not (Test-Path $rawDir)) { New-Item -ItemType Directory -Path $rawDir -Force | Out-Null }
      $full.Save($rawOut, [System.Drawing.Imaging.ImageFormat]::Png)
    }

    $result = @{
      w = $screenW; h = $screenH
      screen = @{ w = $screenW; h = $screenH }
      expectedS = @($screenW, $screenH)
      frameId = $frameId
      hash = $hash
      changed = $true
      box = $null
      ruled = $drawRuler
      orientation = $(if ($screenH -ge $screenW) { 'portrait' } else { 'landscape' })
    }

    $content = $full
    $x0 = 0.0; $x1 = 100.0; $y0 = 0.0; $y1 = 100.0
    $regionInfo = $null
    if ($null -ne $region -and $region.Count -eq 4) {
      $rect = Resolve-RegionRect $screenW $screenH $region
      $content = $full.Clone((New-Object System.Drawing.Rectangle($rect.X, $rect.Y, $rect.W, $rect.H)), $full.PixelFormat)
      $x0 = $rect.X * 100.0 / $screenW
      $x1 = ($rect.X + $rect.W) * 100.0 / $screenW
      $y0 = $rect.Y * 100.0 / $screenH
      $y1 = ($rect.Y + $rect.H) * 100.0 / $screenH
      $regionInfo = @{
        px = @($rect.X, $rect.Y, $rect.W, $rect.H)
        pct = @(
          [math]::Round($x0, 2), [math]::Round($y0, 2),
          [math]::Round($x1 - $x0, 2), [math]::Round($y1 - $y0, 2)
        )
      }
    }

    # 等比缩小只作用于「内容」，缩放后再画标尺，保证标签不会跟着糊掉。
    if ($maxWidth -gt 0 -and $content.Width -gt $maxWidth) {
      $ratio = $maxWidth / [double]$content.Width
      $nw = [int][math]::Round($content.Width * $ratio)
      $nh = [int][math]::Round($content.Height * $ratio)
      $small = New-Object System.Drawing.Bitmap($nw, $nh)
      $sg = [System.Drawing.Graphics]::FromImage($small)
      $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $sg.DrawImage($content, 0, 0, $nw, $nh)
      $sg.Dispose()
      if (-not [object]::ReferenceEquals($content, $full)) { $content.Dispose() }
      $content = $small
      # 缩放后 s 按文档要求改为展示内容尺寸；百分比不变。
      $result.w = $nw; $result.h = $nh
      $result.screen = @{ w = $nw; h = $nh }
      $result.expectedS = @($nw, $nh)
    }

    $display = $content
    $rr = $null
    if ($drawRuler) {
      $rr = [MiPhone.Ruler]::Draw($content, $x0, $x1, $y0, $y1, $result.w, $result.h, $gridStep, $rulerTheme)
      $display = $rr.Image
      $result.contentBox = @($rr.MarginPx, $rr.MarginPx, ($rr.MarginPx + $content.Width), ($rr.MarginPx + $content.Height))
      $result.grid = @{
        style = 'ruler'; step = $rr.Step; minor = $rr.Minor; labels = 'percent'
        marginPx = $rr.MarginPx; fontPx = $rr.FontPx; theme = $rr.Theme
      }
      $result.out = @($display.Width, $display.Height)
    } else {
      $result.contentBox = @(0, 0, $content.Width, $content.Height)
      $result.out = @($content.Width, $content.Height)
      $result.grid = @{ style = 'off' }
    }
    $result.imageW = $display.Width
    $result.imageH = $display.Height

    $stats = Get-BlankStats $full
    foreach ($k in $stats.Keys) { $result[$k] = $stats[$k] }

    if ($prev -and (Test-Path $prev)) {
      try {
        $prevBmp = [System.Drawing.Bitmap]::FromFile($prev)
        try {
          if ($prevBmp.Width -eq $screenW -and $prevBmp.Height -eq $screenH) {
            $ds = [MiPhone.ImgStats]::DiffStats($prevBmp, $full, 16, 6, 6, 32)
            if ($null -ne $ds) {
              $pad = 6
              $l = [math]::Max(0, $ds.MinX - $pad)
              $t = [math]::Max(0, $ds.MinY - $pad)
              $r = [math]::Min($screenW, $ds.MaxX + $pad)
              $b = [math]::Min($screenH, $ds.MaxY + $pad)
              if ($ds.ChangedBlocks -gt 0) {
                $result.changeBoxPx = @($l, $t, $r, $b)
                $result.changeBoxPct = @(
                  [math]::Round($l * 100.0 / $screenW, 2), [math]::Round($t * 100.0 / $screenH, 2),
                  [math]::Round($r * 100.0 / $screenW, 2), [math]::Round($b * 100.0 / $screenH, 2)
                )
                $result.box = @($l, $t, ($r - $l), ($b - $t))
              }
              $result.blocks = $ds.ChangedBlocks
              $result.clusters = $ds.ClusterCount
              $result.ratio = [math]::Round($ds.ChangeRatio, 4)
              $result.diffPx = $ds.ChangedPixels
              $result.headerRatio = [math]::Round($ds.HeaderRatio, 4)
              $result.changed = ($ds.ChangedBlocks -ge 1) -or ($ds.ChangeRatio -ge 0.001)
              if (-not $result.changed) { $result.note = '画面未变化' }
            }
          }
        } finally { $prevBmp.Dispose() }
      } catch { $result.note = 'diff-failed' }
    }

    if ($out) {
      $dir = Split-Path -Parent $out
      if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      $display.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
      $result.path = $out
    }
    if ($rawOut) { $result.rawPath = $rawOut }
    if ($regionInfo) { $result.region = $regionInfo; $result.coordSpace = 'screen' }

    if ($rr -and -not [object]::ReferenceEquals($display, $content)) { $display.Dispose() }
    if (-not [object]::ReferenceEquals($content, $full)) { $content.Dispose() }
    return $result
  } finally {
    if ($ownFull) { $full.Dispose() }
  }
}

# 在两张无标尺原图里比一块百分比区域。返回 hit（按块容差，抗视频噪声）与 diffPx（精确像素差异）。
# verify 固定走这个函数，输入必须是 raw 截图，绝不带标尺。
function Get-RegionDiff([string]$a, [string]$b, $rectPct, $client) {
  if (-not $a -or -not $b -or -not (Test-Path $a) -or -not (Test-Path $b)) { return $null }
  $ba = [System.Drawing.Bitmap]::FromFile($a)
  $bb = [System.Drawing.Bitmap]::FromFile($b)
  try {
    if ($ba.Width -ne $bb.Width -or $ba.Height -ne $bb.Height) { return @{ hit = $false; diffPx = -1; note = 'size-mismatch' } }
    $rx = [int][math]::Floor($client.W * $rectPct[0] / 100.0)
    $ry = [int][math]::Floor($client.H * $rectPct[1] / 100.0)
    $rw = [int][math]::Ceiling($client.W * $rectPct[2] / 100.0)
    $rh = [int][math]::Ceiling($client.H * $rectPct[3] / 100.0)
    if ($rx -lt 0) { $rx = 0 }
    if ($ry -lt 0) { $ry = 0 }
    if ($rx + $rw -gt $ba.Width) { $rw = $ba.Width - $rx }
    if ($ry + $rh -gt $ba.Height) { $rh = $ba.Height - $ry }
    if ($rw -le 2 -or $rh -le 2) { return @{ hit = $false; diffPx = 0; ratio = 0.0 } }
    $rect = New-Object System.Drawing.Rectangle($rx, $ry, $rw, $rh)
    $ca = $ba.Clone($rect, $ba.PixelFormat)
    $cb = $bb.Clone($rect, $bb.PixelFormat)
    try {
      $box = [MiPhone.Img]::DiffBox($ca, $cb, 8, 12, 0.06)
      $ds = [MiPhone.ImgStats]::RegionDiff($ba, $bb, $rx, $ry, $rw, $rh, 12)
      $diffPx = 0
      $ratio = 0.0
      if ($null -ne $ds) { $diffPx = $ds.ChangedPixels; $ratio = $ds.ChangeRatio }
      return @{ hit = ($null -ne $box); diffPx = $diffPx; ratio = [math]::Round($ratio, 5) }
    } finally { $ca.Dispose(); $cb.Dispose() }
  } finally { $ba.Dispose(); $bb.Dispose() }
}

function Test-RegionChanged([string]$a, [string]$b, $rectPct, $client) {
  $r = Get-RegionDiff $a $b $rectPct $client
  if ($null -eq $r) { return $null }
  return [bool]$r.hit
}

# 滚动是否产生有效变化：比整帧中央区域（屏蔽顶部 8% / 底部 8% 的手势与状态区）。
function Get-ScrollDiff([string]$a, [string]$b) {
  if (-not $a -or -not $b -or -not (Test-Path $a) -or -not (Test-Path $b)) { return $null }
  $ba = [System.Drawing.Bitmap]::FromFile($a)
  $bb = [System.Drawing.Bitmap]::FromFile($b)
  try {
    if ($ba.Width -ne $bb.Width -or $ba.Height -ne $bb.Height) { return @{ changed = $true; diffPx = -1; ratio = 1.0; note = 'size-mismatch' } }
    $ds = [MiPhone.ImgStats]::DiffStats($ba, $bb, 16, 8, 8, 24)
    if ($null -eq $ds) { return $null }
    $changed = ($ds.ChangedPixels -ge 80) -and ($ds.ChangeRatio -ge 0.0008)
    return @{ changed = $changed; diffPx = $ds.ChangedPixels; ratio = [math]::Round($ds.ChangeRatio, 5); blocks = $ds.ChangedBlocks }
  } finally { $ba.Dispose(); $bb.Dispose() }
}

# ---------------------------------------------------------------------------
# 关键帧状态（modelBaseline = 模型最近一次实际收到的整屏图）
# ---------------------------------------------------------------------------
function Get-ViewStatePath { return (Join-Path (Join-Path $env:TEMP 'dsh-phone-use') 'view-state.json') }
function Get-BaselinePath { return (Join-Path (Join-Path $env:TEMP 'dsh-phone-use') 'baseline.png') }

function Read-ViewState {
  $st = @{ opsSinceFull = 0; baselineMeta = $null; lastFrame = $null }
  $p = Get-ViewStatePath
  if (Test-Path -LiteralPath $p) {
    try {
      $o = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($null -ne $o.opsSinceFull) { $st.opsSinceFull = [int]$o.opsSinceFull }
      if ($null -ne $o.baselineMeta) { $st.baselineMeta = $o.baselineMeta }
      if ($null -ne $o.lastFrame) { $st.lastFrame = $o.lastFrame }
    } catch { }
  }
  return $st
}

function Save-ViewState($state) {
  try {
    $dir = Join-Path $env:TEMP 'dsh-phone-use'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $state | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText((Get-ViewStatePath), $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

function Reset-ViewBaseline {
  try { if (Test-Path (Get-BaselinePath)) { Remove-Item (Get-BaselinePath) -Force -ErrorAction SilentlyContinue } } catch { }
  Save-ViewState @{ opsSinceFull = 0; baselineMeta = $null; lastFrame = $null }
}

function Add-ViewOps([int]$n) {
  if ($n -le 0) { return }
  $st = Read-ViewState
  $st.opsSinceFull = [int]$st.opsSinceFull + $n
  Save-ViewState $st
}

function Get-Orientation([int]$w, [int]$h) { if ($h -ge $w) { return 'portrait' } else { return 'landscape' } }

# 关键帧策略：决定这次回全屏还是区域图，并在「模型实际收到整屏」时更新 baseline。
# req.mode: auto | full | region；req.commit 表示这张图是否真的会交给模型。
function Invoke-SmartCapture($target, $req) {
  $mode = [string]$req.mode
  if ($mode -ne 'full' -and $mode -ne 'region' -and $mode -ne 'auto') { $mode = 'auto' }
  $out = [string]$req.out
  if (-not $out) { $out = Join-Path (Join-Path $env:TEMP 'dsh-phone-use') 'smart-view.png' }
  $rawOut = [string]$req.rawOut
  $opsDelta = 0
  if ($null -ne $req.opsDelta) { $opsDelta = [int]$req.opsDelta }
  $commit = $true
  if ($null -ne $req.commit) { $commit = [bool]$req.commit }
  $gridOn = $true
  if ([string]$req.grid -eq 'off') { $gridOn = $false }
  $gridStep = 10
  if ([string]$req.gridStep -eq '5') { $gridStep = 5 }
  $theme = [string]$req.rulerTheme
  if ($theme -ne 'dark' -and $theme -ne 'auto') { $theme = 'light' }

  $full = Get-FullFrameBitmap $target
  try {
    $screenW = $full.Width
    $screenH = $full.Height
    $title = [MiPhone.Native]::TitleOf($target.Parent)
    $state = Read-ViewState
    $baselinePath = Get-BaselinePath
    $baselineBmp = $null
    $stats = $null
    try {
      if (Test-Path -LiteralPath $baselinePath) {
        $baselineBmp = [System.Drawing.Bitmap]::FromFile($baselinePath)
        if ($baselineBmp.Width -eq $screenW -and $baselineBmp.Height -eq $screenH) {
          $stats = [MiPhone.ImgStats]::DiffStats($baselineBmp, $full, 16, 6, 6, 32)
        }
      }
    } catch { $stats = $null }

    $reason = ''
    $dimensionChanged = $false
    $baselineMeta = $state.baselineMeta
    $baseS = $null
    if ($null -ne $baselineMeta -and $null -ne $baselineMeta.s) { $baseS = @($baselineMeta.s) }

    if ($mode -eq 'full') {
      $reason = 'explicit-full'
    } elseif ($mode -eq 'region') {
      $reason = 'explicit-region'
    } else {
      if ($null -eq $baselineBmp) { $mode = 'full'; $reason = 'first' }
      elseif ($baselineBmp.Width -ne $screenW -or $baselineBmp.Height -ne $screenH) {
        $mode = 'full'; $reason = 'size-changed'; $dimensionChanged = $true
      } elseif ($null -ne $baseS -and ([int]$baseS[0] -ne $screenW -or [int]$baseS[1] -ne $screenH)) {
        $mode = 'full'; $reason = 'size-changed'; $dimensionChanged = $true
      } elseif ($null -ne $baseS -and ((Get-Orientation ([int]$baseS[0]) ([int]$baseS[1])) -ne (Get-Orientation $screenW $screenH))) {
        $mode = 'full'; $reason = 'orientation-changed'; $dimensionChanged = $true
      } elseif ($null -ne $baselineMeta -and $baselineMeta.title -and ([string]$baselineMeta.title -ne $title)) {
        $mode = 'full'; $reason = 'title-changed'
      } elseif ($null -eq $stats) {
        $mode = 'full'; $reason = 'diff-failed'
      } elseif ($stats.ChangeRatio -ge 0.30) {
        $mode = 'full'; $reason = 'diff-large'
      } elseif ($null -ne $stats -and $stats.ClusterCount -ge 3) {
        $mode = 'full'; $reason = 'multi-region'
      } elseif ($null -ne $stats -and $stats.HeaderRatio -ge 0.50) {
        $mode = 'full'; $reason = 'title-band-changed'
      } elseif (([int]$state.opsSinceFull + $opsDelta) -ge 8) {
        $mode = 'full'; $reason = 'ops-threshold'
      } else {
        $mode = 'region'
        if ($null -ne $stats -and $stats.ChangedBlocks -gt 0) { $reason = 'local-change' } else { $reason = 'no-change' }
      }
    }

    # 区域模式：显式 region 直接用；自动模式按变化框扩上下文 -> 最小 160×120 -> 百分比。
    $regionPct = $null
    if ($mode -eq 'region') {
      if ($null -ne $req.region -and @($req.region).Count -eq 4) {
        $regionPct = @($req.region)
      } else {
        if ($null -eq $stats -or $stats.ChangedBlocks -le 0) {
          $hash = [MiPhone.Img]::Hash($full)
          $frameId = (Get-Date).ToString('yyyyMMddTHHmmssfff') + "-${screenW}x${screenH}"
          $result = @{
            w = $screenW; h = $screenH; screen = @{ w = $screenW; h = $screenH }
            expectedS = @($screenW, $screenH); frameId = $frameId; hash = $hash
            changed = $false; mode = 'region'; reason = 'no-change'; ruled = $gridOn
            orientation = (Get-Orientation $screenW $screenH); changeBoxPx = $null; changeBoxPct = $null
            out = @($screenW, $screenH); contentBox = @(0, 0, $screenW, $screenH); grid = @{ style = $(if ($gridOn) { 'ruler' } else { 'off' }) }
          }
          if ($rawOut) {
            try {
              $rawDir = Split-Path -Parent $rawOut
              if ($rawDir -and -not (Test-Path $rawDir)) { New-Item -ItemType Directory -Path $rawDir -Force | Out-Null }
              $full.Save($rawOut, [System.Drawing.Imaging.ImageFormat]::Png)
              $result.rawPath = $rawOut
            } catch { }
          }
          $state.lastFrame = @{ frameId = $frameId; s = @($screenW, $screenH); title = $title; ts = (Get-Date).ToString('o'); orientation = $result.orientation }
          $state.opsSinceFull = [int]$state.opsSinceFull + $opsDelta
          Save-ViewState $state
          return $result
        }
        $bw = $stats.MaxX - $stats.MinX + 1
        $bh = $stats.MaxY - $stats.MinY + 1
        $pad = [int][math]::Max(16, [math]::Max([math]::Round($bw * 0.15), [math]::Round($bh * 0.15)))
        $l = [math]::Max(0, $stats.MinX - $pad)
        $t = [math]::Max(0, $stats.MinY - $pad)
        $r = [math]::Min($screenW, $stats.MaxX + $pad)
        $b = [math]::Min($screenH, $stats.MaxY + $pad)
        # 变化区横跨画面宽度 60% 以上时，区域图直接使用全宽，避免把整行文字裁半。
        if (($r - $l) -ge ($screenW * 0.60)) { $l = 0; $r = $screenW }
        $regionPct = @(
          ($l * 100.0 / $screenW), ($t * 100.0 / $screenH),
          (($r - $l) * 100.0 / $screenW), (($b - $t) * 100.0 / $screenH)
        )
      }
    }

    $img = Invoke-Capture $target $out $baselinePath $regionPct 0 $rawOut $gridOn $gridStep $theme $full
    $img.mode = $mode
    $img.reason = $reason
    $img.dimensionChanged = $dimensionChanged
    if ($mode -eq 'full' -and $null -eq $img.changeBoxPx) {
      $img.changeBoxPx = @(0, 0, $screenW, $screenH)
      $img.changeBoxPct = @(0, 0, 100, 100)
    }
    if ($null -ne $stats) {
      $img.diffRatio = [math]::Round($stats.ChangeRatio, 4)
      $img.diffPx = $stats.ChangedPixels
      $img.clusters = $stats.ClusterCount
      $img.headerRatio = [math]::Round($stats.HeaderRatio, 4)
    }
    if ($mode -eq 'region' -and $null -eq $img.changeBoxPx -and $null -ne $stats -and $stats.ChangedBlocks -gt 0) {
      $pad = 6
      $l = [math]::Max(0, $stats.MinX - $pad); $t = [math]::Max(0, $stats.MinY - $pad)
      $r = [math]::Min($screenW, $stats.MaxX + $pad); $b = [math]::Min($screenH, $stats.MaxY + $pad)
      $img.changeBoxPx = @($l, $t, $r, $b)
      $img.changeBoxPct = @(
        [math]::Round($l * 100.0 / $screenW, 2), [math]::Round($t * 100.0 / $screenH, 2),
        [math]::Round($r * 100.0 / $screenW, 2), [math]::Round($b * 100.0 / $screenH, 2)
      )
    }

    if ($mode -eq 'full' -and $commit) {
      # 先释放上一帧 baseline（Bitmap 从文件加载会锁住文件），否则 Save 永远失败，
      # 表现就是 modelBaseline 一直停在旧画面、每次都被判成 diff-large。
      if ($null -ne $baselineBmp) { $baselineBmp.Dispose(); $baselineBmp = $null }
      try { $full.Save($baselinePath, [System.Drawing.Imaging.ImageFormat]::Png) } catch { }
      $state.baselineMeta = @{
        s = @($screenW, $screenH); frameId = $img.frameId; title = $title
        ts = (Get-Date).ToString('o'); orientation = (Get-Orientation $screenW $screenH)
      }
      $state.opsSinceFull = 0
      $img.baselineUpdated = $true
    } else {
      $state.opsSinceFull = [int]$state.opsSinceFull + $opsDelta
      $img.baselineUpdated = $false
    }
    $state.lastFrame = @{ frameId = $img.frameId; s = @($screenW, $screenH); title = $title; ts = (Get-Date).ToString('o'); orientation = (Get-Orientation $screenW $screenH) }
    Save-ViewState $state
    return $img
  } finally {
    if ($null -ne $baselineBmp) { $baselineBmp.Dispose() }
    $full.Dispose()
  }
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
  # 用真实时钟推进，而不是"步数 × 固定睡眠"。
  # Start-Sleep 在 Windows 上最小粒度约 15.6ms，实际常睡 20-30ms，
  # 若按步数算时间，总耗时会膨胀 2-3 倍，画面表现为卡顿抽搐。
  # 这里每步按"已流逝时间"反算位置，保证整体时长贴合 ms，轨迹均匀。
  $lp = New-LParam $x1 $y1
  [void][MiPhone.Native]::SendMessage($child, 0x0200, [IntPtr]::Zero, $lp)
  [void][MiPhone.Native]::SendMessage($child, 0x0201, [IntPtr]1, $lp)

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $lastX = $x1; $lastY = $y1
  while ($true) {
    $elapsed = $sw.Elapsed.TotalMilliseconds
    $t = $elapsed / [double]$ms
    if ($t -ge 1.0) { break }
    $mx = [int][math]::Round($x1 + ($x2 - $x1) * $t)
    $my = [int][math]::Round($y1 + ($y2 - $y1) * $t)
    # 位置没变就不重复发消息，减少无谓的远端处理
    if ($mx -ne $lastX -or $my -ne $lastY) {
      [void][MiPhone.Native]::SendMessage($child, 0x0200, [IntPtr]1, (New-LParam $mx $my))
      $lastX = $mx; $lastY = $my
    }
    Start-Sleep -Milliseconds 8
  }
  [void][MiPhone.Native]::SendMessage($child, 0x0200, [IntPtr]1, (New-LParam $x2 $y2))
  [void][MiPhone.Native]::SendMessage($child, 0x0202, [IntPtr]::Zero, (New-LParam $x2 $y2))
  $sw.Stop()
}
# ---- 小米互联手势组件 ----
# 从屏幕顶端边缘往下拉：左侧 = 通知栏，右侧 = 控制中心（主人实测）。
# 起点必须贴边（y 约 1%），否则会被面板里的卡片组件吃掉，变成普通拖动。
# 中途不松手、匀速下滑，让系统识别成下拉手势而不是点击。
function Invoke-PanelPull($target, [string]$side) {
  $client = Get-ClientInfo $target.Child
  $w = $client.W; $h = $client.H
  if ($w -le 0 -or $h -le 0) { return $false }
  $xPct = 25.0
  if ($side -eq 'control') { $xPct = 75.0 }
  $x = [int][math]::Round($w * $xPct / 100.0)
  $y1 = [int][math]::Round($h * 0.8 / 100.0)    # 贴住顶端边缘
  $y2 = [int][math]::Round($h * 55.0 / 100.0)   # 拉到屏幕中部，足够展开面板
  Invoke-Swipe $target $x $y1 $x $y2 400
  return $true
}

# 返回手势：从右边缘往左滑（主人实测可用）。参数 99% → 60%、300ms 稳定触发。
# 用于关闭通知栏/控制中心、或 App 内返回上一页。
function Invoke-BackGesture($target) {
  $client = Get-ClientInfo $target.Child
  $w = $client.W; $h = $client.H
  if ($w -le 0 -or $h -le 0) { return $false }
  $y = [int][math]::Round($h * 50.0 / 100.0)
  $x1 = [int][math]::Round($w * 99.0 / 100.0)
  $x2 = [int][math]::Round($w * 60.0 / 100.0)
  Invoke-Swipe $target $x1 $y $x2 $y 300
  return $true
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

# 后台滚轮：1 格 = 120 delta；up 正、down 负。只发窗口消息，不移动真实鼠标。
function Invoke-Wheel($target, [string]$direction, [int]$notches, [string]$at, [bool]$screenCoords = $true) {
  $child = $target.Child
  $client = Get-ClientInfo $child
  if ([string]::IsNullOrEmpty($at)) { $at = '50,50' }
  $pt = ConvertTo-Point $at $client
  if ($notches -lt 1) { $notches = 1 }
  if ($notches -gt 20) { $notches = 20 }
  $delta = 120
  if ($direction -eq 'down') { $delta = -120 }
  # 先投递 MOVE 让远端知道滚轮作用点（仍为后台窗口消息）
  [void][MiPhone.Native]::SendMessage($child, 0x0200, [IntPtr]::Zero, (New-LParam $pt[0] $pt[1]))
  Start-Sleep -Milliseconds 25
  for ($i = 0; $i -lt $notches; $i++) {
    [MiPhone.Native]::SendWheel($child, $delta, $pt[0], $pt[1], $screenCoords)
    Start-Sleep -Milliseconds 35
  }
  return @{ direction = $direction; notches = $notches; at = $at; px = $pt; screenCoords = $screenCoords }
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
  # 主人实测：长按太短会退化成普通点击、菜单不弹；默认 1200ms。
  if ($holdMs -le 0) { $holdMs = 1200 }
  $shotDir = Join-Path $env:TEMP 'dsh-phone-use'
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
      return (Invoke-OpenMenu $target $at 0 $text)   # 0 = 用默认长按时长（1200ms）
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
  # 主人实测：长按太短会退化成普通点击、菜单不弹；默认 1200ms。
  if ($holdMs -le 0) { $holdMs = 1200 }
  $shotDir = Join-Path $env:TEMP 'dsh-phone-use'
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
    # 等互联把剪贴板同步到手机，否则菜单里不会出现「粘贴」。主人实测不到 1 秒即可，留 1.5s 余量。
    Start-Sleep -Milliseconds 1500
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

# 用 Windows 内置 OCR（zh-Hans）读画面文字。
# 主人实测：投屏画面里的「正在连接...」「手机解锁」「加载失败」字体够大，识别准确；
# 之前判定 OCR 无效是因为当时字体只有 16px 且画面模糊。
# 真实手机画面（桌面/视频/App）OCR 出来是噪声或普通内容，不会命中这些关键词。
# 自检：是否装了简体中文 OCR 语言包。
# 没装的话页面状态判断会退化（无法区分连接页/失败页/解锁页），唤起功能受限。
function Test-OcrAvailable {
  try {
    if (-not $script:OcrProbeDone) {
      Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
      $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
      $null = [Windows.Globalization.Language, Windows.Foundation, ContentType=WindowsRuntime]
      $lang = New-Object Windows.Globalization.Language 'zh-Hans-CN'
      $script:OcrProbeEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
      $script:OcrProbeDone = $true
    }
    return ($null -ne $script:OcrProbeEngine)
  } catch {
    $script:OcrProbeDone = $true
    $script:OcrProbeEngine = $null
    return $false
  }
}

# 返回给调用方的提示：没装中文 OCR 时说明会受限。
# 缺 OCR 语言包时返回结构化缺失信息给 AI（只说缺什么，处置由 AI 决定并转告主人）。
function Get-OcrHint {
  if (Test-OcrAvailable) { return $null }
  return @{
    code = 'ocr-language-missing'
    missing = '简体中文 OCR 语言包（zh-Hans-CN）'
    impact = '无法读取投屏画面上的文字，因此分不清「连接中 / 待解锁 / 连接失败」这三种占位页'
    degraded = @('phone_wake 的页面判定', 'phone_panel 后无法确认面板类型')
    where = 'Windows 设置 → 时间和语言 → 语言和区域 → 添加语言 → 中文(简体) → 勾选「光学字符识别」'
  }
}

function Get-SurfaceOcrText([string]$imagePath) {
  if (-not $imagePath -or -not (Test-Path -LiteralPath $imagePath)) { return $null }
  try {
    if (-not $script:OcrReady) {
      Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
      $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
      })[0]
      $script:OcrAsTask = $asTask
      $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
      $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
      $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType=WindowsRuntime]
      $null = [Windows.Globalization.Language, Windows.Foundation, ContentType=WindowsRuntime]
      $lang = New-Object Windows.Globalization.Language 'zh-Hans-CN'
      $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
      if (-not $script:OcrEngine) { $script:OcrReady = $false; return $null }
      $script:OcrReady = $true
    }
    if (-not $script:OcrEngine) { return $null }

    $await = {
      param($op, $type)
      $t = $script:OcrAsTask.MakeGenericMethod($type).Invoke($null, @($op))
      $t.Wait(-1) | Out-Null
      $t.Result
    }
    $file = & $await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($imagePath)) ([Windows.Storage.StorageFile])
    $stream = & $await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
      $decoder = & $await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
      $bitmap = & $await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
      $result = & $await ($script:OcrEngine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
      # 去掉所有空白，中文常被识别成「正 在 连 接」
      return (($result.Text -replace '\s+',''))
    } finally { $stream.Dispose() }
  } catch {
    return $null
  }
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

# 采样一帧画面，返回纯色统计（-Ocr 时才读文字）。
# 这里只负责"读"，不负责"判"——判定在 Invoke-Wake 里按 纯色 → 动态 → OCR 的顺序做。
# OCR 要 1 秒多，只在确认"静止占位页"时才值得跑，所以默认关掉。
function Get-SurfaceStats($target, [bool]$WantOcr = $false) {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mi-surface-' + [guid]::NewGuid().ToString('N') + '.png')
  try {
    $null = Invoke-Capture $target $tmp $null $null 0
    if (-not (Test-Path -LiteralPath $tmp)) { return $null }
    $bmp = [System.Drawing.Bitmap]::FromFile($tmp)
    try {
      $stepX = [math]::Max(1, [int]($bmp.Width / 96))
      $stepY = [math]::Max(1, [int]($bmp.Height / 96))
      $colorCount = New-Object 'System.Collections.Generic.Dictionary[string,int]'
      $sum = 0.0; $sum2 = 0.0; $n = 0; $darkCount = 0

      for ($y = 0; $y -lt $bmp.Height; $y += $stepY) {
        for ($x = 0; $x -lt $bmp.Width; $x += $stepX) {
          $c = $bmp.GetPixel($x, $y)
          $v = ($c.R + $c.G + $c.B) / 3.0
          $sum += $v; $sum2 += $v * $v; $n++
          $key = "$([int]($c.R / 16)):$([int]($c.G / 16)):$([int]($c.B / 16))"
          if ($colorCount.ContainsKey($key)) { $colorCount[$key]++ } else { $colorCount[$key] = 1 }
          if ($c.R -lt 60 -and $c.G -lt 60 -and $c.B -lt 60) { $darkCount++ }
        }
      }
      if ($n -eq 0) { return $null }
      $mean = $sum / $n
      $sd = [math]::Sqrt([math]::Max(0.0, ($sum2 / $n) - ($mean * $mean)))
      $top = 0
      foreach ($kv in $colorCount.GetEnumerator()) { if ($kv.Value -gt $top) { $top = $kv.Value } }
      $dominant = [double]$top / [double]$n
      $darkRatio = $darkCount / [double]$n
      # 占位页：单一主色占满 或 整屏过暗。
      # 实测连接中 0.974 / 待解锁 0.963 / 连接失败 0.968，真实画面 0.389~0.824。
      $isBlank = (($dominant -ge 0.94) -or ($darkRatio -ge 0.60))
      # OCR 要 1 秒多，只在"确认是占位页 + 调用方明确要文字"时才跑。
      $ocr = $null
      if ($WantOcr -and $isBlank) { $ocr = Get-SurfaceOcrText $tmp }
      return @{
        colors   = $colorCount.Count
        mean     = [math]::Round($mean, 1)
        stdev    = [math]::Round($sd, 2)
        dominant = [math]::Round($dominant, 3)
        dark     = [math]::Round($darkRatio, 4)
        blank    = $isBlank
        hash     = [MiPhone.Img]::Hash($bmp)
        ocr      = $ocr
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
  # 每次唤起/重连都重置关键帧：模型必须重新看到一张整屏图。
  Reset-ViewBaseline
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

  # 2) 唤起顺序（主人实测有效）：先确保「妙享桌面」(MiSmartShareHandoff) 在运行，
  #    再启动「跨屏协作」(MiScreenShare)，投屏握手才完整、画面才渲染得出来。
  #    ⚠ 妙享桌面是常驻程序，通常一直最小化在任务栏 —— 绝不能杀掉它，也不要重复启动它。
  #    缺了它、只孤立启动 MiScreenShare，画面会一直停在「正在连接」，最后报失败。
  $mgrPid = 0
  try {
    $m = Get-Process -Name 'XiaomiPcManager' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { $mgrPid = [int]$m.Id }
  } catch { }

  # 2a) 先妙享桌面：不存在才启动（存在就沿用，不动它）
  $handoffRunning = $null -ne (Get-Process -Name 'MiSmartShareHandoff' -ErrorAction SilentlyContinue | Select-Object -First 1)
  if (-not $handoffRunning) {
    $hoExe = Resolve-ScreenShareExecutable 'MiSmartShareHandoff.exe'
    if ($hoExe) {
      $hoArgs = @("--CastBusinessType=`"1`"")
      try {
        $cmdLine = '"' + $hoExe + '" ' + ($hoArgs -join ' ')
        $spawnResult = $null
        if ($mgrPid -gt 0) {
          # 以管家为父进程启动：子进程能继承管家的管道/句柄，投屏握手才成立。
          try { $spawnResult = Start-ProcessWithParent $mgrPid $hoExe $cmdLine } catch { $spawnResult = $null }
        }
        if (-not ($spawnResult -like 'OK|*')) {
          # 回退：普通启动
          Start-Process -FilePath $hoExe -ArgumentList $hoArgs -WindowStyle Minimized | Out-Null
        }
        $started = $true
        # 给它一点时间把自己挂到任务栏，再继续拉跨屏协作
        Start-Sleep -Milliseconds 1500
      } catch { $launchError = $_.Exception.Message }
    }
  }

  # 2b) 再跨屏协作：妙享桌面就绪后启动它，握手才完整。
  $castRunning = $null -ne (Get-Process -Name 'MiScreenShare' -ErrorAction SilentlyContinue | Select-Object -First 1)
  if (-not $castRunning) {
    $ssExe = Resolve-ScreenShareExecutable 'MiScreenShare.exe'
    if ($ssExe) {
      try {
        $ssCmd = '"' + $ssExe + '"'
        $ssResult = $null
        if ($mgrPid -gt 0) {
          try { $ssResult = Start-ProcessWithParent $mgrPid $ssExe $ssCmd } catch { $ssResult = $null }
        }
        if (-not ($ssResult -like 'OK|*')) {
          Start-Process -FilePath $ssExe -WindowStyle Minimized | Out-Null
        }
        $started = $true
      } catch { $launchError = $_.Exception.Message }
    }
  }

  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  $aspectReject = $false
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
      $parentTitle = [MiPhone.Native]::TitleOf($parent)
      $isLauncherSelf = ($child -eq $parent -and $parentTitle -like '妙享桌面*')
      if ($child -ne [IntPtr]::Zero) {
        $client = Get-ClientInfo $child
        if (-not $isLauncherSelf -and (Test-PhoneAspect $client.W $client.H)) {
          $target = @{ Parent = $parent; Child = $child }
          # ---- 三页判定（主人实测数据）----
          #   已解锁    : 不是纯色占位（dominant < 0.94 且 dark < 0.60，实测真实画面 0.389~0.824）
          #   连接中    : 纯色占位 + 画面在动（两个彩色圆点跳动，哈希持续变化）
          #   待解锁    : 纯色占位 + 静止 + OCR 命中「手机解锁」
          #   连接失败  : 纯色占位 + 静止 + OCR 命中「加载失败」
          # 三页的 dominant/dark 几乎一样（0.963/0.974/0.968），纯色只能判"是不是占位页"。
          # 判定顺序固定为 纯色 → 动态 → OCR，每 2 秒走一套，共 5 套（10 秒）。
          # 计时按真实墙钟算，保证 10 秒能走完 5 套（OCR 只跑一次，不拖垮节奏）。
          $rounds = 5
          $roundMs = 2000
          $verdict = $null
          $evidence = $null
          $startAt = Get-Date
          for ($round = 1; $round -le $rounds; $round++) {
            $roundStart = Get-Date
            # ① 纯色 + ② 动态：连拍 2 帧（不跑 OCR，快），比哈希看画面在不在动
            $a = Get-SurfaceStats $target
            Start-Sleep -Milliseconds 250
            $b = Get-SurfaceStats $target
            if ($null -eq $a -and $null -eq $b) {
              $remain = $roundMs - ((Get-Date) - $roundStart).TotalMilliseconds
              if ($remain -gt 0) { Start-Sleep -Milliseconds ([int]$remain) }
              continue
            }
            if ($null -eq $b) { $b = $a }
            if ($null -eq $a) { $a = $b }
            $animating = ($a.hash -ne $b.hash)
            $cur = $b
            $ocrText = ''
            $hitUnlock = $false; $hitConnecting = $false; $hitFailed = $false
            # ① 纯色判据：不是占位页 = 真实画面 = 已解锁，立即返回
            if (-not $cur.blank) {
              $evidence = @{
                round = $round; elapsedMs = [int]((Get-Date) - $startAt).TotalMilliseconds
                dominant = $cur.dominant; dark = $cur.dark; colors = $cur.colors
                animating = $animating; verdict = 'unlocked'
              }
              $verdict = 'unlocked'
              break
            }
            # ② 动态判据：占位 + 在动 = 连接中，继续等下一套
            if ($animating) {
              $evidence = @{
                round = $round; elapsedMs = [int]((Get-Date) - $startAt).TotalMilliseconds
                dominant = $cur.dominant; dark = $cur.dark; colors = $cur.colors
                animating = $true; verdict = 'connecting'
              }
              $verdict = 'connecting'
              $remain = $roundMs - ((Get-Date) - $roundStart).TotalMilliseconds
              if ($remain -gt 0) { Start-Sleep -Milliseconds ([int]$remain) }
              continue
            }
            # ③ OCR 判据：占位 + 静止，才值得花 1 秒读文字
            $withOcr = Get-SurfaceStats $target -WantOcr $true
            if ($null -ne $withOcr -and $withOcr.ocr) { $ocrText = [string]$withOcr.ocr }
            $hitUnlock     = [bool]($ocrText -match '手机解锁' -or $ocrText -match '请在手机端解锁' -or $ocrText -match '请在手机上解锁' -or $ocrText -match '解锁手机')
            $hitConnecting = [bool]($ocrText -match '正在连接' -or $ocrText -match '连接中')
            $hitFailed     = [bool]($ocrText -match '加载失败' -or $ocrText -match '无法连接' -or $ocrText -match '连接失败' -or $ocrText -match '小米社区反馈')
            $evidence = @{
              round = $round; elapsedMs = [int]((Get-Date) - $startAt).TotalMilliseconds
              dominant = $cur.dominant; dark = $cur.dark; colors = $cur.colors
              animating = $false; ocr = $ocrText
              hitUnlock = $hitUnlock; hitConnecting = $hitConnecting; hitFailed = $hitFailed
            }
            if ($hitUnlock) { $verdict = 'awaiting-unlock'; break }
            if ($hitFailed) { $verdict = 'connect-failed'; break }
            # 静止占位但读到「正在连接」：仍算连接中，继续等
            if ($hitConnecting) {
              $verdict = 'connecting'
              $remain = $roundMs - ((Get-Date) - $roundStart).TotalMilliseconds
              if ($remain -gt 0) { Start-Sleep -Milliseconds ([int]$remain) }
              continue
            }
            # 占位 + 静止 + 没读到任何关键词：OCR 没装或画面还没渲染好，下一套再看
            $verdict = 'unknown-placeholder'
            $remain = $roundMs - ((Get-Date) - $roundStart).TotalMilliseconds
            if ($remain -gt 0) { Start-Sleep -Milliseconds ([int]$remain) }
          }

          if ($verdict -eq 'unlocked') {
            $info = Get-WindowInfo $target
            $info.action = 'wake'
            $info.state = if ($started) { 'started' } elseif ($restored) { 'restored' } else { 'ready' }
            $info.surface = 'ready'
            $info.started = $started
            $info.restored = $restored
            $info.aspect = [math]::Round([double]$client.W / [double]$client.H, 3)
            $info.unlockRequired = $false
            $info.unlockState = 'unlocked'
            $info.evidence = $evidence
            $info.userPrompt = '小米互联画面已就绪，手机看起来已解锁，可以继续操作。若发现画面仍是锁屏，请主人手动指纹解锁。插件不会代为解锁。'
            $info.ocrAvailable = (Test-OcrAvailable)
            $info.ocrHint = (Get-OcrHint)
            return $info
          }
          if ($verdict -eq 'awaiting-unlock') {
            $info = Get-WindowInfo $target
            $info.action = 'wake'
            $info.state = 'awaiting-unlock'
            $info.surface = 'unlock-prompt'
            $info.started = $started
            $info.restored = $restored
            $info.aspect = [math]::Round([double]$client.W / [double]$client.H, 3)
            $info.unlockRequired = $true
            $info.unlockState = 'locked'
            $info.ocrAvailable = (Test-OcrAvailable)
            $info.ocrHint = (Get-OcrHint)
            $info.ok = $true
            $info.evidence = $evidence
            $info.userPrompt = '小米互联已连上，手机处于锁屏状态。请主人在手机上手动完成指纹解锁；解锁完成并确认后再继续操作。插件不会代为解锁。'
            return $info
          }
          if ($verdict -eq 'connect-failed' -or $verdict -eq 'connecting' -or $verdict -eq 'unknown-placeholder') {
            # 走完 5 套（10 秒）仍是连接中 / 一直停在占位页读不到文字 → 都算连接失败。
            # 「直接报连接失败」这一路已由上面的 hitFailed 提前 return。
            $isConn = ($verdict -eq 'connecting')
            return @{
              ok = $false; action = 'wake'
              state = 'connect-failed'
              deviceState = 'not-connected'
              started = $started; restored = $restored
              unlockRequired = $false
              evidence = $evidence
              userActionRequired = if ($isConn) {
                '投屏等了 10 秒还在连接中，判定为连接失败。请确认手机和电脑在同一局域网、手机端小米互联已开启，然后重新发起投屏。此时不需要指纹解锁。'
              } else {
                '投屏没连上，画面停在占位页。请确认手机和电脑在同一局域网、手机端小米互联已开启，然后重新发起投屏。此时不需要指纹解锁。'
              }
              error = if ($isConn) { '投屏等了 10 秒仍未连上。' } else { '投屏没连上，画面停在占位页。' }
              errorPage = $true
              ocrAvailable = (Test-OcrAvailable)
              ocrHint = (Get-OcrHint)
            }
          }
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
# 标尺合成测试（不依赖手机窗口，用于 372×844 / 1080×2400 / 1127×642 验收）
# ---------------------------------------------------------------------------
function Invoke-RulerTest($req) {
  $outDir = [string]$req.outDir
  if (-not $outDir) { $outDir = Join-Path (Join-Path $env:TEMP 'dsh-phone-use') 'ruler-test' }
  if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
  $sizes = @()
  if ($null -ne $req.sizes) {
    $rawSizes = @($req.sizes)
    # 单尺寸 [w,h] 与多尺寸 [[w,h],...] 两种写法都接受
    if ($rawSizes.Count -eq 2 -and -not ($rawSizes[0] -is [System.Array])) {
      $sizes += ,@([int]$rawSizes[0], [int]$rawSizes[1])
    } else {
      foreach ($s in $rawSizes) { $sizes += ,@([int]$s[0], [int]$s[1]) }
    }
  } else {
    $sizes = @(@(372, 844), @(1080, 2400), @(1127, 642))
  }
  $items = @()
  foreach ($sz in $sizes) {
    $w = [int]$sz[0]; $h = [int]$sz[1]
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.Clear([System.Drawing.Color]::White)
      $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(210, 225, 245), 1)
      $axisPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(160, 190, 230), 2)
      for ($i = 1; $i -le 9; $i++) {
        $x = [int][math]::Round($w * $i / 10.0); $y = [int][math]::Round($h * $i / 10.0)
        $g.DrawLine($gridPen, $x, 0, $x, $h)
        $g.DrawLine($gridPen, 0, $y, $w, $y)
      }
      $g.DrawLine($axisPen, [int]($w / 2), 0, [int]($w / 2), $h)
      $g.DrawLine($axisPen, 0, [int]($h / 2), $w, [int]($h / 2))
      $font = New-Object System.Drawing.Font('Arial', [math]::Max(12, [int]($w / 24)), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
      $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(80, 80, 80))
      $g.DrawString("${w}x${h}", $font, $brush, 8, 8)
      $font.Dispose(); $brush.Dispose(); $gridPen.Dispose(); $axisPen.Dispose()
    } finally { $g.Dispose() }

    $rawPath = Join-Path $outDir "raw-${w}x${h}.png"
    $bmp.Save($rawPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $fullR = [MiPhone.Ruler]::Draw($bmp, 0, 100, 0, 100, $w, $h, 10, 'light')
    $fullPath = Join-Path $outDir "full-${w}x${h}.png"
    $fullR.Image.Save($fullPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $back = $fullR.Image.Clone((New-Object System.Drawing.Rectangle($fullR.MarginPx, $fullR.MarginPx, $w, $h)), $fullR.Image.PixelFormat)
    $diff = [MiPhone.ImgStats]::DiffStats($bmp, $back, 0, 0, 0, 16)
    $fullDiff = if ($null -ne $diff) { $diff.ChangedPixels } else { -1 }
    $back.Dispose()

    $rect = Resolve-RegionRect $w $h @(50, 50, 10, 10)
    $sub = $bmp.Clone((New-Object System.Drawing.Rectangle($rect.X, $rect.Y, $rect.W, $rect.H)), $bmp.PixelFormat)
    $rx0 = $rect.X * 100.0 / $w; $rx1 = ($rect.X + $rect.W) * 100.0 / $w
    $ry0 = $rect.Y * 100.0 / $h; $ry1 = ($rect.Y + $rect.H) * 100.0 / $h
    $regR = [MiPhone.Ruler]::Draw($sub, $rx0, $rx1, $ry0, $ry1, $w, $h, 10, 'light')
    $regPath = Join-Path $outDir "region-50-60-${w}x${h}.png"
    $regR.Image.Save($regPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $back2 = $regR.Image.Clone((New-Object System.Drawing.Rectangle($regR.MarginPx, $regR.MarginPx, $sub.Width, $sub.Height)), $regR.Image.PixelFormat)
    $diff2 = [MiPhone.ImgStats]::DiffStats($sub, $back2, 0, 0, 0, 16)
    $regDiff = if ($null -ne $diff2) { $diff2.ChangedPixels } else { -1 }
    $back2.Dispose()

    # 额外用例：region 0,50,100,20（横向全宽、纵向 50–70），标尺应显示 50/60/70
    $rowRect = Resolve-RegionRect $w $h @(0, 50, 100, 20)
    $rowSub = $bmp.Clone((New-Object System.Drawing.Rectangle($rowRect.X, $rowRect.Y, $rowRect.W, $rowRect.H)), $bmp.PixelFormat)
    $rowR = [MiPhone.Ruler]::Draw($rowSub, 0, 100, 50, 70, $w, $h, 10, 'light')
    $rowPath = Join-Path $outDir "region-row-0-50-100-20-${w}x${h}.png"
    $rowR.Image.Save($rowPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $rowSub.Dispose(); $rowR.Image.Dispose()

    $sub.Dispose(); $bmp.Dispose(); $fullR.Image.Dispose(); $regR.Image.Dispose()

    $fm = [int]$fullR.MarginPx
    $item = @{}
    $item.size = @($w, $h)
    $item.full = $fullPath
    $item.region = $regPath
    $item.regionRow = $rowPath
    $item.fullOut = @(($w + 2 * $fm), ($h + 2 * $fm))
    $item.margin = $fm
    $item.font = [int]$fullR.FontPx
    $item.step = [double]$fullR.Step
    $item.regionStep = [double]$regR.Step
    $item.regionMinor = [double]$regR.Minor
    $item.regionBoxArgs = @([double]$regR.X0, [double]$regR.X1, [double]$regR.Y0, [double]$regR.Y1, [bool]$regR.IsFull)
    $item.regionPct = @([math]::Round($rx0, 2), [math]::Round($ry0, 2), [math]::Round($rx1 - $rx0, 2), [math]::Round($ry1 - $ry0, 2))
    $item.regionPx = @($rect.X, $rect.Y, $rect.W, $rect.H)
    $item.contentDiffPixels = @{ full = $fullDiff; region = $regDiff }
    $items += $item
  }
  return @{ ok = $true; action = 'ruler-test'; outDir = $outDir; items = $items }
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
  } elseif ($action -eq 'ruler-test') {
    $result = Invoke-RulerTest $req
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
      if ($req.smart) {
        $img = Invoke-SmartCapture $target $req
      } else {
        $out = [string]$req.out
        $prevPath = [string]$req.prev
        $region = $null
        if ($null -ne $req.region) { $region = @($req.region) }
        $maxWidth = 0
        if ($null -ne $req.maxWidth) { $maxWidth = [int]$req.maxWidth }
        $rawOut = [string]$req.rawOut
        $drawRuler = $false
        if ($null -ne $req.ruler) { $drawRuler = [bool]$req.ruler }
        $gridStep = 10
        if ($null -ne $req.gridStep) { $gridStep = [int]$req.gridStep }
        $theme = 'light'
        if ($req.rulerTheme) { $theme = [string]$req.rulerTheme }
        $img = Invoke-Capture $target $out $prevPath $region $maxWidth $rawOut $drawRuler $gridStep $theme
      }
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
      $bak = Join-Path $env:TEMP 'dsh-phone-use\clip-backup.txt'
      $val = if ($null -ne $req.value) { [string]$req.value } else { $null }
      # "@restore" 是还原指令，不是要写入的文本。此前漏判会把字面量写进剪贴板。
      if ($val -eq '@restore') {
        $restored = $false
        $reason = 'no-backup'
        if (Test-Path $bak) {
          try {
            $prev = [IO.File]::ReadAllText($bak)
            # 备份可能是空字符串（备份时剪贴板本来就空）。Set-Clipboard 不接受空串，要特殊处理。
            if ([string]::IsNullOrEmpty($prev)) {
              try { Set-Clipboard -Value $null -ErrorAction Stop } catch { }
            } else {
              Set-Clipboard -Value $prev -ErrorAction Stop
            }
            Remove-Item $bak -Force -ErrorAction SilentlyContinue
            $restored = $true
            $reason = 'ok'
          } catch { $reason = $_.Exception.Message }
        }
        $result = @{ ok = $true; clip = 'restored'; restored = $restored; reason = $reason }
      } elseif ($null -ne $val) {
        if (-not (Test-Path $bak)) {
          try {
            $prev = Get-Clipboard -Raw -ErrorAction Stop
            [IO.File]::WriteAllText($bak, $prev, [System.Text.UTF8Encoding]::new($false))
          } catch { }
        }
        Set-Clipboard -Value $val -ErrorAction Stop
        $result = @{ ok = $true; clip = 'set'; n = $val.Length }
      } else {
        $text = $null
        try { $text = Get-Clipboard -Raw -ErrorAction Stop } catch { $text = '' }
        $result = @{ ok = $true; clip = 'read'; n = $text.Length; head = $text.Substring(0, [math]::Min(40, $text.Length)) }
      }
    }
    'openmenu' {
      $hold = 0    # 0 = 用默认长按时长（1200ms）
      if ($null -ne $req.ms) { $hold = [int]$req.ms }
      # MCP 层传的是 text 字段（顶层 openmenu 和 batch 里的 openmenu 都用 text），
# 此前这里读 $req.value 导致文字为空、剪贴板没更新，粘贴出来是上一次的旧内容。
      $omText = if ($null -ne $req.text) { [string]$req.text } elseif ($null -ne $req.value) { [string]$req.value } else { '' }
      $r = Invoke-OpenMenu $target ([string]$req.at) $hold $omText
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
    'panel' {
      # 打开系统面板：control = 控制中心，notification = 通知栏
      $side = [string]$req.side
      if ($side -ne 'control' -and $side -ne 'notification') { $side = 'control' }
      $okp = Invoke-PanelPull $target $side
      $result = Get-WindowInfo $target
      $result.did = @{ action = 'panel'; side = $side; ok = $okp }
    }
    'back' {
      # 返回手势：关闭面板或 App 内返回上一页
      $okb = Invoke-BackGesture $target
      $result = Get-WindowInfo $target
      $result.did = @{ action = 'back'; ok = $okb }
    }
    'batch' {
      $client = Get-ClientInfo $target.Child
      $actualS = @($client.W, $client.H)
      $state = Read-ViewState
      $stale = $null

      # 旧坐标保护：expectedS 优先；其次 frameId 里的尺寸；最后自动对照最近一次截图的 s。
      if ($null -ne $req.expectedS) {
        $exp = @($req.expectedS)
        if ($exp.Count -ge 2 -and ([int]$exp[0] -ne $actualS[0] -or [int]$exp[1] -ne $actualS[1])) {
          $stale = @{ ok = $false; stale = $true; state = 'stale_frame'; error = 'stale_frame'; reason = 'expectedS 与当前画面尺寸不一致，旧坐标已失效，请重新截图'; expectedS = @([int]$exp[0], [int]$exp[1]); s = $actualS }
        }
      }
      if ($null -eq $stale -and $req.frameId) {
        $fid = [string]$req.frameId
        if ($fid -match '-(\d+)x(\d+)$') {
          $fw = [int]$Matches[1]; $fh = [int]$Matches[2]
          if ($fw -ne $actualS[0] -or $fh -ne $actualS[1]) {
            $stale = @{ ok = $false; stale = $true; state = 'stale_frame'; error = 'stale_frame'; reason = 'frameId 所属画面尺寸与当前不一致，旧坐标已失效，请重新截图'; expectedS = @($fw, $fh); s = $actualS }
          }
        }
      }
      if ($null -eq $stale -and $null -ne $state.lastFrame -and $null -ne $state.lastFrame.s) {
        $ls = @($state.lastFrame.s)
        if ($ls.Count -ge 2 -and ([int]$ls[0] -ne $actualS[0] -or [int]$ls[1] -ne $actualS[1])) {
          $stale = @{ ok = $false; stale = $true; state = 'stale_frame'; error = 'stale_frame'; reason = '画面尺寸/方向已变化（旋转或缩放），请重新截图后再操作'; expectedS = @([int]$ls[0], [int]$ls[1]); s = $actualS; dimensionChanged = $true }
        }
      }

      if ($null -ne $stale) {
        $result = $stale
      } else {
        $log = New-Object System.Collections.ArrayList
        $lastTap = $null
        $preShot = $null
        $verify = $null
        $opsCount = 0
        $wheelSeen = $false
        $lastWheel = $null
        if ($null -ne $req.verify) { $verify = @($req.verify) }
        $shotDir = Join-Path $env:TEMP 'dsh-phone-use'
        if (-not (Test-Path $shotDir)) { New-Item -ItemType Directory -Path $shotDir -Force | Out-Null }

        # verify 必须先留一张「动作前」的无标尺原图
        if ($null -ne $verify) {
          $preShot = Join-Path $shotDir ('verify-pre-' + [guid]::NewGuid().ToString('N') + '.png')
          Invoke-Capture $target $preShot $null $null 0 $null $false | Out-Null
        }

        foreach ($st in @($req.steps)) {
          $op = [string]$st.op
          switch ($op) {
            'tap' {
              $pt2 = ConvertTo-Point $st.at $client
              Invoke-Tap $target $pt2[0] $pt2[1]
              $lastTap = @($pt2[0], $pt2[1])
              $opsCount++
              [void]$log.Add(@{ op = 'tap'; at = [string]$st.at; px = $pt2 })
              Start-Sleep -Milliseconds 120
            }
            'swipe' {
              $pa = ConvertTo-Point $st.from $client
              $pb = ConvertTo-Point $st.to $client
              $ms2 = 300
              if ($null -ne $st.ms) { $ms2 = [int]$st.ms }
              Invoke-Swipe $target $pa[0] $pa[1] $pb[0] $pb[1] $ms2
              $opsCount++
              [void]$log.Add(@{ op = 'swipe'; from = [string]$st.from; to = [string]$st.to; ms = $ms2 })
              Start-Sleep -Milliseconds 120
            }
            'wheel' {
              $dir = [string]$st.wheel
              if ($dir -ne 'up' -and $dir -ne 'down') { throw 'wheel 只能是 up 或 down' }
              $nt = 3
              if ($null -ne $st.notches) { $nt = [int]$st.notches }
              if ($nt -lt 1) { $nt = 1 }
              if ($nt -gt 20) { $nt = 20 }
              $at = '50,50'
              if ($st.at) { $at = [string]$st.at }
              $wm = 400
              if ($null -ne $st.wait) { $wm = [int]$st.wait }
              $preW = Join-Path $shotDir ('wheel-pre-' + [guid]::NewGuid().ToString('N') + '.png')
              $postW = Join-Path $shotDir ('wheel-post-' + [guid]::NewGuid().ToString('N') + '.png')
              Invoke-Capture $target $preW $null $null 0 $null $false | Out-Null
              $wi = Invoke-Wheel $target $dir $nt $at
              Start-Sleep -Milliseconds $wm
              Invoke-Capture $target $postW $null $null 0 $null $false | Out-Null
              $sd = Get-ScrollDiff $preW $postW
              $scrolled = ($null -ne $sd -and $sd.changed)
              $atEdge = $false
              $notScrollable = $false
              $extra = 0
              if (-not $scrolled) {
                # 兼容少数按客户区坐标解析 WM_MOUSEWHEEL 的控件：先试 1 格客户区坐标模式
                Invoke-Wheel $target $dir 1 $at $false | Out-Null
                Start-Sleep -Milliseconds $wm
                $postAlt = Join-Path $shotDir ('wheel-alt-' + [guid]::NewGuid().ToString('N') + '.png')
                Invoke-Capture $target $postAlt $null $null 0 $null $false | Out-Null
                $sdAlt = Get-ScrollDiff $postW $postAlt
                if ($null -ne $sdAlt -and $sdAlt.changed) { $scrolled = $true; $sd = $sdAlt }
                Remove-Item $postAlt -Force -ErrorAction SilentlyContinue
              }
              if (-not $scrolled) {
                # 连续再滚 2 格仍无变化 → 已到顶/到底
                $extra = 2
                Invoke-Wheel $target $dir $extra $at | Out-Null
                Start-Sleep -Milliseconds $wm
                $postW2 = Join-Path $shotDir ('wheel-post2-' + [guid]::NewGuid().ToString('N') + '.png')
                Invoke-Capture $target $postW2 $null $null 0 $null $false | Out-Null
                $sd2 = Get-ScrollDiff $postW $postW2
                if ($null -ne $sd2 -and $sd2.changed) { $scrolled = $true; $sd = $sd2 }
                else { $atEdge = $true; if ($null -ne $sd2) { $sd = $sd2 } }
                Remove-Item $postW2 -Force -ErrorAction SilentlyContinue
              }
              if ($atEdge) {
                # 反向探测 2 格：反向能动 = 页面可滚，只是到了这一侧边缘；反向也不动 = 该位置不可滚动
                $rev = if ($dir -eq 'up') { 'down' } else { 'up' }
                $preR = Join-Path $shotDir ('wheel-rev-pre-' + [guid]::NewGuid().ToString('N') + '.png')
                $postR = Join-Path $shotDir ('wheel-rev-post-' + [guid]::NewGuid().ToString('N') + '.png')
                Invoke-Capture $target $preR $null $null 0 $null $false | Out-Null
                Invoke-Wheel $target $rev 2 $at | Out-Null
                Start-Sleep -Milliseconds $wm
                Invoke-Capture $target $postR $null $null 0 $null $false | Out-Null
                $sdR = Get-ScrollDiff $preR $postR
                if ($null -ne $sdR -and $sdR.changed) {
                  $notScrollable = $false
                  # 反向探测改变了页面位置，按原方向滚回去
                  Invoke-Wheel $target $dir 2 $at | Out-Null
                  Start-Sleep -Milliseconds 200
                } else {
                  $notScrollable = $true
                }
                Remove-Item $preR, $postR -Force -ErrorAction SilentlyContinue
              }
              $lastWheel = @{ direction = $dir; notches = $nt; extraNotches = $extra; at = $at; wait = $wm; scrolled = [bool]$scrolled; atEdge = $atEdge; notScrollable = $notScrollable; diffPx = $(if ($null -ne $sd) { $sd.diffPx } else { $null }); diffRatio = $(if ($null -ne $sd) { $sd.ratio } else { $null }) }
              [void]$log.Add(@{ op = 'wheel'; wheel = $dir; notches = $nt; extraNotches = $extra; at = $at; px = $wi.px; wait = $wm; scrolled = [bool]$scrolled; atEdge = $atEdge; notScrollable = $notScrollable; diffPx = $lastWheel.diffPx; diffRatio = $lastWheel.diffRatio })
              $opsCount++
              $wheelSeen = $true
              Remove-Item $preW, $postW -Force -ErrorAction SilentlyContinue
            }
            'key' {
              $nn = 1
              if ($null -ne $st.n) { $nn = [int]$st.n }
              Invoke-Key $target ([string]$st.name) $nn | Out-Null
              $opsCount++
              [void]$log.Add(@{ op = 'key'; name = [string]$st.name; n = $nn })
              Start-Sleep -Milliseconds 80
            }
            'text' {
              $rr = Invoke-Text $target ([string]$st.value) ([string]$st.at) ([string]$st.menu)
              $opsCount++
              [void]$log.Add(@{ op = 'text'; n = $rr.n; mode = $rr.mode; clip = $rr.clip; menu = $rr.menu; menuAt = $rr.menuAt; inserted = $rr.inserted; box = $rr.box })
              Start-Sleep -Milliseconds 120
            }
            'openmenu' {
              $mo = 0   # 0 = 用默认长按时长
              if ($null -ne $st.ms) { $mo = [int]$st.ms }
              $om = Invoke-OpenMenu $target ([string]$st.at) $mo ([string]$st.text)
              $opsCount++
              [void]$log.Add(@{ op = 'openmenu'; at = [string]$st.at; opened = $om.opened; box = $om.box; crop = $om.crop })
              Start-Sleep -Milliseconds 120
            }
            'longpress' {
              $pl = ConvertTo-Point $st.at $client
              $msl = 700
              if ($null -ne $st.ms) { $msl = [int]$st.ms }
              Invoke-LongPress $target $pl[0] $pl[1] $msl
              $opsCount++
              [void]$log.Add(@{ op = 'longpress'; at = [string]$st.at; ms = $msl })
              Start-Sleep -Milliseconds 120
            }
            'clip' {
              if ($null -ne $st.value -and ([string]$st.value) -eq '@restore') {
                # 约定值：还原 openmenu/写入前备份的原剪贴板
                $bak = Join-Path (Join-Path $env:TEMP 'dsh-phone-use') 'clip-backup.txt'
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
                $bak = Join-Path (Join-Path $env:TEMP 'dsh-phone-use') 'clip-backup.txt'
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
            'panel' {
              # 打开系统面板：control = 控制中心，notification = 通知栏
              $side = [string]$st.side
              if ($side -ne 'control' -and $side -ne 'notification') { $side = 'control' }
              $okp = Invoke-PanelPull $target $side
              $opsCount++
              [void]$log.Add(@{ op = 'panel'; side = $side; ok = $okp })
              Start-Sleep -Milliseconds 900
            }
            'back' {
              # 返回手势：关闭面板或 App 内返回上一页
              $okb = Invoke-BackGesture $target
              $opsCount++
              [void]$log.Add(@{ op = 'back'; ok = $okb })
              Start-Sleep -Milliseconds 600
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
        if ($wheelSeen -and $null -ne $lastWheel) {
          $result.scrolled = $lastWheel.scrolled
          $result.atEdge = $lastWheel.atEdge
          $result.notScrollable = $lastWheel.notScrollable
          $result.wheel = $lastWheel
        }

        $wantCapture = [bool]$req.capture
        if ($null -ne $verify) { $wantCapture = $true }
        if ($wantCapture) {
          $capOut = [string]$req.out
          if (-not $capOut) { $capOut = Join-Path $shotDir 'batch-view.png' }
          $capRaw = [string]$req.rawOut
          if (-not $capRaw) { $capRaw = [System.IO.Path]::ChangeExtension($capOut, '.raw.png') }
          $capReq = @{
            mode = $(if ([string]$req.mode -eq 'full') { 'full' } else { 'auto' })
            out = $capOut; rawOut = $capRaw; opsDelta = $opsCount
            commit = $true
            grid = $(if ([string]$req.grid -eq 'off') { 'off' } else { 'ruler' })
            gridStep = $(if ($null -ne $req.gridStep) { [int]$req.gridStep } else { 10 })
            rulerTheme = $(if ($req.rulerTheme) { [string]$req.rulerTheme } else { 'light' })
          }
          if ([string]$req.image -eq 'none') { $capReq.commit = $false }
          if ($null -ne $req.commit) { $capReq.commit = [bool]$req.commit }
          $img = Invoke-SmartCapture $target $capReq

          # 点击验证：只比目标那块；没变就重试一次（只一次，不盲目重试）
          if ($null -ne $verify) {
            $vd = Get-RegionDiff $preShot $capRaw $verify $client
            $hit = if ($null -ne $vd) { [bool]$vd.hit } else { $null }
            $tries = 1
            if ($hit -eq $false -and $null -ne $lastTap -and $req.retry -ne $false) {
              Start-Sleep -Milliseconds 450
              Invoke-Tap $target $lastTap[0] $lastTap[1]
              Start-Sleep -Milliseconds 550
              $retryReq = @{}
              foreach ($ck in $capReq.Keys) { $retryReq[$ck] = $capReq[$ck] }
              $retryReq.opsDelta = 0
              $img = Invoke-SmartCapture $target $retryReq
              $vd = Get-RegionDiff $preShot $capRaw $verify $client
              $hit = if ($null -ne $vd) { [bool]$vd.hit } else { $null }
              $tries = 2
            }
            $result.hit = $hit
            $result.tries = $tries
            if ($null -ne $vd) { $result.verifyDiffPx = $vd.diffPx; $result.verifyRatio = $vd.ratio }
            # 顶部条带变了 → 多半弹了通知，页面可能被挤下去
            $bd = Get-RegionDiff $preShot $capRaw @(0, 0, 100, 14) $client
            $result.banner = if ($null -ne $bd) { [bool]$bd.hit } else { $null }
            Remove-Item $preShot -Force -ErrorAction SilentlyContinue
          }
          $result.img = $img
        } else {
          Add-ViewOps $opsCount
          if ($null -ne $verify) { $result.hit = $null }
        }
      }
    }
      default { throw "unknown action: $action" }
    }
  }
} catch {
  $result = @{ ok = $false; error = $_.Exception.Message; type = $_.Exception.GetType().Name; stack = $_.ScriptStackTrace }
}

$json = $result | ConvertTo-Json -Depth 10 -Compress
if ($ResultFile) {
  [System.IO.File]::WriteAllText($ResultFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}
if (-not $ResultFile) { $json }
