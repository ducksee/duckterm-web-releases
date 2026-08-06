[CmdletBinding()]
param(
  [string]$Version = $env:DUCKTERM_VERSION,
  [ValidateSet('', 'tiny', 'full')][string]$Flavor = $env:DUCKTERM_FLAVOR,
  [string]$AppDirectory = $(if ($env:DUCKTERM_APP_DIR) { $env:DUCKTERM_APP_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\DuckTerm Web' }),
  [string]$Tarball = $env:DUCKTERM_TARBALL,
  [string]$Sha256 = $env:DUCKTERM_SHA256,
  [int]$Port = $(if ($env:DUCKTERM_PORT) { [int]$env:DUCKTERM_PORT } else { 0 }),
  [switch]$Expose,
  [switch]$NoService
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repository = 'ducksee/duckterm-web-releases'
$taskName = 'DuckTerm Web'

$trimSeparators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$AppDirectory = [IO.Path]::GetFullPath($AppDirectory).TrimEnd($trimSeparators)
$appRoot = [IO.Path]::GetPathRoot($AppDirectory).TrimEnd($trimSeparators)
$userRoot = [IO.Path]::GetFullPath($HOME).TrimEnd($trimSeparators)
if (-not $AppDirectory -or $AppDirectory -eq $appRoot -or $AppDirectory -eq $userRoot) {
  throw "Refusing unsafe AppDirectory: $AppDirectory"
}

function Write-Step([string]$Message) { Write-Host "[duckterm] $Message" }

function Resolve-Architecture {
  $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
  switch ($native.ToUpperInvariant()) {
    'AMD64' { 'x64' }
    'ARM64' { 'arm64' }
    default { throw "Unsupported Windows architecture: $native" }
  }
}

function Test-Node([string]$Path) {
  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    $parts = (& $Path -p 'process.versions.node' 2>$null).Trim().Split('.')
    return ([int]$parts[0] -gt 22) -or ([int]$parts[0] -eq 22 -and [int]$parts[1] -ge 5)
  } catch { return $false }
}

function Resolve-SystemNode {
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($null -ne $command -and (Test-Node $command.Source)) { return $command.Source }
  $candidate = Join-Path $env:ProgramFiles 'nodejs\node.exe'
  if (Test-Node $candidate) { return $candidate }
  return $null
}

function Stop-WebTaskAndWait {
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($null -eq $task) { return }
  $execute = (($task.Actions | Select-Object -First 1).Execute).Trim('"')
  $serviceEntry = Join-Path $AppDirectory 'duckterm.mjs'
  $ids = @()
  if ($execute) {
    $ids = @(Get-CimInstance Win32_Process | Where-Object {
      $_.ExecutablePath -eq $execute -and
      $_.CommandLine -and
      $_.CommandLine.IndexOf($serviceEntry, [StringComparison]::OrdinalIgnoreCase) -ge 0
    } | ForEach-Object { [int]$_.ProcessId })
  }
  Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while (@($ids | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) }).Count -gt 0) {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the previous DuckTerm Web worker to stop.' }
    Start-Sleep -Milliseconds 100
  }
}

