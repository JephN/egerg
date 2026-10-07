$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'worm-bootstrap-last.log'
function WLog([string]$m) { try { Add-Content -LiteralPath $log -Value $m } catch {} }
try {
  WLog 'bootstrap start'
  $zipUrl = $env:WORM_ZIP_URL
  if (-not $zipUrl) { throw 'WORM_ZIP_URL is not set' }
  $zipName = Split-Path $zipUrl -Leaf
  if (-not $zipName) { $zipName = 'seed.zip' }
  $d = Join-Path $env:TEMP ([guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $d | Out-Null
  WLog ('work ' + $d)
  Invoke-WebRequest -UseBasicParsing $zipUrl -OutFile (Join-Path $d $zipName)
  Expand-Archive -LiteralPath (Join-Path $d $zipName) -DestinationPath (Join-Path $d 'app')
  $app = Join-Path $d 'app'
  if (Test-Path (Join-Path $app 'package.json')) { $w = $app } else {
    $sub = Get-ChildItem $app -Directory | Select-Object -First 1
    if (-not $sub) { throw 'no package folder in zip' }
    $w = $sub.FullName
  }
  WLog ('payload ' + $w)
  Set-Location -LiteralPath $w
  if (-not (Test-Path '.\install.ps1')) { throw 'install.ps1 missing in zip' }
  & '.\install.ps1'
  WLog 'bootstrap done'
} catch {
  WLog ('ERR ' + $_.Exception.Message)
  WLog $_.ScriptStackTrace
  exit 1
}
