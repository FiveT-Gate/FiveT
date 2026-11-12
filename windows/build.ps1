<#
.SYNOPSIS
  Builds FiveT for Windows into .\dist (x64) and .\dist-arm64. Add -Install to copy it into place, or
  -Installer to package it as FiveT-Setup-<version>.exe (x64) and FiveT-Setup-<version>-arm64.exe.

.DESCRIPTION
  Produces FiveT.exe (the tray app) and fivetctl.exe (CLI + MCP bridge).
  By default the build is self-contained (no .NET runtime needed on the target PC) and the two
  programs share one folder of runtime files. -FrameworkDependent makes a small build that needs the
  ".NET 8 Desktop Runtime" installed instead.

  Two architectures are built. x64 runs on every 64-bit PC, including ARM PCs (emulated). ARM64 runs
  natively on ARM PCs and, measured on a Snapdragon laptop, needs about a fifth of the memory and a
  ninth of the start-up CPU of the emulated x64 build, so ARM PCs should get that one.
    -Arch x64 | arm64 | both
  The default is both for -Installer (one setup file per architecture) and this PC's own architecture
  otherwise (so -Install puts the fast build on an ARM laptop). x64 goes to dist\, arm64 to dist-arm64\.

  -Install copies the build to C:\Program Files\FiveT when this shell is elevated (recommended: the login
  task runs FiveT as administrator, so the program files should not be writable by standard users),
  otherwise to %LOCALAPPDATA%\Programs\FiveT. It also creates a Start Menu shortcut.

  -Installer packages the build into .\release\FiveT-Setup-<version>[-arm64].exe with Inno Setup: one file
  the user double-clicks, which installs to Program Files, makes the Start Menu entry, registers the
  logon task and adds an Add/Remove Programs entry. Hand that file to whoever needs FiveT (x64 for
  Intel/AMD PCs, -arm64 for Snapdragon PCs; the x64 file also works on an ARM PC, just heavier).
  Needs Inno Setup 6; the script offers to install it with winget if it is missing.
  -Installer always builds FiveT.dll with -p:Distribution=true: the seeded credentials of
  src\FiveT\LocalSeeds.cs are left out, and the script stops if FiveT.dll still carries them.
  A plain build or -Install keeps them (for this PC only).

  OpenConnect is bundled: the files of the OpenConnect on this PC (-OpenConnectDir, by default
  C:\Program Files\OpenConnect) are copied to dist\openconnect\, which FiveT looks in first. So the
  setup file brings its own VPN engine and the PC it is installed on needs nothing else, like the Mac
  app's built-in openfortivpn (1.7). -NoOpenConnect leaves it out. (It is an x64 program; on an ARM PC
  it runs emulated whichever FiveT build is installed, and Wintun picks the ARM64 driver by itself.)

  Requires the .NET 8 SDK: https://dotnet.microsoft.com/download/dotnet/8.0
#>
param(
    [switch]$Install,
    [switch]$Installer,
    [switch]$FrameworkDependent,
    [switch]$NoOpenConnect,
    [string]$OpenConnectDir = (Join-Path $env:ProgramFiles "OpenConnect"),
    [ValidateSet("", "x64", "arm64", "both")][string]$Arch = "",
    # Older spelling of -Arch (win-x64 / win-arm64).
    [string]$Runtime = ""
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet SDK not found. Install .NET 8 SDK from https://dotnet.microsoft.com/download/dotnet/8.0"
}

if ($Runtime -and -not $Arch) { $Arch = $Runtime -replace '^win-', '' }
$hostArch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { "arm64" } else { "x64" }
if (-not $Arch) { $Arch = if ($Installer) { "both" } else { $hostArch } }
$flavors = if ($Arch -eq "both") { @("x64", "arm64") } else { @($Arch) }
if ($Install -and $flavors.Count -ne 1) { throw "-Install puts one build on this PC: use -Arch x64 or -Arch arm64 (or leave -Arch out for this PC's own)." }

$seeds = Join-Path $PSScriptRoot "src\FiveT\LocalSeeds.cs"
if (-not (Test-Path $seeds)) {
    Write-Host "▸ no LocalSeeds.cs: building with no seeded connections (add them in Settings → Connections)"
    Set-Content -Path $seeds -Value "namespace FiveT;`n`ninternal static partial class LocalSeeds`n{`n    public static List<Connection> Connections() => new();`n}`n"
}

