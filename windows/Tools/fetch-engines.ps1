<#
.SYNOPSIS
  Fetches the VPN programs FiveT for Windows ships with, each checked against a pinned SHA-256, into
  ..\engines\<arch>\ (git-ignored). build.ps1 runs this when that folder is missing and copies it into dist\.

.DESCRIPTION
  The counterpart of the Mac's Tools/fetch-xray.sh and Tools/build-openvpn.sh.

    xray\      Xray-core, the project's own release build (github.com/XTLS/Xray-core), with the wintun.dll
               it ships, and geoip-lite.dat: the Iranian and private address ranges its routing sends direct
               (github.com/Chocolate4U/Iran-v2ray-rules, the same file the Mac app pins).
    openvpn\   OpenVPN 2.6.23 (the Mac app's version): openvpn.exe, its OpenSSL DLLs and tapctl.exe as built
               by the OpenVPN project's own CI for the release commit, plus the two signed network drivers
               from the project's GitHub releases (ovpn-dco-win, tap-windows6).

  Why the CI build and not the official installer: openvpn.net was not reachable from the build PC, and the
  installer would also bring a GUI and services FiveT does not use. GitHub keeps CI artifacts for a limited
  time; when the pinned one is gone, install the official OpenVPN 2.6.x (https://openvpn.net/community/),
  copy bin\openvpn.exe, bin\tapctl.exe and bin\*.dll into engines\<arch>\openvpn\ by hand, and update the
  pins below. Downloading the artifact needs the GitHub CLI (gh), signed in.

  A file that does not match its SHA-256 is deleted and the script stops. Nothing is ever run from a
  download before its checksum has been checked.
#>
param(
    [ValidateSet("x64", "arm64", "both")][string]$Arch = "both",
    [switch]$Force
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path $PSScriptRoot -Parent
$cache = Join-Path $root "engines\downloads"
New-Item -ItemType Directory -Force -Path $cache | Out-Null

# ---- Pins -------------------------------------------------------------------------------------
$XrayVersion = "26.10.31"   # the Mac pins 26.10.29, which its authors have since replaced with this one
$Xray = @{
    x64   = @{ File = "Xray-windows-64.zip";        Sha = "2e04a9995a6f2ad1b28c0bb25c708ecb2695e43a1c9c7889c4b6ac2b48cf7a6a" }
    arm64 = @{ File = "Xray-windows-arm64-v8a.zip"; Sha = "db062e8a177facacc8ae53d4c9c0df4132b13fc3a89acda6f21d92d36633077e" }
}
$GeoRelease = "202611101256"
$GeoSha = "1f443cc645af8d77d371546bb0dfb21dbd5260fda40a11549b44a2b08c28ec5d"

$OpenVpnVersion = "2.6.23"
$OpenVpnCommit = "49620843c4"   # tag v2.6.23; CI run 35863514949 of OpenVPN/openvpn
$OpenVpn = @{
    x64   = @{ Artifact = "10752361741"; Name = "openvpn-msvc-amd64"; Sha = "4cd1a1a3c48de49edf33c151dc8877dd2486dcaeeeb1df9a77d10b70869ecc71"; Dir = "build/win-amd64-release" }
    arm64 = @{ Artifact = "10752336599"; Name = "openvpn-msvc-arm64"; Sha = "c8f9d8ae459a4dfa95dea8d50ebc0fa0cb1712a0f61f3da67bdefda34f94f030"; Dir = "build/win-arm64-release" }
}
$DcoVersion = "2.8.14"
$Dco = @{
    amd64 = "425487f4c7d28911b66edab8a7f8f01bd67f4aad999d4a585ea0779b7299f074"
    arm64 = "11ab23c056c257ea4cda0caed3373cdc62b6f4b1c57482ccbafed6b2f670c724"
}
$TapVersion = "9.27.0"
$TapSha = "36e2609b7ceefedcb978ce5c48caf9e0e5af83423717c4e2e3c1d7ebca8f62a5"
# -----------------------------------------------------------------------------------------------

function Get-Sha([string]$path) { (Get-FileHash $path -Algorithm SHA256).Hash.ToLower() }

# Downloads $url to the cache as $name (kept for next time) and checks it against $sha.
function Fetch([string]$sha, [string]$url, [string]$name) {
    $path = Join-Path $cache $name
    if (-not (Test-Path $path) -or (Get-Sha $path) -ne $sha) {
        Write-Host "▸ downloading $name"
        Invoke-WebRequest -Uri $url -OutFile "$path.part" -UseBasicParsing
        Move-Item "$path.part" $path -Force
    }
    if ((Get-Sha $path) -ne $sha) {
        Remove-Item $path -Force
        throw "$name does not match its SHA-256; deleted, run again"
    }
    return $path
}

# A build artifact of OpenVPN's own CI, through the GitHub CLI (artifacts need a signed-in account).
function Fetch-Artifact([string]$sha, [string]$id, [string]$name) {
    $path = Join-Path $cache "$name-$OpenVpnVersion.zip"
    if (-not (Test-Path $path) -or (Get-Sha $path) -ne $sha) {
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if (-not $gh) { $gh = Get-Command (Join-Path $env:ProgramFiles "GitHub CLI\gh.exe") -ErrorAction SilentlyContinue }
        if (-not $gh) { throw "The GitHub CLI (gh) is needed to download OpenVPN's CI build. See the notes at the top of this script." }
        Write-Host "▸ downloading $name (OpenVPN $OpenVpnVersion, CI build of $OpenVpnCommit)"
        & $gh.Source api "repos/OpenVPN/openvpn/actions/artifacts/$id/zip" --method GET -H "Accept: application/vnd.github+json" > "$path.part"
        if ($LASTEXITCODE -ne 0) { Remove-Item "$path.part" -Force -ErrorAction SilentlyContinue; throw "GitHub did not hand out artifact $id (expired?). See the notes at the top of this script." }
        Move-Item "$path.part" $path -Force
    }
    if ((Get-Sha $path) -ne $sha) {
        Remove-Item $path -Force
        throw "$name does not match its SHA-256; deleted, run again"
    }
    return $path
}

function Expand([string]$zip, [string]$to) {
    if (Test-Path $to) { Remove-Item $to -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $to)
}

$geo = Fetch $GeoSha "https://github.com/Chocolate4U/Iran-v2ray-rules/releases/download/$GeoRelease/geoip-lite.dat" "geoip-lite-$GeoRelease.dat"
$tapZip = Fetch $TapSha "https://github.com/OpenVPN/tap-windows6/releases/download/$TapVersion/dist.win10.zip" "tap-windows6-$TapVersion-dist.win10.zip"
$dcoZips = @{}
foreach ($a in "amd64", "arm64") {
    $dcoZips[$a] = Fetch $Dco[$a] "https://github.com/OpenVPN/ovpn-dco-win/releases/download/$DcoVersion/ovpn-dco-win-$DcoVersion-$a.zip" "ovpn-dco-win-$DcoVersion-$a.zip"
}
$license = Join-Path $cache "openvpn-$OpenVpnVersion-COPYING.txt"
if (-not (Test-Path $license)) {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/OpenVPN/openvpn/v$OpenVpnVersion/COPYING" -OutFile $license -UseBasicParsing
}

$flavors = if ($Arch -eq "both") { @("x64", "arm64") } else { @($Arch) }
foreach ($f in $flavors) {
    $out = Join-Path $root "engines\$f"
    if ((Test-Path (Join-Path $out "VERSION")) -and -not $Force -and
        (Get-Content (Join-Path $out "VERSION") -Raw).Trim() -eq "xray $XrayVersion, openvpn $OpenVpnVersion, geoip $GeoRelease, dco $DcoVersion, tap $TapVersion") {
        Write-Host "✓ engines\$f is up to date"
        continue
    }
    $tmp = "$out.tmp"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Force -Path "$tmp\xray", "$tmp\openvpn" | Out-Null

    # ---- Xray: the program, its tunnel driver loader and its license. The zip's own geoip.dat and
    # geosite.dat (11 MB) are not used: FiveT's routing reads only geoip-lite.dat.
    $zip = Fetch $Xray[$f].Sha "https://github.com/XTLS/Xray-core/releases/download/v$XrayVersion/$($Xray[$f].File)" "xray-$XrayVersion-$($Xray[$f].File)"
    Expand $zip "$tmp\unzip"
    Copy-Item "$tmp\unzip\xray.exe", "$tmp\unzip\wintun.dll" "$tmp\xray"
    Copy-Item "$tmp\unzip\LICENSE" "$tmp\xray\Xray-core-LICENSE.txt"
    Copy-Item "$tmp\unzip\LICENSE-Wintun" "$tmp\xray\Wintun-LICENSE.txt"
    Copy-Item $geo "$tmp\xray\geoip-lite.dat"
    Remove-Item "$tmp\unzip" -Recurse -Force
    @"
Xray-core $XrayVersion (https://github.com/XTLS/Xray-core), Mozilla Public License 2.0: the unmodified
release build $($Xray[$f].File), whose source is at the link above (tag v$XrayVersion).

wintun.dll, as shipped in that release (https://www.wintun.net): see Wintun-LICENSE.txt.

geoip-lite.dat (release $GeoRelease of https://github.com/Chocolate4U/Iran-v2ray-rules), GNU GPL 3.0:
Iranian and private IP address ranges, read by Xray to send those addresses direct.
"@ | Set-Content "$tmp\xray\NOTICE.txt" -Encoding utf8

    # ---- OpenVPN: the program, the DLLs it loads, tapctl (creates its adapter) and both drivers for
    # both kinds of PC (an x64 FiveT on an ARM PC needs the ARM64 driver; they are small).
    Expand (Fetch-Artifact $OpenVpn[$f].Sha $OpenVpn[$f].Artifact $OpenVpn[$f].Name) "$tmp\unzip"
    $bin = Join-Path "$tmp\unzip" $OpenVpn[$f].Dir
    Copy-Item "$bin\Release\openvpn.exe", "$bin\src\tapctl\Release\tapctl.exe" "$tmp\openvpn"
    Get-ChildItem "$bin\Release\*.dll" | Where-Object { $_.Name -ne "cmocka.dll" } | Copy-Item -Destination "$tmp\openvpn"
    Remove-Item "$tmp\unzip" -Recurse -Force
    Expand $tapZip "$tmp\tap"
    foreach ($a in "amd64", "arm64") {
        Expand $dcoZips[$a] "$tmp\dco"
        foreach ($w in "win10", "win11") {
            New-Item -ItemType Directory -Force -Path "$tmp\openvpn\drivers\$a\dco-$w" | Out-Null
            Copy-Item "$tmp\dco\$w\*" "$tmp\openvpn\drivers\$a\dco-$w"
        }
        Remove-Item "$tmp\dco" -Recurse -Force
        New-Item -ItemType Directory -Force -Path "$tmp\openvpn\drivers\$a\tap" | Out-Null
        Copy-Item "$tmp\tap\dist.win10\$a\OemVista.inf", "$tmp\tap\dist.win10\$a\tap0901.cat", "$tmp\tap\dist.win10\$a\tap0901.sys" "$tmp\openvpn\drivers\$a\tap"
    }
    Remove-Item "$tmp\tap" -Recurse -Force
    Copy-Item $license "$tmp\openvpn\OpenVPN-COPYING.txt"
    @"
OpenVPN $OpenVpnVersion (https://github.com/OpenVPN/openvpn), GNU GPL v2 with an exception for linking
OpenSSL (see OpenVPN-COPYING.txt): openvpn.exe, tapctl.exe and the OpenSSL and pkcs11-helper DLLs are the
unmodified build $($OpenVpn[$f].Name) made by the OpenVPN project's own CI for commit $OpenVpnCommit
(tag v$OpenVpnVersion). Source: the link above. OpenSSL: Apache License 2.0 (https://www.openssl.org).

drivers\*\dco-*: ovpn-dco-win $DcoVersion (https://github.com/OpenVPN/ovpn-dco-win), MIT, signed by OpenVPN Inc.
drivers\*\tap:   tap-windows6 $TapVersion (https://github.com/OpenVPN/tap-windows6), GPL v2, signed by OpenVPN Inc.
"@ | Set-Content "$tmp\openvpn\NOTICE.txt" -Encoding utf8

    # What they are: the right architecture, and programs that report the pinned versions (run only on a
    # PC that can run them: an ARM64 program does not start on an Intel PC).
    $hostArm = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64'
    if ($f -eq "x64" -or $hostArm) {
        $v = (& "$tmp\xray\xray.exe" version | Select-Object -First 1)
        if ($v -notmatch "^Xray $([regex]::Escape($XrayVersion)) ") { throw "xray.exe ($f) does not report version $XrayVersion ($v)" }
        $v = (& "$tmp\openvpn\openvpn.exe" --version | Select-Object -First 1)
        if ($v -notmatch "^OpenVPN $([regex]::Escape($OpenVpnVersion)) ") { throw "openvpn.exe ($f) does not report version $OpenVpnVersion ($v)" }
        # The routing FiveT gives Xray needs the two categories of the address list.
        '{"log":{"loglevel":"none"},"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[{"ip":["ext:geoip-lite.dat:ir","ext:geoip-lite.dat:private"],"outboundTag":"direct"}]}}' |
            Set-Content "$tmp\check.json" -Encoding ascii
        $env:XRAY_LOCATION_ASSET = "$tmp\xray"
        & "$tmp\xray\xray.exe" run -test -c "$tmp\check.json" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "xray.exe ($f) cannot read geoip-lite.dat" }
        Remove-Item Env:\XRAY_LOCATION_ASSET
        Remove-Item "$tmp\check.json" -Force
    }
    foreach ($sys in Get-ChildItem "$tmp\openvpn\drivers" -Recurse -Filter *.sys) {
        $sig = Get-AuthenticodeSignature $sys.FullName
        if ($sig.Status -ne "Valid") { throw "$($sys.FullName) is not validly signed ($($sig.Status))" }
    }

    "xray $XrayVersion, openvpn $OpenVpnVersion, geoip $GeoRelease, dco $DcoVersion, tap $TapVersion" | Set-Content "$tmp\VERSION" -Encoding ascii
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    Move-Item $tmp $out
    $mb = [math]::Round(((Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
    Write-Host "✓ engines\$f ($mb MB): Xray $XrayVersion, OpenVPN $OpenVpnVersion"
}
