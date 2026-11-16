#requires -Version 7.2
<#
.SYNOPSIS
  The Windows half of a Bridgey by Round Robin release or nightly, on an RR CI Windows runner (hosted
  windows-latest): the x64 and Arm64 zips for the version scripts/rr/ci-release.sh then publishes.

.DESCRIPTION
  pwsh -NoProfile -File scripts/rr/ci-release-windows.ps1 -Mode nightly -Output <dir>
  pwsh -NoProfile -File scripts/rr/ci-release-windows.ps1 -Mode tag -Output <dir>     beta or stable from RR_CI_REF

  Builds with scripts/rr/build-windows.ps1 (the verify lane ran the UI tests on this revision, so they are skipped
  here). The output holds the two zips under fixed names (Bridgey-RR-windows-x64.zip, ...-arm64.zip), SHA256SUMS, release.env (the time, channel, version name, build number, tag
  and revision; ci-release.sh refuses a different revision or version), windows.build-info (the toolchains) and
  windows-rust-dependencies.txt (cargo tree for the Windows target, for the SBOM). RR_CI_RELEASE_NOW, when set,
  gives the release time so a separate Mac job derives the same version. No secrets: the zips are signed with the
  release key when ci-release.sh assembles the release.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('nightly', 'tag')] [string] $Mode,
    [Parameter(Mandatory)] [string] $Output
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$python = if (Get-Command python3 -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }

if ($Mode -eq 'nightly') {
    $versionArgs = @('nightly')
}
else {
    $ref = $env:RR_CI_REF
    if (-not $ref -or -not $ref.StartsWith('refs/tags/v')) { throw "RR_CI_REF must name the release tag (got '$ref')" }
    $version = $ref.Substring('refs/tags/v'.Length)
    $channel = if ($version -match '^\d+\.\d+\.\d+-beta\.\d+$') { 'beta' } elseif ($version -match '^\d+\.\d+\.\d+$') { 'stable' } else { throw "v$version is neither a stable nor a beta tag" }
    $versionArgs = @($channel, '--version', $version)
}
$now = if ($env:RR_CI_RELEASE_NOW) { $env:RR_CI_RELEASE_NOW } else { [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:00Z") }
$lines = & $python (Join-Path $Root 'scripts/rr/rrrelease.py') version @versionArgs --now $now
if ($LASTEXITCODE -ne 0) { throw 'rrrelease.py version failed' }
$values = @{}
foreach ($line in $lines) { if ($line -match '^([A-Z_]+)=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim("'") } }
$env:BRIDGEY_VERSION_NAME = $values['VERSION_NAME']
$env:BRIDGEY_BUILD_NUMBER = $values['BUILD_NUMBER']
Write-Host "== Windows for $($values['CHANNEL']) $($values['VERSION_NAME']) build $($values['BUILD_NUMBER'])"

$build = Join-Path ([IO.Path]::GetTempPath()) "bridgey-windows-release"
if (Test-Path $build) { Remove-Item -Recurse -Force $build }
& pwsh -NoProfile -File (Join-Path $Root 'scripts/rr/build-windows.ps1') -SkipUiTests -Output $build
if ($LASTEXITCODE -ne 0) { throw "build-windows.ps1 failed ($LASTEXITCODE)" }

New-Item -ItemType Directory -Force -Path $Output | Out-Null
# Fixed names, as the Mac job's Bridgey-RR-macOS.dmg: RR CI hands files to the publishing job by exact name, and
# release.sh puts the version back in the names it publishes.
$prefix = ((Get-Content (Join-Path $Root 'rr-edition.properties')) -match '^EDITION_ASSET_PREFIX=' | Select-Object -First 1) -replace '^EDITION_ASSET_PREFIX=', ''
$sums = foreach ($arch in @('x64', 'arm64')) {
    $zip = Get-ChildItem $build -Filter "*-windows-$arch.zip" | Select-Object -First 1
    if (-not $zip) { throw "build-windows.ps1 made no $arch zip" }
    $name = "$prefix-windows-$arch.zip"
    Copy-Item $zip.FullName (Join-Path $Output $name)
    "$((Get-FileHash -Algorithm SHA256 (Join-Path $Output $name)).Hash.ToLowerInvariant())  $name"
}
Set-Content -Path (Join-Path $Output 'SHA256SUMS') -Value $sums -Encoding ascii
$revision = (& git -C $Root rev-parse HEAD).Trim()
@(
    "NOW=$now", "CHANNEL=$($values['CHANNEL'])", "VERSION_NAME=$($values['VERSION_NAME'])", "BUILD_NUMBER=$($values['BUILD_NUMBER'])",
    "TAG=$($values['TAG'])", "REVISION=$revision"
) | Set-Content -Path (Join-Path $Output 'release.env') -Encoding ascii
$dotnet = (& dotnet --version).Trim()
$rust = (& rustc --version).Trim()
@("host=$env:COMPUTERNAME", "os=$([Environment]::OSVersion.VersionString)", "dotnet=$dotnet", "rust=$rust") |
    Set-Content -Path (Join-Path $Output 'windows.build-info') -Encoding ascii
& cargo tree -p bridgey-client --target x86_64-pc-windows-msvc -e normal --prefix none --manifest-path (Join-Path $Root 'rust/Cargo.toml') |
    Sort-Object -Unique | Set-Content -Path (Join-Path $Output 'windows-rust-dependencies.txt') -Encoding utf8
Get-ChildItem $Output | ForEach-Object { Write-Host ("{0}: {1:N1} MB" -f $_.Name, ($_.Length / 1MB)) }
