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

Write-Host ""
Write-Host "MISERY Gambling Mod -- Uninstaller"
Write-Host "=================================="
Write-Host ""

if (-not $InstallPath) { $InstallPath = Find-MiseryInstall }

if ($InstallPath) {
    Write-Host "MISERY install: $InstallPath" -ForegroundColor Cyan
}

while (-not $InstallPath -or -not (Test-Path -LiteralPath $InstallPath)) {
    Write-Host ""
    $InstallPath = Read-Host "Enter the path to your MISERY install folder"
    if ($InstallPath) { $InstallPath = $InstallPath.Trim('"').Trim().TrimEnd('\') }
    if (-not $InstallPath -or -not (Test-Path -LiteralPath $InstallPath)) {
        Write-Host "  Path doesn't exist. Try again." -ForegroundColor Yellow
        $InstallPath = $null
    }
}

$modsDir = Join-Path $InstallPath "MISERY\Binaries\Win64\ue4ss\Mods"
$src = Join-Path $PSScriptRoot "Mods"

if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "ERROR: Mods\ folder not found next to uninstall.ps1." -ForegroundColor Red
    exit 1
}

foreach ($modFolder in (Get-ChildItem -LiteralPath $src -Directory)) {
    $dest = Join-Path $modsDir $modFolder.Name
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
        Write-Host "  [OK] Removed: $($modFolder.Name)"
    } else {
        Write-Host "  [SKIP] Not present: $($modFolder.Name)"
    }
}

Write-Host ""
Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host ""
