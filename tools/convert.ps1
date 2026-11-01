param([Parameter(ValueFromRemainingArguments=$true)][string[]]$CliArgs)
$msroot = Join-Path (Join-Path $PSScriptRoot '..\.cache\mslite') 'mindspore-lite-2.3.1-win-x64'
$env:PATH = "$msroot\tools\converter\lib;$env:PATH"
& "$msroot\tools\converter\converter\converter_lite.exe" @CliArgs
exit $LASTEXITCODE
