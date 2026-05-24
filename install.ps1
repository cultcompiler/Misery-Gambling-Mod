#Requires -Version 5.0
param([string]$InstallPath)

$ErrorActionPreference = "Stop"
$STEAM_APPID = "2119830"

function Get-RegValueSafe($path, $name) {
    try { return (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name }
    catch { return $null }
}

function Find-SteamPath {
    $sources = @(
        @{Path = 'HKCU:\Software\Valve\Steam';                Name = 'SteamPath'},
        @{Path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam';    Name = 'InstallPath'},
        @{Path = 'HKLM:\SOFTWARE\Valve\Steam';                Name = 'InstallPath'}
    )
    foreach ($s in $sources) {
        $v = Get-RegValueSafe $s.Path $s.Name
        if ($v) { return ($v -replace '/', '\') }
    }
    return $null
}

function Get-SteamLibraries {
    $libs = New-Object 'System.Collections.Generic.List[string]'
    $steam = Find-SteamPath
    if (-not $steam) { return @() }
    $libs.Add($steam) | Out-Null
    $vdf = "$steam\steamapps\libraryfolders.vdf"
    try {
        if (Test-Path -LiteralPath $vdf) {
            $content = Get-Content -Raw -LiteralPath $vdf
            foreach ($m in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
                $p = $m.Groups[1].Value -replace '\\\\', '\'
                if (-not $libs.Contains($p)) { $libs.Add($p) | Out-Null }
            }
            foreach ($m in [regex]::Matches($content, '"\d+"\s+"([A-Za-z]:[^"]+)"')) {
                $p = $m.Groups[1].Value -replace '\\\\', '\'
                if (-not $libs.Contains($p)) { $libs.Add($p) | Out-Null }
            }
        }
    } catch { }
    return $libs.ToArray()
}

function Find-MiseryInstall {
    foreach ($lib in Get-SteamLibraries) {
        $manifest = "$lib\steamapps\appmanifest_$STEAM_APPID.acf"
        try {
            if (Test-Path -LiteralPath $manifest) {
                $mc = Get-Content -Raw -LiteralPath $manifest
                if ($mc -match '"installdir"\s+"([^"]+)"') {
                    $p = "$lib\steamapps\common\$($matches[1])"
                    if (Test-Path -LiteralPath $p) { return $p }
                }
            }
        } catch { }
        foreach ($name in @('MISERY', 'Misery')) {
            $p = "$lib\steamapps\common\$name"
            try { if (Test-Path -LiteralPath $p) { return $p } } catch { }
        }
    }
    return $null
}

function Get-Win64Path($installPath) {
    return Join-Path $installPath "MISERY\Binaries\Win64"
}

function Test-UE4SSInstalled($installPath) {
    $win64 = Get-Win64Path $installPath
    return (Test-Path -LiteralPath (Join-Path $win64 "dwmapi.dll")) `
        -or (Test-Path -LiteralPath (Join-Path $win64 "UE4SS.dll"))
}

Write-Host ""
Write-Host "MISERY Gambling Mod -- Installer"
Write-Host "================================"
Write-Host ""

if (-not $InstallPath) {
    Write-Host "Searching for MISERY..."
    $InstallPath = Find-MiseryInstall
    if ($InstallPath) {
        Write-Host "  Found at: $InstallPath" -ForegroundColor DarkGray
    } else {
        Write-Host "  Not auto-detected." -ForegroundColor DarkGray
    }
}

if ($InstallPath) {
    Write-Host ""
    Write-Host "MISERY install:"
    Write-Host "  $InstallPath" -ForegroundColor Cyan
}

while (-not $InstallPath -or -not (Test-Path -LiteralPath $InstallPath)) {
    Write-Host ""
    $InstallPath = Read-Host "Enter the path to your MISERY install folder (the one with MISERY\Binaries\Win64\ inside)"
    if ($InstallPath) { $InstallPath = $InstallPath.Trim('"').Trim().TrimEnd('\') }
    if (-not $InstallPath -or -not (Test-Path -LiteralPath $InstallPath)) {
        Write-Host "  Path doesn't exist. Try again." -ForegroundColor Yellow
        $InstallPath = $null
    }
}

if (-not (Test-UE4SSInstalled $InstallPath)) {
    Write-Host ""
    Write-Host "ERROR: UE4SS isn't installed at this MISERY install." -ForegroundColor Red
    Write-Host "  Looked for: $(Get-Win64Path $InstallPath)\dwmapi.dll"
    Write-Host ""
    Write-Host "Install UE4SS first, then re-run this installer:"
    Write-Host "  1. Download from https://github.com/UE4SS-RE/RE-UE4SS/releases"
    Write-Host "  2. Extract its contents into:"
    Write-Host "       $(Get-Win64Path $InstallPath)"
    exit 1
}

$modsDir = Join-Path (Get-Win64Path $InstallPath) "ue4ss\Mods"
if (-not (Test-Path -LiteralPath $modsDir)) {
    Write-Host ""
    Write-Host "ERROR: UE4SS Mods folder not found." -ForegroundColor Red
    Write-Host "  Expected: $modsDir"
    Write-Host "Did UE4SS finish first-launch setup? Launch MISERY once, quit, then re-run this."
    exit 1
}

$src = Join-Path $PSScriptRoot "Mods"
if (-not (Test-Path -LiteralPath $src)) {
    Write-Host ""
    Write-Host "ERROR: Mods\ folder not found next to install.ps1." -ForegroundColor Red
    Write-Host "Make sure you extracted the whole ZIP, not just install.bat."
    exit 1
}

Write-Host ""
Write-Host "Installing mod into: $modsDir"
Write-Host ""

foreach ($modFolder in (Get-ChildItem -LiteralPath $src -Directory)) {
    $dest = Join-Path $modsDir $modFolder.Name
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    Copy-Item -LiteralPath $modFolder.FullName -Destination $modsDir -Recurse -Force
    Write-Host "  [OK] $($modFolder.Name)"
}

Write-Host ""
Write-Host "Install complete." -ForegroundColor Green
Write-Host ""
Write-Host "Launch MISERY, load ur save, head to the bunker. Gambler"
Write-Host "auto-spawns a few sec after the world loads. Walk up + press E."
Write-Host ""