function Resolve-LatestVersion {
  $candidate = ''
  try { $candidate = ([string](Invoke-RestMethod -UseBasicParsing -Uri "https://raw.githubusercontent.com/$repository/main/LATEST")).Trim() } catch {}
  if ($candidate -match '^\d+\.\d+\.\d+$') { return $candidate }
  try {
    $response = Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue -Uri "https://github.com/$repository/releases/latest"
    $location = [string]$response.Headers.Location
    $candidate = ($location.TrimEnd('/') -split '/')[-1].TrimStart('v')
  } catch {
    if ($_.Exception.Response -and $_.Exception.Response.Headers['Location']) {
      $candidate = ([string]$_.Exception.Response.Headers['Location']).TrimEnd('/').Split('/')[-1].TrimStart('v')
    }
  }
  if ($candidate -match '^\d+\.\d+\.\d+$') { return $candidate }
  try { $candidate = ([string](Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$repository/releases/latest").tag_name).TrimStart('v') } catch {}
  if ($candidate -notmatch '^\d+\.\d+\.\d+$') { throw 'Could not resolve the latest DuckTerm Web version.' }
  return $candidate
}

$arch = Resolve-Architecture
$systemNode = Resolve-SystemNode
if (-not $Flavor) { $Flavor = if ($systemNode) { 'tiny' } else { 'full' } }
if (-not $Tarball) {
  if (-not $Version) { $Version = Resolve-LatestVersion }
  if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must be X.Y.Z (got '$Version')" }
}
Write-Step "platform: win32-$arch | node: $(if ($systemNode) { $systemNode } else { 'bundled' }) | flavor: $Flavor"

$parent = Split-Path -Parent $AppDirectory
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("duckterm-web-install-" + [Guid]::NewGuid().ToString('N'))
$stage = Join-Path $parent (".duckterm-web-stage-" + [Guid]::NewGuid().ToString('N'))
$backup = "$AppDirectory.rollback"
$archive = Join-Path $temporary 'package.tar.gz'
New-Item -ItemType Directory -Path $temporary,$stage -Force | Out-Null
$activated = $false
$configPath = Join-Path $HOME '.duckterm\config.json'
$configBackup = Join-Path $temporary 'config.json.previous'
$configWasPresent = Test-Path -LiteralPath $configPath -PathType Leaf
if ($configWasPresent) { Copy-Item -LiteralPath $configPath -Destination $configBackup }
$previousTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$previousTaskXml = if ($null -ne $previousTask) { Export-ScheduledTask -TaskName $taskName } else { $null }
$previousTaskWasRunning = $null -ne $previousTask -and $previousTask.State -eq 'Running'
$previousConfig = if ($configWasPresent) {
  try { Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } catch { $null }
} else { $null }
$previousHost = if ($null -ne $previousConfig -and $null -ne $previousConfig.PSObject.Properties['host']) { [string]$previousConfig.PSObject.Properties['host'].Value } else { '' }
$previousPort = if ($null -ne $previousConfig -and $null -ne $previousConfig.PSObject.Properties['port']) { [int]$previousConfig.PSObject.Properties['port'].Value } else { 0 }
$effectiveHost = if ($Expose) { '0.0.0.0' } elseif ($previousHost) { $previousHost } else { '127.0.0.1' }
$effectivePortForFirewall = if ($Port -gt 0) { $Port } elseif ($previousPort -gt 0) { $previousPort } else { 1420 }
$needsFirewall = $effectiveHost -notin @('127.0.0.1', 'localhost', '::1')
$firewallRuleName = "DuckTerm Web LAN TCP $effectivePortForFirewall"
$firewallRuleWasPresent = $needsFirewall -and $null -ne (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)

try {
  if ($Tarball) {
    if (-not (Test-Path -LiteralPath $Tarball -PathType Leaf)) { throw "Local archive not found: $Tarball" }
    Copy-Item -LiteralPath $Tarball -Destination $archive
    if ($Sha256) {
      $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actual -ne $Sha256.ToLowerInvariant()) { throw "SHA256 mismatch (want $Sha256 got $actual)" }
      Write-Step 'sha256 verified'
    }
  } else {
    $suffix = if ($Flavor -eq 'tiny') { 'tiny' } else { "full-win32-$arch" }
    $asset = "duckterm-web-v$Version-$suffix.tar.gz"
    $releaseRoot = "https://github.com/$repository/releases/download/v$Version"
    $checksums = [string](Invoke-RestMethod -UseBasicParsing -Uri "$releaseRoot/SHA256SUMS")
    $match = [Regex]::Match($checksums, '(?m)^([0-9a-fA-F]{64})\s+\*?' + [Regex]::Escape($asset) + '\s*$')
    if (-not $match.Success) { throw "Release checksum is missing for $asset" }
    Invoke-WebRequest -UseBasicParsing -Uri "$releaseRoot/$asset" -OutFile $archive
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $match.Groups[1].Value.ToLowerInvariant()) { throw "SHA256 verification failed for $asset" }
    Write-Step 'sha256 verified'
  }

  & tar.exe -xzf $archive -C $stage
  if ($LASTEXITCODE -ne 0) { throw 'Could not extract the DuckTerm Web package.' }
  foreach ($required in @('package.json','duckterm.mjs','service-manager.mjs','dev-bridge.mjs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $required) -PathType Leaf)) { throw "Package is missing $required" }
  }
  $stagedNode = Join-Path $stage 'node\node.exe'
  if (-not (Test-Node $stagedNode)) { $stagedNode = $systemNode }
  if (-not $stagedNode) { throw 'No compatible Node >=22.5 and package has no bundled runtime.' }
  $packageVersion = (& $stagedNode -p "require(process.argv[1]).version" (Join-Path $stage 'package.json')).Trim()
  if ($packageVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Package version is invalid: $packageVersion" }
  if ($Version -and $packageVersion -ne $Version) { throw "Package version $packageVersion does not match requested $Version" }
  $reported = (& $stagedNode (Join-Path $stage 'duckterm.mjs') version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $reported -ne "duckterm-web $packageVersion") { throw 'Staged launcher failed its version check.' }

  Stop-WebTaskAndWait
  Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $AppDirectory) { Move-Item -LiteralPath $AppDirectory -Destination $backup }
  Move-Item -LiteralPath $stage -Destination $AppDirectory
  $activated = $true
  $node = Join-Path $AppDirectory 'node\node.exe'
  if (-not (Test-Node $node)) { $node = $systemNode }

  if ($Port -gt 0 -or $Expose) {
    $configArgs = @((Join-Path $AppDirectory 'duckterm.mjs'), 'config')
    if ($Expose) { $configArgs += '--lan' }
    if ($Port -gt 0) { $configArgs += @('--port', [string]$Port) }
    & $node @configArgs
    if ($LASTEXITCODE -ne 0) { throw 'Could not save the requested service configuration.' }
  }
  if (-not $NoService) {
    $previousReconcile = $env:DUCKTERM_RECONCILE_SERVICE
    $env:DUCKTERM_RECONCILE_SERVICE = '1'
    try {
      & $node (Join-Path $AppDirectory 'duckterm.mjs') service install
    } finally {
      $env:DUCKTERM_RECONCILE_SERVICE = $previousReconcile
    }
    if ($LASTEXITCODE -ne 0) { throw 'Could not install the Windows login task.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    $healthy = $false
    $effectivePort = if ($Port -gt 0) { $Port } else {
      $configPath = Join-Path $HOME '.duckterm\config.json'
      if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try { [int](Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).port } catch { 1420 }
      } else { 1420 }
    }
    while ([DateTime]::UtcNow -lt $deadline) {
      try {
        & curl.exe -kfsS --max-time 2 "https://localhost:$effectivePort/" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { & curl.exe -fsS --max-time 2 "http://localhost:$effectivePort/" 2>$null | Out-Null }
        if ($LASTEXITCODE -eq 0) { $healthy = $true; break }
      } catch {}
      Start-Sleep -Seconds 1
    }
    if (-not $healthy) { throw 'The installed service did not become healthy before the deadline.' }
  } else {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  }

  Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
  Write-Step "installed DuckTerm Web v$packageVersion in $AppDirectory"
  & $node (Join-Path $AppDirectory 'duckterm.mjs') status
} catch {
  if ($activated) {
    Write-Warning 'Installation failed; restoring the previous application.'
    Stop-WebTaskAndWait
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if ($needsFirewall -and -not $firewallRuleWasPresent) {
      Remove-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $AppDirectory -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $backup) {
      Move-Item -LiteralPath $backup -Destination $AppDirectory
    }
    if ($configWasPresent) {
      New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
      Copy-Item -LiteralPath $configBackup -Destination $configPath -Force
    } else {
      Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
    }
    if ($previousTaskXml) {
      Register-ScheduledTask -TaskName $taskName -Xml $previousTaskXml -Force | Out-Null
      if ($previousTaskWasRunning) { Start-ScheduledTask -TaskName $taskName }
    }
  }
  throw
} finally {
  Remove-Item -LiteralPath $temporary,$stage -Recurse -Force -ErrorAction SilentlyContinue
}
