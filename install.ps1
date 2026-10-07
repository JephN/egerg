# worm install · tag=etr8 · build=1791390140674-etr8
$ErrorActionPreference = 'Stop'
$WormLog = Join-Path $env:TEMP 'worm-install-last.log'
try { Start-Transcript -Path $WormLog -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
$WormTag = 'etr8'
$WormBuildId = '1791390140674-etr8'
$WormEmbedSeedUrl = ''
$WormEmbedSeedSha256 = ''
$WormMinNodeMajor = 18
$WormNodeVersion = if ($env:WORM_NODE_VERSION) { $env:WORM_NODE_VERSION } else { '20.18.0' }
if (-not $env:WORM_ALLOW_SCRIPTS) { $env:WORM_ALLOW_SCRIPTS = '1' }

function Fail([string]$Message) {
  Write-Error $Message
  exit 1
}

function Test-RuntimeOk {
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $false }
  if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { return $false }
  $major = [int](node -p "process.versions.node.split('.')[0]")
  if ($major -lt $WormMinNodeMajor) { return $false }
  return $true
}

function Add-WormNodePath {
  $root = Join-Path $env:LOCALAPPDATA 'worm-node'
  if (-not (Test-Path $root)) { return }
  Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if (Test-Path (Join-Path $_.FullName 'node.exe')) {
      $env:PATH = "$($_.FullName);$env:PATH"
    }
  }
}

function Get-WinNodeArch {
  $a = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  switch ($a.ToString()) {
    'X64' { return 'x64' }
    'Arm64' { return 'arm64' }
    default { Fail 'unsupported Windows CPU architecture' }
  }
}

function Install-NodeOfficial {
  if ($WormNodeVersion -notmatch '^[0-9.]+$') { Fail 'invalid WORM_NODE_VERSION' }
  $arch = Get-WinNodeArch
  $parent = Join-Path $env:LOCALAPPDATA 'worm-node'
  $dest = Join-Path $parent "$WormNodeVersion-win-$arch"
  if (Test-Path $dest) {
    $env:PATH = "$dest;$env:PATH"
    if (Test-RuntimeOk) { return }
    Remove-Item -LiteralPath $dest -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $tmp = Join-Path $env:TEMP ([guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $archive = "node-v$WormNodeVersion-win-$arch.zip"
  $base = "https://nodejs.org/dist/v$WormNodeVersion"
  Invoke-WebRequest -UseBasicParsing "$base/$archive" -OutFile (Join-Path $tmp $archive)
  Invoke-WebRequest -UseBasicParsing "$base/SHASUMS256.txt" -OutFile (Join-Path $tmp 'SHASUMS256.txt')
  $expected = (Select-String -Path (Join-Path $tmp 'SHASUMS256.txt') -Pattern " $archive$" | ForEach-Object { $_.Line.Split(' ')[0] })
  if ($expected.Length -ne 64) { Fail 'missing Node.js checksum' }
  $actual = (Get-FileHash (Join-Path $tmp $archive) -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $expected) { Fail 'Node.js checksum mismatch' }
  $stage = Join-Path $tmp 'stage'
  Expand-Archive -LiteralPath (Join-Path $tmp $archive) -DestinationPath $stage
  $inner = Get-ChildItem -Path $stage -Directory | Select-Object -First 1
  if (-not $inner) { Fail 'invalid Node.js zip layout' }
  Move-Item -LiteralPath $inner.FullName -Destination $dest
  $env:PATH = "$dest;$env:PATH"
  if (-not (Test-RuntimeOk)) { Fail 'downloaded Node.js cannot run' }
}

function Get-FileSha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Resolve-WorkDir {
  if ($env:WORM_WORKDIR) {
    if (-not (Test-Path (Join-Path $env:WORM_WORKDIR 'package.json'))) { Fail 'WORM_WORKDIR has no package.json' }
    return (Resolve-Path $env:WORM_WORKDIR).Path
  }
  $here = $PSScriptRoot
  if ((Test-Path (Join-Path $here 'package.json')) -and (Test-Path (Join-Path $here 'setup.mjs'))) {
    return $here
  }
  $url = $null
  if ($env:WORM_SEED_URL) { $url = $env:WORM_SEED_URL }
  elseif ($WormEmbedSeedUrl) { $url = $WormEmbedSeedUrl }
  elseif ($env:WORM_INSTALL_BASE) {
    $file = if ($env:WORM_SEED_FILE) { $env:WORM_SEED_FILE } else { "$WormTag.zip" }
    $url = ($env:WORM_INSTALL_BASE.TrimEnd('/')) + '/' + $file
  }
  else { Fail 'run from extracted seed or set WORM_SEED_URL' }
  if ($url -notmatch '^https://') { Fail 'only HTTPS seed URLs' }
  $tmp = Join-Path $env:TEMP ([guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'payload.zip'
  Invoke-WebRequest -UseBasicParsing $url -OutFile $zip
  $sha = $env:WORM_SEED_SHA256
  if (-not $sha -and $WormEmbedSeedSha256) { $sha = $WormEmbedSeedSha256 }
  if ($sha) {
    if ($sha.Length -ne 64) { Fail 'invalid WORM_SEED_SHA256' }
    if ((Get-FileSha256 $zip) -ne $sha.ToLower()) { Fail 'payload checksum mismatch' }
  }
  $out = Join-Path $tmp 'out'
  Expand-Archive -LiteralPath $zip -DestinationPath $out
  if ((Test-Path (Join-Path $out 'package.json')) -and (Test-Path (Join-Path $out 'setup.mjs'))) {
    return $out
  }
  $sub = Get-ChildItem -Path $out -Directory | Where-Object {
    (Test-Path (Join-Path $_.FullName 'package.json')) -and (Test-Path (Join-Path $_.FullName 'setup.mjs'))
  }
  if ($sub.Count -eq 1) { return $sub[0].FullName }
  Fail 'ZIP must contain package.json and setup.mjs'
}

Add-WormNodePath
if (-not (Test-RuntimeOk)) {
  Install-NodeOfficial
  Add-WormNodePath
}
if (-not (Test-RuntimeOk)) { Fail 'Node/npm missing after install attempts' }

$work = Resolve-WorkDir
Set-Location -LiteralPath $work
$ignore = if ($env:WORM_ALLOW_SCRIPTS -eq '1') { 'false' } else { 'true' }
npm install --ignore-scripts=$ignore --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { Fail 'npm install failed' }
try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
