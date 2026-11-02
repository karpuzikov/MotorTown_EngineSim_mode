#requires -Version 7.0
<#
  Installs ONLY the built MotorTownEngineSim development package.
  UE4SS must already be installed. No other game files or mods are modified.
  Run only after building the latest feat/native-engine-audio revision.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$GameWin64,
    [string]$StageRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Karpuzikov Tools\MotorTown EngineSim Mod\build\UE4SS\dev-stage\ue4ss\Mods\MotorTownEngineSim'),
    [string]$BackupRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Karpuzikov Tools\MotorTown EngineSim Mod\backups')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (Get-Process -Name 'MotorTown-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'Close Motor Town before installing the development audio test.'
}
$GameWin64 = [IO.Path]::GetFullPath($GameWin64)
$StageRoot = [IO.Path]::GetFullPath($StageRoot)
$BackupRoot = [IO.Path]::GetFullPath($BackupRoot)
$mods = Join-Path $GameWin64 'ue4ss\Mods'
$target = Join-Path $mods 'MotorTownEngineSim'
if (-not (Test-Path -LiteralPath $mods -PathType Container)) {
    throw "Existing UE4SS Mods directory not found: $mods"
}

$required = @(
    'dlls\main.dll', 'Scripts\main.lua', 'enabled.txt',
    'engine_profiles.tsv', 'engine_families.tsv', 'settings.ini', 'ENGINE_SIM_LICENSE.txt',
    'assets\es_ford_flathead_239.mr', 'assets\es_chevy_350.mr', 'assets\es_volvo_d13.mr',
    'assets\sound-library\smooth\smooth_39.wav',
    'assets\sound-library\new\mild_exhaust.wav', 'es\engine_sim.mr'
)
foreach ($relative in $required) {
    $path = Join-Path $StageRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Incomplete staged development package; missing: $path"
    }
}
if (-not (Select-String -LiteralPath (Join-Path $StageRoot 'Scripts\main.lua') -Pattern 'Exporter v0.2.24 active' -Quiet)) {
    throw 'Refusing outdated staged Lua exporter.'
}

$saved = $null
if (Test-Path -LiteralPath $target -PathType Container) {
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $backupName = 'DevAudio_' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss-fff')
    $backup = Join-Path $BackupRoot $backupName
    New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
    $saved = Join-Path $backup 'MotorTownEngineSim'
    Copy-Item -LiteralPath $target -Destination $saved -Recurse -Force
}

try {
    foreach ($folder in @('dlls', 'Scripts', 'assets', 'es')) {
        $destination = Join-Path $target $folder
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item -Path (Join-Path $StageRoot "$folder\*") -Destination $destination -Recurse -Force
    }
    foreach ($file in @('enabled.txt', 'engine_profiles.tsv', 'engine_families.tsv', 'ENGINE_SIM_LICENSE.txt')) {
        Copy-Item -LiteralPath (Join-Path $StageRoot $file) -Destination (Join-Path $target $file) -Force
    }
    # Keep the player's own settings.ini volume.
    if (-not (Test-Path -LiteralPath (Join-Path $target 'settings.ini'))) {
        Copy-Item -LiteralPath (Join-Path $StageRoot 'settings.ini') -Destination (Join-Path $target 'settings.ini')
    }
    foreach ($relative in @('dlls\main.dll', 'Scripts\main.lua')) {
        $sourceHash = (Get-FileHash -LiteralPath (Join-Path $StageRoot $relative) -Algorithm SHA256).Hash
        $destHash = (Get-FileHash -LiteralPath (Join-Path $target $relative) -Algorithm SHA256).Hash
        if ($sourceHash -ne $destHash) { throw "Verification failed: $relative" }
    }
}
catch {
    Write-Warning "Installation interrupted. Previous mod backup: $saved"
    throw
}

Write-Host 'Development engine-audio test installed and verified.' -ForegroundColor Green
Write-Host "Game mod: $target"
if ($saved) { Write-Host "Previous mod backup: $saved" }
Write-Host 'This is an EXPERIMENTAL test, not a playable release.' -ForegroundColor Yellow
