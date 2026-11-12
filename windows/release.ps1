<#
.SYNOPSIS
  Cuts a new Windows release:  .\release.ps1 1.3.1

.DESCRIPTION
  Stamps the version into Directory.Build.props, then builds dist\ and packages
  release\FiveT-Setup-<version>.exe by calling build.ps1 -Installer.

  It publishes nothing. Upload the setup files to a GitHub release tagged windows-v<version> (never
  marked "latest": that is the Mac app's update feed) and update latest-windows.json on the rolling
  windows-feed release with each file's SHA-256 and signature; see README.md, section "Updates".
  A setup file installs over an existing copy and keeps its connections.

  -SkipBuild reuses whatever is already in dist\ (to re-package without rebuilding).
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$SkipBuild
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if ($Version -notmatch '^\d+\.\d+(\.\d+)?$') { throw "Version must look like 1.3.1, not '$Version'" }

$propsPath = Join-Path $PSScriptRoot "Directory.Build.props"
$text = Get-Content $propsPath -Raw
$text = $text -replace '<Version>[^<]*</Version>', "<Version>$Version</Version>"
# Directory.Build.props is UTF-8 with a BOM so Windows PowerShell 5.1 reads the © in it correctly.
[System.IO.File]::WriteAllText($propsPath, $text, (New-Object System.Text.UTF8Encoding $true))
Write-Host "▸ FiveT $Version"

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot "build.ps1") -Installer
    if ($LASTEXITCODE -ne 0) { throw "build.ps1 -Installer failed" }
}

$setup = Join-Path $PSScriptRoot "release\FiveT-Setup-$Version.exe"
if (-not (Test-Path $setup)) { throw "Missing $setup - run without -SkipBuild" }

# The setup file goes to other people, so the FiveT.dll behind it must be a distribution build (build.ps1
# -Installer makes one: -p:Distribution=true leaves LocalSeeds.cs, with its real credentials, out and stamps
# the assembly "FiveT.NoLocalSeeds"). With -SkipBuild nothing was built here, so check what dist\ holds.
$dll = Join-Path $PSScriptRoot "dist\FiveT.dll"
if (-not (Test-Path $dll)) { throw "Missing $dll - run without -SkipBuild" }
$dllText = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($dll))
if (-not $dllText.Contains("FiveT.NoLocalSeeds")) {
    throw "dist\FiveT.dll contains the seeded credentials of LocalSeeds.cs (it was not built by build.ps1 -Installer). Do not share $setup; run release.ps1 without -SkipBuild."
}

$mb = [math]::Round(((Get-Item $setup).Length / 1MB), 1)
Write-Host "OK  FiveT $Version packaged ($mb MB)"
Write-Host "  installer: $setup"
Write-Host ""
Write-Host "Next:"
Write-Host "  1. Install it here and check the app still connects:  & '$setup'"
Write-Host "  2. Upload it to a windows-v$Version release and update the signed feed (README.md, section Updates)."
Write-Host "  3. Commit:  git add -A; git commit -m 'Windows $Version'"