# LocalSeeds.cs holds real passwords and TOTP secrets that get compiled into FiveT.dll. A build for
# this PC (plain, or -Install) keeps them; a setup file is handed to other people, so -Installer builds
# with -p:Distribution=true (FiveT.csproj then compiles LocalSeedsEmpty.cs instead), and this proves
# it worked: LocalSeedsEmpty.cs stamps the assembly with "FiveT.NoLocalSeeds".
function Assert-NoLocalSeeds([string]$dll) {
    if (-not (Test-Path $dll)) { throw "$dll is missing: cannot check it for seeded credentials." }
    $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($dll))
    if (-not $text.Contains("FiveT.NoLocalSeeds")) {
        throw "$dll was built with LocalSeeds.cs (real credentials inside). Refusing to package it: build with -p:Distribution=true (build.ps1 -Installer does that)."
    }
}

function Get-DistDir([string]$arch) { Join-Path $PSScriptRoot $(if ($arch -eq "x64") { "dist" } else { "dist-$arch" }) }

function Build-Flavor([string]$arch) {
    $rid = "win-$arch"
    $dist = Get-DistDir $arch
    if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }

    # Reproducible, no .pdb, no local path in the binaries (PathMap turns this folder into /src).
    $common = @("-c", "Release", "-r", $rid, "-o", $dist, "-p:DebugType=none", "-p:Deterministic=true", "-p:ContinuousIntegrationBuild=true", "-p:PathMap=$PSScriptRoot=/src")
    if ($FrameworkDependent) { $common += "--self-contained"; $common += "false" }
    else { $common += "--self-contained"; $common += "true" }

    $fivetOnly = @()
    # The WinUI project builds per platform; x64 is what its project file says, ARM64 is asked for here.
    if ($arch -eq "arm64") { $fivetOnly += "-p:Platform=ARM64" }
    if ($Installer) {
        $fivetOnly += "-p:Distribution=true"
        Write-Host "▸ distribution build (-p:Distribution=true): LocalSeeds.cs is left out, no seeded credentials in FiveT.dll"
    } elseif ((Get-Content $seeds -Raw) -match 'new\s+Connection') {
        Write-Host "▸ note: this build contains the seeded connections of LocalSeeds.cs, so it is for this PC only (-Installer leaves them out)"
    }

    Write-Host "▸ publishing FiveT.exe ($rid, $(if ($FrameworkDependent) {'framework-dependent'} else {'self-contained'}))"
    # Out-Host: a function's output is its return value, and this one returns the folder.
    dotnet publish src/FiveT/FiveT.csproj @common @fivetOnly | Select-Object -Last 2 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish of FiveT.exe ($rid) failed (exit code $LASTEXITCODE)" }
    if ($Installer) { Assert-NoLocalSeeds (Join-Path $dist "FiveT.dll") }
    Write-Host "▸ publishing fivetctl.exe ($rid)"
    dotnet publish src/fivetctl/fivetctl.csproj @common | Select-Object -Last 2 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish of fivetctl.exe ($rid) failed (exit code $LASTEXITCODE)" }

    if (-not $NoOpenConnect) {
        $oc = Join-Path $OpenConnectDir "openconnect.exe"
        if (Test-Path $oc) {
            Write-Host "▸ bundling OpenConnect from $OpenConnectDir"
            $ocDist = Join-Path $dist "openconnect"
            New-Item -ItemType Directory -Force -Path $ocDist | Out-Null
            # What openconnect.exe needs at run time: itself, its DLLs (GnuTLS, libxml2, …, wintun.dll)
            # and the script that sets routes and DNS. Not its uninstaller or shortcuts.
            Get-ChildItem $OpenConnectDir -File | Where-Object {
                $_.Name -eq "openconnect.exe" -or $_.Extension -eq ".dll" -or $_.Name -eq "vpnc-script-win.js"
            } | Copy-Item -Destination $ocDist
            @"
OpenConnect for Windows, bundled with FiveT so the PC needs nothing else.
OpenConnect is free software under the GNU LGPL 2.1: https://www.infradead.org/openconnect/
Source code: https://gitlab.com/openconnect/openconnect
wintun.dll is the prebuilt Wintun driver from https://www.wintun.net (redistributable as shipped).
"@ | Set-Content (Join-Path $ocDist "README.txt") -Encoding utf8
            $ocMb = [math]::Round(((Get-ChildItem $ocDist -File | Measure-Object Length -Sum).Sum / 1MB), 1)
            Write-Host "  $((Get-ChildItem $ocDist -File).Count) files, $ocMb MB"
        } else {
            Write-Warning "OpenConnect not found at ${OpenConnectDir}: this build does not bring its own. Install it there, pass -OpenConnectDir, or -NoOpenConnect to silence this."
        }
    }
    # The VPN programs (Xray for V2Ray and Outline, OpenVPN), fetched once and checked against pinned SHA-256s.
    $engines = Join-Path $PSScriptRoot "engines\$arch"
    if (-not (Test-Path (Join-Path $engines "VERSION"))) {
        & (Join-Path $PSScriptRoot "Tools\fetch-engines.ps1") -Arch $arch
    }
    Write-Host "▸ bundling $((Get-Content (Join-Path $engines 'VERSION') -Raw).Trim())"
    Copy-Item (Join-Path $engines "xray") (Join-Path $dist "xray") -Recurse
    Copy-Item (Join-Path $engines "openvpn") (Join-Path $dist "openvpn") -Recurse
    Write-Host "✓ built ($arch): $dist"
    return $dist
}

