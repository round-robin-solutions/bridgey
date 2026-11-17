#requires -Version 7.2
<#
.SYNOPSIS
  Builds and tests Bridgey by Round Robin for Windows: the RR CI windows lane (hosted windows-latest) runs this.

.DESCRIPTION
  1. bridgey_core.dll (rust/client) for x64 and Arm64, and its Rust tests.
  2. The C# unit tests (interop, view models, settings) against the x64 DLL.
  3. The app (WinUI 3, NativeAOT, self-contained, unpackaged) for each architecture, zipped.
  4. The UI tests on this desktop (x64): screenshots in light and dark, and pairing with a scripted peer.

  Everything lands in windows/out: the zips and SHA256SUMS, screenshots/, test-results/ (TRX) and logs/.
  Versions come from rr-edition.properties: BRIDGEY_VERSION_NAME and BRIDGEY_BUILD_NUMBER when a release sets them,
  else <next>-dev and the UTC build time (YYDDDHHMM).

.EXAMPLE
  pwsh -NoProfile -File scripts/rr/build-windows.ps1
  pwsh -NoProfile -File scripts/rr/build-windows.ps1 -Architectures x64 -SkipUiTests
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string[]] $Architectures = @('x64', 'arm64'),
    [switch] $SkipUiTests,
    [string] $Output = 'windows/out'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Out = if ([IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path $Root $Output }
$Logs = Join-Path $Out 'logs'
$Shots = Join-Path $Out 'screenshots'
$Results = Join-Path $Out 'test-results'
$Publish = Join-Path $Out 'publish'
foreach ($dir in @($Out, $Logs, $Shots, $Results, $Publish)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

function Write-Step([string] $Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }

# Runs a native command, copies its output to logs/<Log>, and stops on a non-zero exit.
function Invoke-Logged {
    param([Parameter(Mandatory)] [string] $Log, [Parameter(Mandatory)] [string] $Exe, [string[]] $Arguments = @())
    Write-Host "> $Exe $($Arguments -join ' ')"
    & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath (Join-Path $Logs $Log) -Append | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Exe exited with $LASTEXITCODE (see logs/$Log)" }
}

$started = [Diagnostics.Stopwatch]::StartNew()
$failed = $null
try {
    Write-Step 'Edition and version'
    $edition = @{}
    foreach ($line in Get-Content (Join-Path $Root 'rr-edition.properties')) {
        if ($line -match '^([A-Z0-9_]+)=(.*)$') { $edition[$Matches[1]] = $Matches[2] }
    }
    $now = [DateTime]::UtcNow
    $version = if ($env:BRIDGEY_VERSION_NAME) { $env:BRIDGEY_VERSION_NAME } else { "$($edition['EDITION_NEXT_VERSION'])-dev" }
    $build = if ($env:BRIDGEY_BUILD_NUMBER) { $env:BRIDGEY_BUILD_NUMBER } else { '{0:yy}{1:000}{0:HHmm}' -f $now, $now.DayOfYear }
    $env:BRIDGEY_VERSION_NAME = $version
    $env:BRIDGEY_BUILD_NUMBER = $build
    $prefix = $edition['EDITION_ASSET_PREFIX']
    Write-Host "$($edition['EDITION_DISPLAY_NAME']) $version, build $build"

    Write-Step '.NET SDK'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $hasSdk = $false
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        $hasSdk = [bool] (& dotnet --list-sdks | Where-Object { $_ -match '^10\.' })
    }
    if (-not $hasSdk) {
        $dotnetHome = Join-Path ($env:RUNNER_TEMP ?? $Out) 'dotnet'
        $installer = Join-Path $dotnetHome 'dotnet-install.ps1'
        New-Item -ItemType Directory -Force -Path $dotnetHome | Out-Null
        Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
        & $installer -Channel 10.0 -InstallDir $dotnetHome
        $env:DOTNET_ROOT = $dotnetHome
        $env:PATH = "$dotnetHome$([IO.Path]::PathSeparator)$env:PATH"
    }
    Invoke-Logged -Log 'dotnet.log' -Exe 'dotnet' -Arguments @('--info')

    Write-Step 'Rust: bridgey_core.dll and its tests'
    $rustTargets = @{ x64 = 'x86_64-pc-windows-msvc'; arm64 = 'aarch64-pc-windows-msvc' }
    if (-not (Get-Command clang -ErrorAction SilentlyContinue) -and (Test-Path 'C:\Program Files\LLVM\bin\clang.exe')) {
        # ring needs clang for Arm64 Windows.
        $env:PATH = "C:\Program Files\LLVM\bin;$env:PATH"
    }
    $manifest = Join-Path $Root 'rust/Cargo.toml'
    Invoke-Logged -Log 'rustup.log' -Exe 'rustup' -Arguments (@('target', 'add') + ($Architectures | ForEach-Object { $rustTargets[$_] }))
    if ($env:RR_CI_HOSTED -eq '1') {
        # A throwaway CI runner: the Connect test dials a QUIC tunnel to this machine's own network address. Allow the
        # test programs through Windows Firewall first, so a missing rule can't be why it fails. Never on anyone's own PC.
        $built = & cargo test -p bridgey-client --locked --no-run --message-format=json --manifest-path $manifest 2>$null
        if ($LASTEXITCODE -ne 0) { throw "cargo test --no-run failed ($LASTEXITCODE)" }
        foreach ($line in $built) {
            if ($line -notmatch '"executable":"([^"]+)"') { continue }
            $program = $Matches[1] -replace '\\\\', '\'
            & netsh advfirewall firewall add rule name="Bridgey CI test $(Split-Path -Leaf $program)" dir=in action=allow program="$program" enable=yes | Out-Null
        }
    }
    Invoke-Logged -Log 'cargo-test.log' -Exe 'cargo' -Arguments @('test', '-p', 'bridgey-client', '--locked', '--manifest-path', $manifest)
    $native = @{}
    foreach ($arch in $Architectures) {
        $target = $rustTargets[$arch]
        Invoke-Logged -Log "cargo-$arch.log" -Exe 'cargo' -Arguments @('build', '-p', 'bridgey-client', '--lib', '--release', '--locked', '--target', $target, '--manifest-path', $manifest)
        $native[$arch] = Join-Path $Root "rust/target/$target/release"
        if (-not (Test-Path (Join-Path $native[$arch] 'bridgey_core.dll'))) { throw "bridgey_core.dll for $arch was not built" }
    }
    Invoke-Logged -Log 'cargo-peer.log' -Exe 'cargo' -Arguments @('build', '-p', 'bridgey-client', '--example', 'peer', '--release', '--locked', '--manifest-path', $manifest)
    $peer = Join-Path $Root 'rust/target/release/examples/peer.exe'

    Push-Location (Join-Path $Root 'windows')
    try {
        Write-Step 'C# unit tests'
        $hostArch = if ($native.ContainsKey('x64')) { 'x64' } else { $Architectures[0] }
        Invoke-Logged -Log 'unit-tests.log' -Exe 'dotnet' -Arguments @('test', '--project', 'tests/Bridgey.Core.Tests', "-p:BridgeyNativeDir=$($native[$hostArch])", '--report-trx', '--results-directory', $Results)

        $sums = [System.Collections.Generic.List[string]]::new()
        foreach ($arch in $Architectures) {
            Write-Step "App for $arch (NativeAOT)"
            $platform = if ($arch -eq 'arm64') { 'ARM64' } else { 'x64' }
            $dest = Join-Path $Publish $arch
            if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
            Invoke-Logged -Log "publish-$arch.log" -Exe 'dotnet' -Arguments @(
                'publish', 'src/Bridgey.App/Bridgey.App.csproj', '-c', 'Release', '-r', "win-$arch", "-p:Platform=$platform",
                "-p:BridgeyNativeDir=$($native[$arch])", '-o', $dest)
            foreach ($file in @('Bridgey.exe', 'bridgey_core.dll', 'Assets/Bridgey.ico')) {
                if (-not (Test-Path (Join-Path $dest $file))) { throw "$file is missing from the $arch build" }
            }
            # The app's compiled XAML and resources: without its .pri, App.xaml cannot load and the app exits at start.
            $pri = @(Get-ChildItem $dest -Filter '*.pri' | Where-Object { $_.Name -in @('resources.pri', 'Bridgey.pri') })
            if ($pri.Count -eq 0) { throw "resources.pri is missing from the $arch build (found: $((Get-ChildItem $dest -Filter *.pri).Name -join ', '))" }

            # The zip holds one folder, named like the app, so it can be unpacked anywhere.
            $stage = Join-Path $Out "stage/$arch"
            $folder = Join-Path $stage $edition['EDITION_DISPLAY_NAME']
            if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            Copy-Item -Recurse -Path (Join-Path $dest '*') -Destination $folder
            Get-ChildItem $folder -Recurse -Include '*.pdb' | Remove-Item -Force
            $zip = Join-Path $Out "$prefix-$version-windows-$arch.zip"
            if (Test-Path $zip) { Remove-Item -Force $zip }
            Compress-Archive -Path $folder -DestinationPath $zip -CompressionLevel Optimal
            $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
            $sums.Add("$hash  $(Split-Path -Leaf $zip)")
            Write-Host ("{0}: {1:N1} MB" -f (Split-Path -Leaf $zip), ((Get-Item $zip).Length / 1MB))
        }
        Set-Content -Path (Join-Path $Out 'SHA256SUMS') -Value $sums -Encoding ascii

        if (-not $SkipUiTests -and $Architectures -contains 'x64') {
            Write-Step 'UI tests (x64): screenshots and pairing with the scripted peer'
            $env:BRIDGEY_APP_EXE = Join-Path $Publish 'x64/Bridgey.exe'
            if ($env:RR_CI_HOSTED -eq '1') {
                # A throwaway CI runner: allow both programs through Windows Firewall up front, so no security alert
                # covers the window in screenshots. Never done on anyone's own PC.
                foreach ($program in @($env:BRIDGEY_APP_EXE, $peer)) {
                    & netsh advfirewall firewall add rule name="Bridgey CI $(Split-Path -Leaf $program)" dir=in action=allow program="$program" enable=yes | Out-Null
                }
            }
            $env:BRIDGEY_PEER_EXE = $peer
            # The self-update test serves a signed copy of this zip from a local test feed.
            $env:BRIDGEY_UPDATE_ZIP = Join-Path $Out "$prefix-$version-windows-x64.zip"
            $env:BRIDGEY_SCREENSHOTS = $Shots
            # A smoke launch first: if the app dies at start, say how (exit code and Windows' error report).
            $smokeData = Join-Path ([IO.Path]::GetTempPath()) 'bridgey-ui-smoke'
            New-Item -ItemType Directory -Force -Path $smokeData | Out-Null
            $smoke = New-Object Diagnostics.ProcessStartInfo $env:BRIDGEY_APP_EXE
            $smoke.UseShellExecute = $false
            $smoke.Environment['BRIDGEY_DATA_DIR'] = $smokeData
            $smoke.Environment['BRIDGEY_PORT'] = '42459'
            $smokeStarted = [DateTime]::Now
            $process = [Diagnostics.Process]::Start($smoke)
            if ($process.WaitForExit(10000)) {
                Write-Host ("The app exited at start with 0x{0:X8}" -f $process.ExitCode) -ForegroundColor Red
                Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $smokeStarted.AddSeconds(-5) } -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProviderName -in @('Application Error', '.NET Runtime', 'Windows Error Reporting') } |
                    Select-Object -First 6 | ForEach-Object { Write-Host "--- $($_.ProviderName)`n$($_.Message)" }
                $smokeLog = Join-Path $smokeData 'bridgey.log'
                if (Test-Path $smokeLog) { Write-Host "--- bridgey.log"; Get-Content $smokeLog | Write-Host }
                throw 'The app exits at start'
            }
            $process.Kill()
            $process.WaitForExit(5000) | Out-Null
            Write-Host 'Smoke launch: the app stayed up for 10 s'
            Invoke-Logged -Log 'ui-tests.log' -Exe 'dotnet' -Arguments @('test', '--project', 'tests/Bridgey.UiTests', '--report-trx', '--results-directory', $Results)
            Write-Host "Screenshots: $((Get-ChildItem $Shots -Filter *.png).Name -join ', ')"
        }
    }
    finally {
        Pop-Location
    }
}
catch {
    $failed = $_
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
}
finally {
    # The app's own log from UI test profiles, if any, helps when a UI test fails.
    Get-ChildItem -Path ([IO.Path]::GetTempPath()) -Filter 'bridgey-ui-*' -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem $_.FullName -Filter 'bridgey.log' -ErrorAction SilentlyContinue } |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $Logs "app-$($_.Directory.Name).log") -ErrorAction SilentlyContinue }
    Write-Host ("`nTook {0:N0} s" -f $started.Elapsed.TotalSeconds)
}
if ($failed) { exit 1 }
exit 0
