param([string]$Path)
$errs = $null
$tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
if ($errs.Count -eq 0) {
  Write-Output 'OK: 没有语法错误'
} else {
  foreach ($e in $errs) {
    Write-Output ("line {0} col {1}: {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
    Write-Output ("    >>> " + ($e.Extent.Text -split "`n")[0])
  }
}
