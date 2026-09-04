# Build a Windows x64 Release package of XMRig (MSVC or MinGW/GCC).
# Requires: CMake, plus either Visual Studio C++ tools or a MinGW-w64 GCC (e.g. WinLibs).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1 -DepsDir C:\xmrig-deps
#
# Output:
#   release\xmrig-<version>-windows-x64\   runnable folder
#   release\xmrig-<version>-windows-x64.zip

[CmdletBinding()]
param(
    [string]$DepsDir = "",
    [string]$Generator = "",
    [string]$VsYear = "",
    [int]$Jobs = 2
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Find-CMake {
    $cmd = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @(
        "${env:ProgramFiles}\CMake\bin\cmake.exe",
        "${env:ProgramFiles(x86)}\CMake\bin\cmake.exe"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    throw "CMake not found. Install it from https://cmake.org/download/ and add it to PATH."
}

function Find-MinGW {
    $gcc = Get-Command gcc -ErrorAction SilentlyContinue
    if (-not $gcc) { return $null }
    $binDir = Split-Path $gcc.Source
    $make = Join-Path $binDir "mingw32-make.exe"
    if (-not (Test-Path $make)) {
        $makeCmd = Get-Command mingw32-make -ErrorAction SilentlyContinue
        if ($makeCmd) { $make = $makeCmd.Source }
    }
    if (-not (Test-Path $make)) { return $null }
    return @{ Gcc = $gcc.Source; Make = $make; BinDir = $binDir }
}

function Find-Toolchain {
    param([string]$PreferredYear)

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($installPath) {
            $vsVersion = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property catalog_productLineVersion
            if ($PreferredYear) { $vsVersion = $PreferredYear }
            $gen = switch ("$vsVersion") {
                "2022" { "Visual Studio 17 2022" }
                "2019" { "Visual Studio 16 2019" }
                default { "Visual Studio 17 2022" }
            }
            $triplet = if ("$vsVersion" -eq "2019") { "msvc2019" } else { "msvc2022" }
            return @{
                Generator   = $gen
                ArchArg     = "x64"
                DepsTriplet = $triplet
                Config      = "Release"
                ExeRelPath  = "Release\xmrig.exe"
            }
        }
    }

    $mingw = Find-MinGW
    if ($mingw) {
        Write-Host "Using MinGW GCC: $($mingw.Gcc)"
        return @{
            Generator   = "MinGW Makefiles"
            ArchArg     = $null
            DepsTriplet = "gcc"
            Config      = $null
            ExeRelPath  = "xmrig.exe"
            Make        = $mingw.Make
        }
    }

    throw "No C++ compiler found. Install Visual Studio 2022 (Desktop C++) or MinGW-w64 (WinLibs)."
}

function Get-AppVersion {
    $text = Get-Content (Join-Path $Root "src\version.h") -Raw
    $m = [regex]::Match($text, '#define APP_VERSION\s+"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return "dev"
}

function Ensure-WinRing0 {
    $sys = Join-Path $Root "bin\WinRing0\WinRing0x64.sys"
    if (Test-Path $sys) { return }
    Write-Host "WinRing0x64.sys is missing; downloading from official xmrig repo..."
    New-Item -ItemType Directory -Force -Path (Split-Path $sys) | Out-Null
    Invoke-WebRequest -Uri "https://github.com/xmrig/xmrig/raw/master/bin/WinRing0/WinRing0x64.sys" -OutFile $sys
}

function Ensure-Deps {
    param([string]$RequestedDir, [string]$Triplet)

    $candidates = @()
    if ($RequestedDir) { $candidates += $RequestedDir }
    $candidates += @(
        "C:\xmrig-deps",
        (Join-Path $Root "xmrig-deps")
    )

    foreach ($base in $candidates) {
        $libDir = Join-Path $base "$Triplet\x64"
        if ((Test-Path (Join-Path $libDir "lib")) -or (Test-Path (Join-Path $libDir "include"))) {
            return (Resolve-Path $libDir).Path
        }
        # zip extract often nests xmrig-deps-master
        $nested = Join-Path $base "xmrig-deps-master\$Triplet\x64"
        if (Test-Path $nested) { return (Resolve-Path $nested).Path }
    }

    $dest = Join-Path $Root "xmrig-deps"
    Write-Host "Downloading xmrig-deps into $dest ..."
    $zip = Join-Path $env:TEMP "xmrig-deps.zip"
    Invoke-WebRequest -Uri "https://github.com/xmrig/xmrig-deps/archive/refs/heads/master.zip" -OutFile $zip
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $Root -Force
    $extracted = Join-Path $Root "xmrig-deps-master"
    if (Test-Path $extracted) { Rename-Item $extracted "xmrig-deps" }
    Remove-Item $zip -Force

    $libDir = Join-Path $dest "$Triplet\x64"
    if (-not (Test-Path $libDir)) {
        throw "xmrig-deps downloaded, but $Triplet\x64 was not found under $dest"
    }
    return (Resolve-Path $libDir).Path
}

$cmake = Find-CMake
$tc = Find-Toolchain -PreferredYear $VsYear
if ($Generator) { $tc.Generator = $Generator }

Write-Host "CMake      : $cmake"
Write-Host "Generator  : $($tc.Generator)"
Write-Host "Deps       : $($tc.DepsTriplet)/x64"

Ensure-WinRing0
$deps = Ensure-Deps -RequestedDir $DepsDir -Triplet $tc.DepsTriplet
Write-Host "XMRIG_DEPS : $deps"

$buildDir = Join-Path $Root "build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$configure = @("-S", $Root, "-B", $buildDir, "-G", $tc.Generator, "-DXMRIG_DEPS=$deps", "-DCMAKE_BUILD_TYPE=Release")
if ($tc.ArchArg) { $configure += @("-A", $tc.ArchArg) }
& $cmake @configure
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

$buildArgs = @("--build", $buildDir, "--parallel", "$Jobs")
if ($tc.Config) { $buildArgs += @("--config", $tc.Config) }
& $cmake @buildArgs
if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }

$exe = Join-Path $buildDir $tc.ExeRelPath
if (-not (Test-Path $exe)) { throw "Build succeeded but $exe was not produced" }

& $exe --version

$version = Get-AppVersion
$pkgName = "xmrig-$version-windows-x64"
$outDir = Join-Path $Root "release\$pkgName"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Copy-Item $exe $outDir
Copy-Item (Join-Path $Root "src\config.json") $outDir
Copy-Item (Join-Path $Root "LICENSE") $outDir

foreach ($f in @(
    (Join-Path $buildDir "Release\WinRing0x64.sys"),
    (Join-Path $buildDir "WinRing0x64.sys"),
    (Join-Path $Root "bin\WinRing0\WinRing0x64.sys")
)) {
    if (Test-Path $f) {
        Copy-Item $f $outDir
        break
    }
}
$wrLicense = Join-Path $Root "bin\WinRing0\LICENSE"
if (Test-Path $wrLicense) {
    Copy-Item $wrLicense (Join-Path $outDir "WinRing0-LICENSE")
}

foreach ($cmd in @(
    "benchmark_1M.cmd",
    "benchmark_10M.cmd",
    "pool_mine_example.cmd",
    "solo_mine_example.cmd",
    "rtm_ghostrider_example.cmd"
)) {
    $src = Join-Path $buildDir "Release\$cmd"
    if (-not (Test-Path $src)) { $src = Join-Path $buildDir $cmd }
    if (-not (Test-Path $src)) { $src = Join-Path $Root "scripts\$cmd" }
    if (Test-Path $src) { Copy-Item $src $outDir }
}

$startCmd = @"
@echo off
cd /d "%~dp0"
echo Edit config.json first: set your pool URL and wallet address.
echo Then run xmrig.exe (this window).
xmrig.exe
pause
"@
Set-Content -Path (Join-Path $outDir "start.cmd") -Value $startCmd -Encoding ASCII

$zipPath = Join-Path $Root "release\$pkgName.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $outDir "*") -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "Windows release package ready:"
Write-Host "  $outDir"
Write-Host "  $zipPath"
Write-Host ""
Write-Host "To mine: edit release\$pkgName\config.json (wallet + pool), then run start.cmd"
Write-Host "Wizard: https://xmrig.com/wizard"
