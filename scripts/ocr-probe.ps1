param([string]$Image, [double]$Scale = 3.0, [string]$Lang = 'zh-Hans-CN')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$src = [System.Drawing.Image]::FromFile($Image)
$w = [int]($src.Width * $Scale); $h = [int]($src.Height * $Scale)
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.Clear([System.Drawing.Color]::White)
$g.DrawImage($src, 0, 0, $w, $h)
$g.Dispose(); $src.Dispose()
$out = Join-Path $env:TEMP ('ocr-{0}.png' -f [guid]::NewGuid().ToString('N'))
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
function Await($op, $type) {
  $task = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
  $task.Wait(-1) | Out-Null
  $task.Result
}

$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($out)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$sb = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

$language = New-Object Windows.Globalization.Language($Lang)
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
if ($null -eq $engine) { throw "OCR engine unavailable for $Lang" }
$res = Await ($engine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])

$lines = @()
foreach ($line in $res.Lines) {
  $words = @()
  foreach ($word in $line.Words) {
    $r = $word.BoundingRect
    $words += [pscustomobject]@{
      t = $word.Text
      x = [int]($r.X / $Scale); y = [int]($r.Y / $Scale)
      w = [int]($r.Width / $Scale); h = [int]($r.Height / $Scale)
    }
  }
  $lines += [pscustomobject]@{ text = $line.Text; words = $words }
}
[pscustomobject]@{ ok = $true; engine = 'windows-ocr'; lang = $Lang; lines = $lines } | ConvertTo-Json -Depth 6 -Compress
