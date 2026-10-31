#requires -version 5.1
<# Read-only connection diagnostics. Does not install, rebuild, or change game settings. #>
param(
    [string]$GamePath = '',
    [string]$ProjectPath = '',
    [string[]]$TempDirectories = @(),
    [ValidateRange(0,10)][int]$ObserveSeconds = 3,
    [switch]$NoOpen
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# MTES_GAME_DETECTION_BEGIN
function Resolve-GameExe([string]$userPath) {
    $relative = 'MotorTown\Binaries\Win64\MotorTown-Win64-Shipping.exe'
    if ($userPath) {
        foreach ($possible in @($userPath,(Join-Path $userPath $relative), (Join-Path $userPath 'MotorTown-Win64-Shipping.exe'))) {
            if (Test-Path -LiteralPath $possible -PathType Leaf) { return (Resolve-Path -LiteralPath $possible).Path }
        }
        throw ('Motor Town not found at -GamePath ' + $userPath)
    }
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        $steam = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($steam) {
            foreach ($prop in @('SteamPath','InstallPath')) {
                if ($steam.PSObject.Properties.Name -contains $prop) { $roots.Add([string]$steam.$prop) }
            }
        }
    }
    foreach ($default in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam")) {
        if ($default -and (Test-Path $default)) { $roots.Add($default) }
    }
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -eq [IO.DriveType]::Fixed -and $drive.IsReady) {
            foreach ($sub in @('SteamLibrary','Steam','Games\SteamLibrary')) {
                $loc = Join-Path $drive.RootDirectory.FullName $sub
                if (Test-Path $loc) { $roots.Add($loc) }
            }
        }
    }
    $libraries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in @($roots | Select-Object -Unique)) {
        if (-not (Test-Path $root)) { continue }
        $libraries.Add($root)
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($line in (Get-Content -LiteralPath $vdf)) {
                if ($line -match '^\s*"(?:path|\d+)"\s*"([^"]+)"') {
                    $libraries.Add(($Matches[1] -replace '\\\\','\'))
                }
            }
        }
    }
    foreach ($lib in @($libraries | Select-Object -Unique)) {
        $manifest = Join-Path $lib 'steamapps\appmanifest_1369670.acf'
        $directory = 'Motor Town'
        if (Test-Path $manifest) {
            $match = Select-String -Path $manifest -Pattern '"installdir"\s*"([^"]+)"' | Select-Object -First 1
            if ($match) { $directory = $match.Matches[0].Groups[1].Value }
        }
        $exe = Join-Path (Join-Path $lib ('steamapps\common\' + $directory)) $relative
        if (Test-Path -LiteralPath $exe -PathType Leaf) { return (Resolve-Path -LiteralPath $exe).Path }
    }
    throw 'Steam installation not found. Re-run with -GamePath "D:\SteamLibrary\steamapps\common\Motor Town".'
}
# MTES_GAME_DETECTION_END

function Add-ReportFile([Collections.Generic.List[string]]$report,[string]$label,[string]$path,[int]$lines = 160,[switch]$IncludeHead) {
    $report.Add('')
    $report.Add('--- ' + $label + ' ---')
    $report.Add('Path: ' + $path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $report.Add('MISSING')
        return
    }
    try {
        $item = Get-Item -LiteralPath $path
        $report.Add('Modified: ' + $item.LastWriteTime.ToString('o') + '; bytes: ' + $item.Length)
        if ($IncludeHead) {
            $report.Add('First 40 lines:')
            foreach ($line in @(Get-Content -LiteralPath $path -TotalCount 40)) { $report.Add([string]$line) }
            $report.Add('Last ' + $lines + ' lines:')
        }
        foreach ($line in @(Get-Content -LiteralPath $path -Tail $lines)) { $report.Add([string]$line) }
    } catch { $report.Add('READ FAILED: ' + $_.Exception.Message) }
}

function Read-Telemetry([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { $text = [IO.File]::ReadAllText($path).Trim() } catch { return $null }
    $parts = @($text -split '\s+')
    if ($parts.Count -ne 5 -or $parts[0] -ne 'MTES1') { return $null }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $rpm = 0.0; $throttle = 0.0; $epoch = [long]0
    if (-not [double]::TryParse($parts[1],[Globalization.NumberStyles]::Float,$culture,[ref]$rpm) -or
        -not [double]::TryParse($parts[2],[Globalization.NumberStyles]::Float,$culture,[ref]$throttle) -or
        -not [long]::TryParse($parts[4],[ref]$epoch) -or $parts[3] -notmatch '^[01]$' -or
        [double]::IsNaN($rpm) -or [double]::IsInfinity($rpm) -or
        [double]::IsNaN($throttle) -or [double]::IsInfinity($throttle) -or
        $rpm -lt 0 -or $rpm -gt 25000 -or $throttle -lt 0 -or $throttle -gt 1) { return $null }
    return [pscustomobject]@{ Path=$path; Text=$text; RPM=$rpm; Throttle=$throttle; Running=$parts[3]; Epoch=$epoch }
}

try {
    if (-not $ProjectPath) {
        $ProjectPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Karpuzikov Tools\MotorTown EngineSim Bridge'
    }
    $logs = Join-Path $ProjectPath 'logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $reportPath = Join-Path $logs ('Connection_' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss-ffff') + '.txt')
    $report = New-Object 'System.Collections.Generic.List[string]'
    $report.Add('MotorTown EngineSim - connection diagnostics')
    $report.Add('Collected: ' + (Get-Date).ToString('o'))
    $report.Add('Project: ' + $ProjectPath)
    $report.Add('Stock audio is not automatically replaced or muted in the current prototype.')
    $processes = @(Get-Process -Name 'MotorTown-Win64-Shipping','engine-sim-app' -ErrorAction SilentlyContinue)
    $gameProcesses = @($processes | Where-Object { $_.ProcessName -eq 'MotorTown-Win64-Shipping' })
    $gameExe = $null
    $moduleCheckAvailable = $false
    $ue4ssLoaded = $false
    foreach ($process in $processes) {
        $report.Add('Process: ' + $process.ProcessName + '; PID: ' + $process.Id)
        try {
            $report.Add('Executable: ' + $process.Path)
            if ($process.ProcessName -eq 'MotorTown-Win64-Shipping') { $gameExe = $process.Path }
        } catch { $report.Add('Executable path unavailable: ' + $_.Exception.Message) }
        if ($process.ProcessName -eq 'MotorTown-Win64-Shipping') {
            try {
                $modules = @($process.Modules)
                $moduleCheckAvailable = $true
                foreach ($module in $modules) {
                    if ($module.ModuleName -match '(?i)ue4ss|^dwmapi\.dll$|^xinput1_3\.dll$') {
                        $report.Add('Loaded module: ' + $module.FileName)
                        if ($module.ModuleName -match '(?i)ue4ss') { $ue4ssLoaded = $true }
                    }
                }
            } catch { $report.Add('Module inspection unavailable: ' + $_.Exception.Message) }
        }
    }
    if ($GamePath -or -not $gameExe) {
        try { $gameExe = Resolve-GameExe $GamePath }
        catch { $report.Add('Game path detection: ' + $_.Exception.Message) }
    }
    if ($gameProcesses.Count -eq 0) { $report.Add('Motor Town process was not found. Collect while the game is running.') }

    if ($TempDirectories.Count -eq 0) {
        $TempDirectories = @(@($env:TMP,$env:TEMP,[IO.Path]::GetTempPath()) | Where-Object { $_ } | Select-Object -Unique)
    }
    $telemetryPaths = @($TempDirectories | ForEach-Object { Join-Path $_ 'MotorTownEngineSim_telemetry.txt' } | Select-Object -Unique)
    $samples = New-Object 'System.Collections.Generic.List[object]'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        foreach ($path in $telemetryPaths) {
            $packet = Read-Telemetry $path
            if ($null -ne $packet) { $samples.Add($packet) }
        }
        if ($timer.Elapsed.TotalSeconds -ge $ObserveSeconds) { break }
        Start-Sleep -Milliseconds 250
    } while ($true)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $live = @($samples | Where-Object { $_.Epoch -le $now + 1 -and $now - $_.Epoch -le 2 })
    $report.Add('')
    if ($live.Count -gt 0) {
        $latest = $live | Sort-Object Epoch -Descending | Select-Object -First 1
        $status = 'LIVE game telemetry: RPM=' + $latest.RPM + '; throttle=' + $latest.Throttle + '; running=' + $latest.Running
        $report.Add($status)
        $report.Add('Live packet path: ' + $latest.Path)
        $rpms = $live | Measure-Object -Property RPM -Minimum -Maximum
        $report.Add('Observed RPM range: ' + $rpms.Minimum + ' to ' + $rpms.Maximum + ' RPM')
        if ($latest.RPM -eq 0) { $report.Add('Exporter reports zero RPM; vehicle recognition and field mapping need inspection.') }
        $report.Add('Live exporter packets do not prove that the simulator receives them or replaces stock audio.')
    } else {
        $status = 'NO LIVE game telemetry observed.'
        $report.Add($status)
        if ($moduleCheckAvailable -and -not $ue4ssLoaded) {
            $report.Add('UE4SS was not found in the inspected game modules. Check the loader installation and UE4SS log below.')
        } elseif ($samples.Count -gt 0) { $report.Add('Telemetry packets exist but are stale or future-dated.') }
        else { $report.Add('Telemetry is missing, unreadable, or invalid. Check exporter/UE4SS logs below.') }
    }
    foreach ($path in $telemetryPaths) { Add-ReportFile $report 'Telemetry packet' $path 5 }
    foreach ($directory in $TempDirectories) {
        Add-ReportFile $report 'Latest game discovery snapshot' (Join-Path $directory 'MotorTownEngineSim_discovery.txt') 350 -IncludeHead
        Add-ReportFile $report 'Latest SDK engine audio targets' (Join-Path $directory 'MotorTownEngineSim_audio_targets.txt') 100 -IncludeHead
        Add-ReportFile $report 'Game exporter diagnostics' (Join-Path $directory 'MotorTownEngineSim_diagnostics.txt') 450 -IncludeHead
    }
    if ($gameExe) {
        $win64 = Split-Path -Parent $gameExe
        $report.Add('')
        $report.Add('Game executable: ' + $gameExe)
        foreach ($root in @((Join-Path $win64 'ue4ss'),$win64)) {
            foreach ($name in @('UE4SS.dll','dwmapi.dll','xinput1_3.dll')) {
                $path = Join-Path $root $name
                $report.Add('Loader file: ' + $path + '; exists=' + (Test-Path -LiteralPath $path -PathType Leaf))
            }
            Add-ReportFile $report 'UE4SS log' (Join-Path $root 'UE4SS.log') 300 -IncludeHead
            Add-ReportFile $report 'UE4SS settings' (Join-Path $root 'UE4SS-settings.ini') 400
            $mods = Join-Path $root 'Mods'
            $list = Join-Path $mods 'mods.txt'
            $report.Add('')
            $report.Add('Mod activation list: ' + $list)
            try {
                if (Test-Path -LiteralPath $list -PathType Leaf) {
                    $entries = @(Get-Content -LiteralPath $list | Where-Object { $_ -match '^\s*MotorTownEngineSim\s*:' })
                    if ($entries.Count -gt 0) { foreach ($line in $entries) { $report.Add($line) } }
                    else { $report.Add('No MotorTownEngineSim entry') }
                } else { $report.Add('MISSING') }
            } catch { $report.Add('READ FAILED: ' + $_.Exception.Message) }
            $mod = Join-Path $mods 'MotorTownEngineSim'
            $script = Join-Path $mod 'Scripts/main.lua'
            $report.Add('enabled.txt exists: ' + (Test-Path -LiteralPath (Join-Path $mod 'enabled.txt') -PathType Leaf))
            try {
                if (Test-Path -LiteralPath $script -PathType Leaf) {
                    $report.Add('Exporter SHA256: ' + (Get-FileHash -LiteralPath $script -Algorithm SHA256).Hash)
                }
            } catch { $report.Add('Exporter HASH FAILED: ' + $_.Exception.Message) }
            Add-ReportFile $report 'Installed exporter (tail)' $script 4
        }
    }
    Add-ReportFile $report 'Simulator runtime' (Join-Path $ProjectPath 'source/engine-sim/build-mtes/MotorTownEngineSim_runtime.log')
    Add-ReportFile $report 'Engine script errors' (Join-Path $ProjectPath 'source/engine-sim/build-mtes/error_log.log')
    [IO.File]::WriteAllLines($reportPath,$report,[Text.UTF8Encoding]::new($false))
    Write-Host $status
    Write-Host ('Report: ' + $reportPath)
    if (-not $NoOpen) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $reportPath + '"') | Out-Null }
    exit 0
} catch {
    Write-Host ('DIAGNOSTICS FAILED: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