function Install-Flavor([string]$dist) {
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $target = if ($elevated) { Join-Path $env:ProgramFiles "FiveT" } else { Join-Path $env:LOCALAPPDATA "Programs\FiveT" }
    Write-Host "▸ installing to $target"
    Get-Process -Name "FiveT" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  stopping running FiveT (pid $($_.Id))"
        try { $_.CloseMainWindow() | Out-Null } catch {}
        if (-not $_.WaitForExit(10000)) { Stop-Process -Id $_.Id -Force }
        # The copy below fails with "file in use" until the old exe has really gone.
        $_.WaitForExit(5000) | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -Path (Join-Path $dist "*") -Destination $target -Recurse -Force

    $startMenu = Join-Path ([Environment]::GetFolderPath("Programs")) "FiveT.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($startMenu)
    $lnk.TargetPath = Join-Path $target "FiveT.exe"
    $lnk.WorkingDirectory = $target
    $lnk.Description = "FiveT — FortiGate SSL-VPN"
    $lnk.Save()

    Write-Host "✓ installed: $target"
    Write-Host "  Start it from the Start Menu (FiveT). If the login task was created for an older path, turn Start FiveT at login off and on again in Settings → General."
    if (-not $elevated) {
        Write-Host "  Note: installed per-user. For a system-wide install under Program Files, run this script from an elevated PowerShell."
    }
}

# Inno Setup 6 builds the setup exe. It is the only extra tool this repository needs.
# 6.7 installs per-user under LOCALAPPDATA; older builds go to Program Files.
function Find-Iscc {
    $places = @((Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
                # Not set in a native ARM64 PowerShell (Join-Path would throw on null).
                $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe" }),
                (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"))
    foreach ($p in $places) { if ($p -and (Test-Path $p)) { return $p } }
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Package-Flavor([string]$arch, [string]$dist, [string]$iscc, [string]$version) {
    # Checked again right before packaging: this is the file that gets handed to other people.
    Assert-NoLocalSeeds (Join-Path $dist "FiveT.dll")

    $release = Join-Path $PSScriptRoot "release"
    New-Item -ItemType Directory -Force -Path $release | Out-Null
    $name = if ($arch -eq "x64") { "FiveT-Setup-$version.exe" } else { "FiveT-Setup-$version-$arch.exe" }
    $setup = Join-Path $release $name
    if (Test-Path $setup) { Remove-Item $setup -Force }

    Write-Host "▸ packaging $name"
    & $iscc /Qp "/DAppVersion=$version" "/DArch=$arch" "/DSourceDir=$dist" "/DOutputDir=$release" (Join-Path $PSScriptRoot "installer\FiveT.iss")
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }
    if (-not (Test-Path $setup)) { throw "Inno Setup reported success but $setup is missing" }

    $folderMb = [math]::Round(((Get-ChildItem $dist -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
    $setupMb = [math]::Round(((Get-Item $setup).Length / 1MB), 1)
    # Printed so a shared build can be checked against what was actually published.
    $sha = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLower()

    Write-Host "✓ installer ($arch): $setup"
    Write-Host "  $setupMb MB to download, $folderMb MB installed"
    Write-Host "  sha256: $sha"
    Write-Host "  Test it with:  & '$setup'          (unattended:  & '$setup' /VERYSILENT)"
}

$built = @{}
foreach ($f in $flavors) { $built[$f] = Build-Flavor $f }

if ($Install) { Install-Flavor $built[$flavors[0]] }

if ($Installer) {
    # Version comes from Directory.Build.props, the same place the assembly gets it from.
    $props = [xml](Get-Content (Join-Path $PSScriptRoot "Directory.Build.props"))
    $version = $props.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
    if (-not $version) { throw "No <Version> in Directory.Build.props" }

    $iscc = Find-Iscc
    if (-not $iscc) {
        Write-Host "▸ Inno Setup 6 is not installed; installing it with winget"
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw "Inno Setup 6 is required to build the installer. Install it from https://jrsoftware.org/isdl.php and run this again."
        }
        winget install --id JRSoftware.InnoSetup --exact --silent --accept-package-agreements --accept-source-agreements
        $iscc = Find-Iscc
        if (-not $iscc) { throw "Inno Setup was installed but ISCC.exe was not found. Open a new shell and run this again." }
    }

    foreach ($f in $flavors) { Package-Flavor $f $built[$f] $iscc $version }
}
