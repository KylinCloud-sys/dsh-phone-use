<##
Safe probe for the Xiaomi interop window. It does not click, paste, press Enter,
or send a message. It only posts a single WM_CHAR/WM_IME_CHAR code unit to the
currently focused phone surface, for diagnostics in a test field.
##>
param(
  [ValidateSet('info','char','imechar')][string]$Mode='info',
  [string]$Text='中文测试'
)
$ErrorActionPreference='Stop'
$source=@'
using System; using System.Text; using System.Runtime.InteropServices;
public static class MiPhoneTextProbe {
 public delegate bool EnumProc(IntPtr h,IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p,EnumProc cb,IntPtr l);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 public static string Cls(IntPtr h){var s=new StringBuilder(256);GetClassName(h,s,256);return s.ToString();}
 public static IntPtr Parent(){IntPtr p=IntPtr.Zero;EnumWindows((h,l)=>{if(Cls(h)=="kMiScreenShareMainWindow")p=h;return true;},IntPtr.Zero);return p;}
 public static IntPtr Child(IntPtr p){IntPtr c=IntPtr.Zero;EnumChildWindows(p,(h,l)=>{if(Cls(h)=="kMiChildSharedWindow")c=h;return true;},IntPtr.Zero);return c;}
}
'@
Add-Type -TypeDefinition $source
$p=[MiPhoneTextProbe]::Parent();$c=[MiPhoneTextProbe]::Child($p)
if($p -eq [IntPtr]::Zero -or $c -eq [IntPtr]::Zero){throw 'phone window not found'}
if($Mode -ne 'info'){
  if($Text -match '[\r\n\t]'){throw 'control characters are not allowed'}
  $msg=if($Mode -eq 'imechar'){0x0286}else{0x0102}
  foreach($ch in $Text.ToCharArray()){
    [void][MiPhoneTextProbe]::PostMessage($c,$msg,[IntPtr][int]$ch,[IntPtr]1)
    Start-Sleep -Milliseconds 40
  }
}
@{ok=$true;mode=$Mode;length=$Text.Length;parent=[long]$p;child=[long]$c}|ConvertTo-Json -Compress
