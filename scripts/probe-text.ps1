param([ValidateSet('info','char','imechar')][string]$Mode='info',[string]$Text='中文测试')
$ErrorActionPreference='Stop'
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public class MiTextProbe {
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p,EnumProc cb,IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 public static string Cls(IntPtr h){var s=new StringBuilder(256); GetClassName(h,s,256);return s.ToString();}
 public static IntPtr Parent(){IntPtr p=IntPtr.Zero;EnumWindows((h,l)=>{if(Cls(h)=="kMiScreenShareMainWindow")p=h;return true;},IntPtr.Zero);return p;}
 public static IntPtr Child(IntPtr p){IntPtr c=IntPtr.Zero;EnumChildWindows(p,(h,l)=>{if(Cls(h)=="kMiChildSharedWindow")c=h;return true;},IntPtr.Zero);return c;}
}
'@
$p=[MiTextProbe]::Parent(); $c=[MiTextProbe]::Child($p)
if($p -eq [IntPtr]::Zero -or $c -eq [IntPtr]::Zero){throw 'phone window not found'}
if($Mode -ne 'info'){
 if($Text -match '[\r\n\t]'){throw 'probe excludes control characters'}
 $msg=0x0102; if($Mode -eq 'imechar'){$msg=0x0286}
 foreach($ch in $Text.ToCharArray()){
  if(-not [MiTextProbe]::PostMessage($c,$msg,[IntPtr][int]$ch,[IntPtr]1)){throw 'PostMessage failed'}
  Start-Sleep -Milliseconds 40
 }
}
@{parent=[long]$p; child=[long]$c; mode=$Mode; length=$Text.Length}|ConvertTo-Json -Compress
