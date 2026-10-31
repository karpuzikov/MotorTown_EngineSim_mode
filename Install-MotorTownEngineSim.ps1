#requires -version 5.1
<#
Motor Town EngineSim Bridge v0.2.14 experimental installer.
Single-file automated setup. Downloads open-source dependencies from official sources.
Not game-tested; gameplay/audio correctness is not guaranteed.
Run: powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-MotorTownEngineSim.ps1
Optional: -GamePath "D:\SteamLibrary\steamapps\common\Motor Town"
#>
param(
    [string]$GamePath = '',
    [switch]$NoLaunch,
    [switch]$SkipDependencyInstall
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Installing Visual Studio C++ and writing to Steam's game folder may require elevation.
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($GamePath) { $argumentLine += ' -GamePath "' + $GamePath.Replace('"','') + '"' }
    if ($NoLaunch) { $argumentLine += ' -NoLaunch' }
    if ($SkipDependencyInstall) { $argumentLine += ' -SkipDependencyInstall' }
    $elevated = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru
    exit $elevated.ExitCode
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AppName = 'MotorTown EngineSim Bridge'
$HomeDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Karpuzikov Tools\MotorTown EngineSim Bridge'
$Deps = Join-Path $HomeDir 'dependencies'
$Sources = Join-Path $HomeDir 'source'
$Logs = Join-Path $HomeDir 'logs'
$Repo = Join-Path $Sources 'engine-sim'
$EngineSimSource = 'https://github.com/karpuzikov/engine-sim.git'
foreach ($folder in @($HomeDir, $Deps, $Sources, $Logs)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
$Log = Join-Path $Logs ('Install_' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss') + '.log')
Start-Transcript -Path $Log | Out-Null

function Say([string]$s) { Write-Host ('[MTES] ' + $s) -ForegroundColor Cyan }
function Ensure([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Run([string]$exe,[string[]]$argv) {
    Say ($exe + ' ' + ($argv -join ' '))
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { throw "$exe exited with code $LASTEXITCODE" }
}
function Find-Exe([string]$name, [string[]]$fallback = @()) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($item in $fallback) { if (Test-Path -LiteralPath $item -PathType Leaf) { return $item } }
    return $null
}
function Refresh-Path {
    $env:PATH = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User') + ';' + $env:PATH
}
function Download([string]$url, [string]$dest) {
    Say ('Download: ' + $url)
    $parent = Split-Path -Parent $dest
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -Headers @{ 'User-Agent'='MTES-Bridge-Installer' }
    Ensure ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -gt 1000) ('Download failed: ' + $url)
}
function Get-Release([string]$repo,[string]$suffix = 'latest') {
    $uri = "https://api.github.com/repos/$repo/releases/$suffix"
    Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent'='MTES-Bridge-Installer'; Accept='application/vnd.github+json' }
}
function Decode([string]$encoded) {
    $bytes = [Convert]::FromBase64String($encoded)
    $inputStream = [IO.MemoryStream]::new($bytes)
    $gz = [IO.Compression.GzipStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress)
    $out = [IO.MemoryStream]::new()
    $gz.CopyTo($out)
    $gz.Dispose(); $inputStream.Dispose()
    $text = [Text.Encoding]::UTF8.GetString($out.ToArray())
    $out.Dispose()
    return $text
}
function Write-UTF8([string]$path,[string]$contents) {
    [IO.File]::WriteAllText($path,$contents,[Text.UTF8Encoding]::new($false))
}
function Ensure-EngineSource([string]$git,[string]$sourceRoot,[string]$sourceUrl) {
    if (-not (Test-Path (Join-Path $sourceRoot '.git'))) {
        Ensure (-not (Test-Path $sourceRoot)) ('Existing non-Git directory: ' + $sourceRoot)
        Run $git @('clone','--recurse-submodules',$sourceUrl,$sourceRoot)
    } else {
        # Switching the remote preserves local patches, submodules and build files.
        Run $git @('-C',$sourceRoot,'remote','set-url','origin',$sourceUrl)
        Run $git @('-C',$sourceRoot,'submodule','update','--init','--recursive')
    }
    Say ('Engine Simulator source: ' + $sourceUrl)
}
function Repair-DirectXLinkage([string]$sourceRoot) {
    # The pinned Delta CMake file links retail AND debug D3DX import libraries.
    # Release must use retail DLLs supplied by the DirectX redistributable.
    $path = Join-Path $sourceRoot 'dependencies/submodules/delta-studio/CMakeLists.txt'
    Ensure (Test-Path -LiteralPath $path -PathType Leaf) ('Delta Studio CMake source missing: ' + $path)
    $old = @'
    ${D3DX_LIBS}/d3dx9.lib
    ${D3DX_LIBS}/d3dx9d.lib
    ${D3DX_LIBS}/d3dx10d.lib
    ${D3DX_LIBS}/d3dx10.lib
    ${D3DX_LIBS}/d3dx11.lib
    ${D3DX_LIBS}/d3dx11d.lib
'@
    $new = @'
    optimized ${D3DX_LIBS}/d3dx9.lib
    debug ${D3DX_LIBS}/d3dx9d.lib
    optimized ${D3DX_LIBS}/d3dx10.lib
    debug ${D3DX_LIBS}/d3dx10d.lib
    optimized ${D3DX_LIBS}/d3dx11.lib
    debug ${D3DX_LIBS}/d3dx11d.lib
'@
    $original = [IO.File]::ReadAllText($path)
    $text = $original.Replace("`r`n", "`n")
    $old = $old.Replace("`r`n", "`n")
    $new = $new.Replace("`r`n", "`n")
    if ($text.Contains($new)) { Say 'DirectX libraries already selected per build configuration.'; return }
    Ensure ([regex]::Matches($text, [regex]::Escape($old)).Count -eq 1) `
        'Unsupported Delta Studio DirectX link layout. No CMake source changes made.'
    $text = $text.Replace($old, $new)
    if ($original.Contains("`r`n")) { $text = $text.Replace("`n", "`r`n") }
    Copy-Item -LiteralPath $path -Destination ($path + '.before-mtes-directx-' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss-ffff'))
    Write-UTF8 $path $text
    Say 'Fixed DirectX linkage: Release uses retail libraries; Debug uses debug libraries.'
}
function Assert-ReleaseDirectXDependencies([string]$dumpbin,[string]$enginePath) {
    $output = @(& $dumpbin '/nologo' '/dependents' $enginePath)
    Ensure ($LASTEXITCODE -eq 0) ('MSVC dependency inspection failed (exit ' + $LASTEXITCODE + ').')
    $text = $output -join "`n"
    $debugImports = @([regex]::Matches($text, '(?i)\bd3dx(?:9|10|11)d_\d+\.dll\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
    Ensure ($debugImports.Count -eq 0) ('Debug DirectX dependency in Release executable: ' + ($debugImports -join ', ') + '. Refusing to launch this build.')
    $imports = @([regex]::Matches($text, '(?i)\b[\w.-]+\.dll\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
    Say ('Release DLL dependencies: ' + ($imports -join ', '))
}
function Install-TelemetryBridge([string]$sourceRoot) {
    # Canonical payloads: bridge/patch_engine_sim.py.
    $originalInputSha256 = '1912b063d7da3adcb1de660eb095e9f63306a4439552d427cbfa5d6710c0b188'
    $over = Decode 'H4sIAAAAAAACA41UwW7iMBC98xXTHqpwANrDXqig0narqtIiVQX1itxkklhre5A9XoS2++87cQIJWg7NAWT7vTfzxjMegXyzGaw2T+vt97eXH89P2/e7OaCrtEPIybEnI/8WA5AzByg9WfnBUEOlLAKjQYvsD9PRUYuYPGxo72BXH4LOAyiPEB1TzGss7iGwcoUyJBF+4eGDlC+OoVpsoYP6MFi0mrqEzG51jk9tVosFuGjMjj18foLdBm2jUU3Q/mQMHjl6d58UVrw5pgmW2z0JGBg+KNlzDnPGAhZCU8UAnlke/4cnJ8CedHMjolMfndOuOq52FpYL+HY7vW3pgzQnywq59ZKN0+Klcpo1uRUV0aRNu0WXSiCRyF2QkAUrz+hTuadDfKlMwIuU4uBo+gXpDleTOQc1++sddlR4kEvVHOZzcZu1pscwh8ueT6qeWDVmj0ID2cul2njlgtUhCKmpTV4rV+EzKp9N7sZf4wTkRxM5r1+ldUP0mEmWPbcJvkbm5gKbjKS0IrI+306OxSbXYoENnls99WcKlqiPbU9n5wG6qM2kxKQs10UQtEGXy5TlpAJPChmfmYzdrklXPIAjHRD2tcCa8Th133BEVCw0rSn6HOFqMApnJ5Ol5PFOJlrMkqO76W3ZWim71LqBcyVJzYL02Jnan4TpTPeYZPsnVStJWFWYXfUD8gDXqUubN2EOe6WT7VIG9vR6XJ9Em2/e1nrIMvo3Hp+lniXIIag7p7KEmVQM3l5X152nv6N/fCKFiuwEAAA='
    $hdr = Decode 'H4sIAAAAAAACA3VU204bMRB936+YgEQ3os2t6guBSFQgykNaBFGpVFWR2Z1N3O7aK3vcEEH+veO9ZI2U7sPKnsvxOTNjD4cwX1w/LD/f317dXC+/j6NjmaWYwfLx9uvHCe9UkrsU4XwjVao3drCeRceoUpkFvsySQVHMAlNCssA3hkIQ50ZKFGhLkSC8RJzmEoI5LTDHAsls2Qj8pdo95QimLOACRoPRNLTS2mgiXgSuJ61zME4pqVZsz0RucRrtplE0HMJijYDPpTaEBjZGElrQKt8CaQZDSJwxqAicRfPOAmHBsYLJpNJgQtpsBx7mHn/zDiwJPpsV/EGyUxBs0GWJKaxYGRTOEihNkKP4y8eqlVQIwqVSt/wGUc0WRRooj8MqnGhHfa7F22Z4oclamI7Xz/nlj+Xd5eILnML4Fwt/2dX1uHr8dn8Fii03yLhFecfVv4zb8PcdRL9OkBnEHM4lhddXTpxBG9tnpuSMaovqoy2lZ2eyaTtIFVcG3rK8uINmVkdzzcuF3qjrqhQPslhSq3NAz3QUEOhJ9d/TanCwcqUEBzQuyW1DJXgsUj8OtTHXHFj9sNTJunNUZ8SS1c06IL/hcg/8sDXL/YTxvkX3S4/WP8TQA3eAvQuWzbdqfORr2auLZTOpePLi5qg+u6pU/x0IaSn4uD2987o7e7Yw+TQajUKkN+yD8E4RjL0tbmX1fMdPTiDYjw9KTLTiyRaO74zSG64p3wOSyTIRls73FZ/Vk+Avf6xcnpdk+kGD637MKoTTmolffoDWMTl0dKV3f7dD5rW/yeDHhBOOkfNCcwPUPFq7aAd8l4XSaltoZ2H/HkX/AFj/9ysMBQAA'
    $legacyOver = Decode 'H4sIAAAAAAACA51UTW/bMAy951fwVDiHOu1hlxTpgLVZ0UOAogm2Y6DIjC1MH4ZENwiG/vdRsuc5bZA11cHWB/lIPT5xBDwmE1is5sv1t+fH+4f5+sf1FIIWLwhUIYimUA6CMo0W5DyQg4WLk5XbWdhVaIFQo0Hye1ABtHrBfNTBrhigc1XOgkcjlA0Jt0TbKIswt2X8LfsA0plNE6L9pI2NyaLHHESvq31QMoDwCI0l18gKixuG5zxq7ySGAM7qPWyd1m4XQFEA6YX9FSqxJXh+WrSwv9M3jkCcqoSNcxoM/RThzlmLkrCAGWyFDnjT2y5o1d/c0L99tYXMoygG55mh8XgQJo538OSbAXoc0tlAbTJM34xdct9Yq2wJFxdpVRu4ncGXq/zq0NOs+5Jd3pZILc3ZOC0eS6siwQtXNDptmjVasdEpDWdPQPGChCf0qQz50O8NO0dci711+RmhOvvK6ePG8XxZYwcFX1kEXOHplFnJWnLGMIXT3PRRvKOk0r+AA/jT1K5YUMGoENg5cikrYUt8QOGzy+vxeb4B6U43JKsnz+JtPGac/XuMmNQSiaIQYqZcEgZbHm4nRpgGqvhqpPE4FUpiq40UPEGwJsk7nR0GGmTx2s+QS570fijmt1LnZ/tdKM29QKOlrmvEJiAMgtQuID9UP2gkhQqirpnCkJ8lqA9rsNPU/+0/LffzHt1xtA/V+byiHuqpreTr6A81EQt3CAYAAA=='
    $cpp = Join-Path $sourceRoot 'src/engine_sim_application.cpp'
    Ensure (Test-Path -LiteralPath $cpp -PathType Leaf) 'Original Engine Simulator C++ source missing.'
    $original = [IO.File]::ReadAllText($cpp)
    $contents = $original.Replace("`r`n", "`n")
    $funcStart = 'void EngineSimApplication::processEngineInput() {'
    $funcEnd = "`n}`n`nvoid EngineSimApplication::renderScene() {"
    $start = $contents.IndexOf($funcStart,[StringComparison]::Ordinal)
    $end = if ($start -ge 0) { $contents.IndexOf($funcEnd,$start,[StringComparison]::Ordinal) } else { -1 }
    Ensure ($start -ge 0 -and $end -gt $start) 'Unable to find supported Engine Simulator input function boundaries. No source changes made.'
    $installed = $contents.Contains('// MTES_BRIDGE_V1')
    $body = $contents.Substring($start + $funcStart.Length, $end - $start - $funcStart.Length)
    $originalBody = $body
    if ($installed) {
        Ensure ([regex]::Matches($contents, [regex]::Escape($hdr)).Count -eq 1) 'Incomplete or changed telemetry header. No source changes made.'
        if ($body -eq $over) { Say 'Telemetry-only engine controls already installed.'; return }
        Ensure ($body.EndsWith($legacyOver,[StringComparison]::Ordinal)) 'Unknown existing telemetry patch. No source changes made.'
        $originalBody = $body.Substring(0,$body.Length - $legacyOver.Length)
    }
    $inputHasher = [Security.Cryptography.SHA256]::Create()
    try {
        $inputHash = [BitConverter]::ToString($inputHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($originalBody))).Replace('-','').ToLowerInvariant()
    } finally { $inputHasher.Dispose() }
    Ensure ($inputHash -eq $originalInputSha256) 'Unsupported or modified Engine Simulator input controls. No source changes made.'
    $contents = $contents.Substring(0,$start + $funcStart.Length) + $over + $contents.Substring($end)
    if (-not $installed) { $contents = $contents.Insert($start, $hdr + "`n") }
    if ($original.Contains("`r`n")) { $contents = $contents.Replace("`n", "`r`n") }
    $backup = $cpp + '.before-mtes-' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss-ffff')
    Copy-Item -LiteralPath $cpp -Destination $backup
    Write-UTF8 $cpp $contents
    Say ('Installed telemetry-only engine controls (backup: ' + $backup + ')')
}
function Install-RuntimeDiagnostics([string]$sourceRoot) {
    # Canonical definition: bridge/patch_engine_sim.py. Regenerate with package_installer.py.
    $runtimePatch = Decode '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'
    $spec = $runtimePatch | ConvertFrom-Json
    $pending = @()
    foreach ($entry in $spec.patches) {
        $path = Join-Path $sourceRoot $entry.path
        Ensure (Test-Path -LiteralPath $path -PathType Leaf) ('Runtime source missing: ' + $path)
        $original = [IO.File]::ReadAllText($path)
        $usedCRLF = $original.Contains("`r`n")
        $text = $original.Replace("`r`n", "`n")
        foreach ($edit in $entry.edits) {
            if ([regex]::Matches($text, [regex]::Escape($edit.after)).Count -eq 1) { continue }
            $count = [regex]::Matches($text, [regex]::Escape($edit.before)).Count
            Ensure ($count -eq 1) ('Unsupported runtime source layout: ' + $path + '. No runtime files changed.')
            $text = $text.Replace($edit.before, $edit.after)
        }
        if ($text -eq $original.Replace("`r`n", "`n")) { continue }
        if ($usedCRLF) { $text = $text.Replace("`n", "`r`n") }
        $pending += @{ Path=$path; Text=$text }
    }
    # Validate every source before changing any file.
    foreach ($change in $pending) {
        Copy-Item -LiteralPath $change.Path -Destination ($change.Path + '.before-mtes-runtime-' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss-ffff'))
        Write-UTF8 $change.Path $change.Text
    }
    Write-UTF8 (Join-Path $sourceRoot $spec.header_path) $spec.header
    Say 'Engine Simulator startup diagnostics installed.'
}
function Start-EngineSimulator([IO.FileInfo]$engineExe,[string]$build) {
    $runtimeLog = Join-Path $build 'MotorTownEngineSim_runtime.log'
    $scriptLog = Join-Path $build 'error_log.log'
    $stamp = Get-Date -Format 'yyyy-MM-dd-HH-mm-ss-ffff'
    foreach ($path in @($runtimeLog,$scriptLog)) {
        if (Test-Path -LiteralPath $path) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $Logs ($stamp + '-previous-' + (Split-Path $path -Leaf)))
            Remove-Item -LiteralPath $path
        }
    }
    Say 'Launching Engine Simulator and checking startup...'
    $engineProcess = Start-Process -FilePath $engineExe.FullName -WorkingDirectory $build -PassThru
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    $failed = $false
    do {
        $engineProcess.Refresh()
        if (Test-Path -LiteralPath $runtimeLog) {
            $runtimeText = [string](Get-Content -LiteralPath $runtimeLog -Raw -ErrorAction SilentlyContinue)
            $ready = $runtimeText -match '(?m)^MTES_STARTUP_READY\r?$'
            $failed = $runtimeText -match '(?m)^RUNTIME FAILED:'
        }
        if ($ready -or $failed -or $engineProcess.HasExited) { break }
        Start-Sleep -Milliseconds 250
    } while ($timer.Elapsed.TotalSeconds -lt 30)
    foreach ($path in @($runtimeLog,$scriptLog)) {
        if (Test-Path -LiteralPath $path) {
            Say ('Runtime report: ' + $path)
            Get-Content -LiteralPath $path -Tail 60 | ForEach-Object { Write-Host $_ }
            Copy-Item -LiteralPath $path -Destination (Join-Path $Logs ($stamp + '-' + (Split-Path $path -Leaf)))
        }
    }
    if ($failed) { throw 'Engine Simulator reported a runtime failure. See the runtime report above.' }
    if ($engineProcess.HasExited) {
        $engineProcess.WaitForExit()
        $code = $engineProcess.ExitCode
        throw ('Engine Simulator exited during the startup check (exit ' + $code + ', ' + ('0x{0:X8}' -f $code) + '). See the runtime report above.')
    }
    if ($ready) {
        Say 'Engine Simulator initialization completed. Start Motor Town normally in Steam; telemetry/audio synchronization is still unverified.'
    } else {
        Write-Host ('[MTES] Engine Simulator is still initializing. Last recorded stage is above. Live runtime log: ' + $runtimeLog) -ForegroundColor Yellow
    }
}
function Ensure-SdlDev([string]$name,[string]$folder,[string]$header,[string]$library,
                       [string]$url,[string]$expectedSha) {
    $destination = Join-Path $Deps $name
    $sdk = Join-Path $destination $folder
    $headerFile = Join-Path $sdk ('include\' + $header)
    $libFile = Join-Path $sdk ('lib\x64\' + $library)
    $dllFile = Join-Path $sdk ('lib\x64\' + $library.Replace('.lib','.dll'))
    if (-not ((Test-Path $headerFile) -and (Test-Path $libFile) -and (Test-Path $dllFile))) {
        if ($SkipDependencyInstall) { throw ('Missing development SDK: ' + $name) }
        $zip = Join-Path $Deps ($folder + '-VC.zip')
        if (-not (Test-Path $zip) -or
            (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expectedSha) {
            Download $url $zip
        }
        Ensure ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -eq $expectedSha) ('SDK checksum mismatch: ' + $name)
        Expand-Archive -LiteralPath $zip -DestinationPath $destination -Force
    }
    Ensure ((Test-Path $headerFile) -and (Test-Path $libFile) -and (Test-Path $dllFile)) ('SDK incomplete: ' + $name)
    return @{ Include=(Join-Path $sdk 'include'); Library=$libFile; Runtime=$dllFile }
}
function Install-LegacyDirectX {
    # EngineSim's Windows executable needs legacy D3DX10 (including d3dx10_43.dll).
    # These optional DirectX SDK components are not part of Windows 10/11.
    if ($SkipDependencyInstall) {
        Say 'Skipping legacy DirectX runtime installation (-SkipDependencyInstall).'
        return
    }
    Say 'Installing legacy DirectX runtimes required by Engine Simulator...'
    $url = 'https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe'
    $expectedSha = '053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b'
    $redistributable = Join-Path $Deps 'directx_Jun2010_redist.exe'
    if (-not (Test-Path -LiteralPath $redistributable) -or
        (Get-FileHash -LiteralPath $redistributable -Algorithm SHA256).Hash -ne $expectedSha) {
        Download $url $redistributable
    }
    Ensure ((Get-FileHash -LiteralPath $redistributable -Algorithm SHA256).Hash -eq $expectedSha) `
        'Microsoft DirectX redistributable checksum mismatch.'
    $extractDir = Join-Path $Deps 'DirectX-June2010'
    $setup = Join-Path $extractDir 'DXSETUP.exe'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) {
        New-Item -Path $extractDir -ItemType Directory -Force | Out-Null
        # Self-extracting Microsoft package; quote the destination for paths with spaces.
        $unpack = Start-Process -FilePath $redistributable -ArgumentList ('/Q /C /T:"' + $extractDir + '"') -Wait -PassThru
        Ensure ($unpack.ExitCode -eq 0) ('Microsoft DirectX extraction failed (exit ' + $unpack.ExitCode + ').')
    }
    Ensure (Test-Path -LiteralPath $setup -PathType Leaf) 'Microsoft DirectX DXSETUP.exe not found after extraction.'
    # Microsoft's guidance: let DXSETUP determine which side-by-side runtimes are needed.
    Run $setup @('/silent')
}
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
function Winget-Install([string]$id,[string[]]$extra = @()) {
    if ($SkipDependencyInstall) { throw "Missing required dependency ($id). Remove -SkipDependencyInstall." }
    $w = Find-Exe 'winget.exe' @((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'))
    Ensure ([bool]$w) 'winget.exe not found. Install Microsoft App Installer and retry.'
    Run $w (@('install','--id',$id,'--exact','--source','winget','--silent','--accept-package-agreements','--accept-source-agreements') + $extra)
    Refresh-Path
}
function Detect-VS {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    $path = & $vswhere -latest -products '*' -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath
    if (-not $path) { return $null }
    $version = & $vswhere -latest -products '*' -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationVersion
    $major = [int](([string]$version).Split('.')[0])
    $generator = if ($major -ge 18) { 'Visual Studio 18 2026' } else { 'Visual Studio 17 2022' }
    return @{ Path=([string]$path).Trim(); Generator=$generator }
}
function Wait-ForGameExit {
    $running = @(Get-Process -Name 'MotorTown-Win64-Shipping' -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return }
    Write-Host '[MTES] Motor Town is still running. Save your game and close it to finish installation.' -ForegroundColor Yellow
    Write-Host '[MTES] The installer will continue automatically once Motor Town closes.' -ForegroundColor Yellow
    do {
        Start-Sleep -Seconds 2
        $running = @(Get-Process -Name 'MotorTown-Win64-Shipping' -ErrorAction SilentlyContinue)
    } while ($running.Count -gt 0)
    Say 'Motor Town closed. Continuing setup.'
}
function Install-Compiler {
    $vs = Detect-VS
    if ($vs) { return $vs }
    if ($SkipDependencyInstall) { throw 'Visual Studio C++ Build Tools not found.' }
    $w = Find-Exe 'winget.exe' @((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'))
    Ensure ([bool]$w) 'winget not found: cannot install Visual Studio Build Tools.'
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $installed = & $vswhere -latest -products '*' -property installationPath
        if ($installed) {
            $setup = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
            Ensure (Test-Path $setup) 'Visual Studio Installer setup.exe missing.'
            Run $setup @('modify','--installPath',([string]$installed).Trim(),'--add','Microsoft.VisualStudio.Workload.VCTools','--includeRecommended','--quiet','--wait','--norestart')
            $vs = Detect-VS
            if ($vs) { return $vs }
        }
    }
    Winget-Install 'Microsoft.VisualStudio.2022.BuildTools' @('--override','--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
    $vs = Detect-VS
    Ensure ([bool]$vs) 'C++ Build Tools installation incomplete (a restart may be needed). Re-run installer.'
    return $vs
}

try {
    Say 'MotorTown EngineSim Bridge v0.2.14'
    Say 'Checking game location...'
    $gameExe = Resolve-GameExe $GamePath
    $win64 = Split-Path -Parent $gameExe
    Say ('Found Motor Town: ' + $gameExe)
    if (Get-Process -Name 'MotorTown-Win64-Shipping' -ErrorAction SilentlyContinue) {
        Say 'Motor Town is running; setup can prepare dependencies before the game needs to close.'
    }

    Say 'Checking compiler and build tools...'
    $git = Find-Exe 'git.exe' @('C:\Program Files\Git\cmd\git.exe')
    if (-not $git) { Winget-Install 'Git.Git'; $git = Find-Exe 'git.exe' @('C:\Program Files\Git\cmd\git.exe') }
    Ensure ([bool]$git) 'Git missing after installation.'
    $cmake = Find-Exe 'cmake.exe' @('C:\Program Files\CMake\bin\cmake.exe')
    if (-not $cmake) { Winget-Install 'Kitware.CMake'; $cmake = Find-Exe 'cmake.exe' @('C:\Program Files\CMake\bin\cmake.exe') }
    Ensure ([bool]$cmake) 'CMake missing after installation.'
    $vs = Install-Compiler
    Say ('Detected: ' + $vs.Generator)

    Say 'Setting up Flex and Bison...'
    $fbRoot = Join-Path $Deps 'winflexbison'
    $flex = Get-ChildItem -Path $fbRoot -Recurse -Filter 'win_flex.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $bison = Get-ChildItem -Path $fbRoot -Recurse -Filter 'win_bison.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $flex -or -not $bison) {
        $release = Get-Release 'lexxmark/winflexbison'
        $asset = @($release.assets | Where-Object { $_.name -match 'win_flex_bison.*\.zip$' } | Select-Object -First 1)
        Ensure ($asset.Count -eq 1) 'No WinFlexBison ZIP asset in official release.'
        $zipFile = Join-Path $Deps 'winflexbison.zip'
        Download $asset[0].browser_download_url $zipFile
        Expand-Archive -LiteralPath $zipFile -DestinationPath $fbRoot -Force
        $flex = Get-ChildItem -Path $fbRoot -Recurse -Filter 'win_flex.exe' -File | Select-Object -First 1
        $bison = Get-ChildItem -Path $fbRoot -Recurse -Filter 'win_bison.exe' -File | Select-Object -First 1
    }
    Ensure ([bool]$flex -and [bool]$bison) 'WinFlexBison executables missing.'

    Say 'Checking SDL2 and SDL2_image development libraries...'
    $sdl = Ensure-SdlDev 'SDL2' 'SDL2-2.32.10' 'SDL.h' 'SDL2.lib' `
        'https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-devel-2.32.10-VC.zip' `
        'af347939395a58b365846aaea27391e69f9ec9d4dd650d6ac40802159b418a6e'
    $sdlImage = Ensure-SdlDev 'SDL2_image' 'SDL2_image-2.8.8' 'SDL_image.h' 'SDL2_image.lib' `
        'https://github.com/libsdl-org/SDL_image/releases/download/release-2.8.8/SDL2_image-devel-2.8.8-VC.zip' `
        '076cebe070c5762bff0c854d2307078e53348d0225e04748feeb7c944453a86e'

    Say 'Checking Boost.Filesystem (static MSVC library)...'
    $vcpkgRoot = Join-Path $Deps 'vcpkg'
    $boostPrefix = Join-Path $vcpkgRoot 'installed\x64-windows-static-md'
    $boostLibs = @(Get-ChildItem -Path (Join-Path $boostPrefix 'lib') -Filter '*boost_filesystem*.lib' -File -ErrorAction SilentlyContinue)
    if ($boostLibs.Count -eq 0) {
        if ($SkipDependencyInstall) { throw 'Boost.Filesystem missing. Remove -SkipDependencyInstall.' }
        if (-not (Test-Path (Join-Path $vcpkgRoot '.git'))) {
            Ensure (-not (Test-Path $vcpkgRoot)) ('Existing non-Git vcpkg directory: ' + $vcpkgRoot)
            Run $git @('clone','--depth','1','https://github.com/microsoft/vcpkg.git',$vcpkgRoot)
        }
        $vcpkgExe = Join-Path $vcpkgRoot 'vcpkg.exe'
        if (-not (Test-Path $vcpkgExe)) {
            Run (Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat') @('-disableMetrics')
        }
        Ensure (Test-Path $vcpkgExe) 'vcpkg bootstrap did not produce vcpkg.exe.'
        Run $vcpkgExe @('install','boost-filesystem:x64-windows-static-md','--disable-metrics')
        $boostLibs = @(Get-ChildItem -Path (Join-Path $boostPrefix 'lib') -Filter '*boost_filesystem*.lib' -File -ErrorAction SilentlyContinue)
    }
    Ensure ($boostLibs.Count -gt 0) 'Boost.Filesystem library missing after vcpkg installation.'
    $vcpkgToolchain = Join-Path $vcpkgRoot 'scripts\buildsystems\vcpkg.cmake'
    Ensure (Test-Path $vcpkgToolchain) 'vcpkg CMake toolchain missing.'

    Say 'Checking Engine Simulator source (reusing the existing checkout)...'
    Ensure-EngineSource $git $Repo $EngineSimSource
    Install-TelemetryBridge $Repo

    # Piranha's pinned source calls a Boost.Filesystem method removed in modern Boost.
    $piranhaSource = Join-Path $Repo 'dependencies\submodules\piranha\src\path.cpp'
    Ensure (Test-Path $piranhaSource) 'Piranha path.cpp missing from Engine Simulator submodules.'
    $piranhaText = [IO.File]::ReadAllText($piranhaSource)
    if ($piranhaText.Contains('m_path->is_complete()')) {
        $piranhaBackup = $piranhaSource + '.before-mtes-' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss')
        Copy-Item -LiteralPath $piranhaSource -Destination $piranhaBackup
        $piranhaText = $piranhaText.Replace('m_path->is_complete()', 'm_path->is_absolute()')
        Write-UTF8 $piranhaSource $piranhaText
        Say ('Patched Piranha for Boost.Filesystem (backup: ' + $piranhaBackup + ')')
    } elseif ($piranhaText.Contains('m_path->is_absolute()')) {
        Say 'Piranha already compatible with modern Boost.Filesystem.'
    } else {
        throw 'Piranha path.cpp changed unexpectedly; refusing source patch.'
    }

    Install-RuntimeDiagnostics $Repo
    Repair-DirectXLinkage $Repo
    $runningEngine = @(Get-Process -Name 'engine-sim-app' -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($Repo + '\', [StringComparison]::OrdinalIgnoreCase)
    })
    if ($runningEngine.Count -gt 0) {
        Write-Host '[MTES] Close the existing Engine Simulator window to update its executable. Setup will continue automatically.' -ForegroundColor Yellow
        $runningEngine | Wait-Process -ErrorAction SilentlyContinue
    }
    Say 'Building Engine Simulator (this can take substantial disk space)...'
    $build = Join-Path $Repo 'build-mtes'
    Run $cmake @('-S',$Repo,'-B',$build,'--fresh','-G',$vs.Generator,'-A','x64',
        ('-DFLEX_EXECUTABLE=' + $flex.FullName),('-DBISON_EXECUTABLE=' + $bison.FullName),
        ('-DSDL2_INCLUDE_DIR=' + $sdl.Include),('-DSDL2_LIBRARY=' + $sdl.Library),
        ('-DSDL2_IMAGE_INCLUDE_DIR=' + $sdlImage.Include),('-DSDL2_IMAGE_LIBRARY=' + $sdlImage.Library),
        ('-DCMAKE_TOOLCHAIN_FILE=' + $vcpkgToolchain),
        '-DVCPKG_TARGET_TRIPLET=x64-windows-static-md',
        ('-DBOOST_ROOT=' + $boostPrefix),
        '-DDISCORD_ENABLED=OFF','-DDTV=OFF',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
    Run $cmake @('--build',$build,'--config','Release','--target','engine-sim-app','--parallel','6')
    $engineExe = Get-ChildItem -Path $build -Filter 'engine-sim-app.exe' -Recurse -File | Where-Object { $_.FullName -match '\\Release\\' } | Select-Object -First 1
    Ensure ([bool]$engineExe) 'Build ended without engine-sim-app.exe.'
    Say ('Engine Simulator built: ' + $engineExe.FullName)
    $dumpbinTools = @(Get-ChildItem -Path (Join-Path $vs.Path 'VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe') -File -ErrorAction SilentlyContinue)
    Ensure ($dumpbinTools.Count -gt 0) 'MSVC dumpbin.exe missing; cannot verify the Release executable dependencies.'
    Assert-ReleaseDirectXDependencies $dumpbinTools[0].FullName $engineExe.FullName

    # EngineSim resolves shaders/fonts from the executable folder using delta.conf.
    $exeDir = Split-Path -Parent $engineExe.FullName
    $deltaBasic = Join-Path $Repo 'dependencies\submodules\delta-studio\engines\basic'
    $assetDir = Join-Path $Repo 'assets'
    # Absolute paths are supported by the source application only as combined with modulePath;
    # use a relative path from the location of the actual executable for compatibility.
    $exeUri = [Uri]((Resolve-Path $exeDir).Path.TrimEnd('\') + '\')
    function Relative([string]$target) {
        $targetUri = [Uri]( (Resolve-Path $target).Path.TrimEnd('\') + '\')
        return [Uri]::UnescapeDataString($exeUri.MakeRelativeUri($targetUri).ToString()).Replace('/','\').TrimEnd('\')
    }
    $conf = (Relative $deltaBasic) + "`n" + (Relative $assetDir) + "`n"
    Write-UTF8 (Join-Path $exeDir 'delta.conf') $conf
    Copy-Item -LiteralPath $sdl.Runtime -Destination $exeDir -Force
    Copy-Item -LiteralPath $sdlImage.Runtime -Destination $exeDir -Force
    Install-LegacyDirectX

    Wait-ForGameExit
    Say 'Installing UE4SS into Motor Town...'
    $ueDir = Join-Path $win64 'ue4ss'
    $ueDll = Join-Path $ueDir 'UE4SS.dll'
    $legacyDll = Join-Path $win64 'UE4SS.dll'
    if ((Test-Path $ueDll) -or (Test-Path $legacyDll)) {
        Say 'Existing UE4SS detected; preserving current installation.'
    } else {
        $release = Get-Release 'UE4SS-RE/RE-UE4SS' 'tags/experimental-latest'
        $asset = @($release.assets | Where-Object { $_.name -match '^UE4SS_v.*\.zip$' } | Select-Object -First 1)
        if ($asset.Count -eq 0) {
            $asset = @($release.assets | Where-Object { $_.name -match '^zDEV-UE4SS_v.*\.zip$' } | Select-Object -First 1)
        }
        Ensure ($asset.Count -eq 1) 'Could not locate official UE4SS experimental ZIP asset.'
        $archive = Join-Path $Deps 'UE4SS-experimental.zip'
        $extract = Join-Path $Deps 'UE4SS-experimental-extract'
        Download $asset[0].browser_download_url $archive
        if (Test-Path $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
        $proxies = @(Get-ChildItem -Path $extract -Recurse -File -Filter 'dwmapi.dll')
        Ensure ($proxies.Count -gt 0) 'UE4SS release ZIP has no dwmapi.dll proxy.'
        $root = Split-Path -Parent $proxies[0].FullName
        $modern = Join-Path $root 'ue4ss'
        $destProxy = Join-Path $win64 'dwmapi.dll'
        Ensure (-not (Test-Path $destProxy)) ('Existing dwmapi.dll is not confirmed as UE4SS: ' + $destProxy)
        if (Test-Path (Join-Path $modern 'UE4SS.dll')) {
            New-Item -ItemType Directory -Path $ueDir -Force | Out-Null
            Copy-Item -Path (Join-Path $modern '*') -Destination $ueDir -Recurse -Force
        } elseif (Test-Path (Join-Path $root 'UE4SS.dll')) {
            Copy-Item -Path (Join-Path $root '*') -Destination $win64 -Recurse -Force
        } else { throw 'UE4SS release ZIP layout unrecognized. No game files changed.' }
        Copy-Item -LiteralPath $proxies[0].FullName -Destination $destProxy
    }

    Say 'Installing MotorTown telemetry mod...'
    $modsParent = if ((Test-Path $legacyDll) -and -not (Test-Path $ueDll)) { $win64 } else { $ueDir }
    $modRoot = Join-Path $modsParent 'Mods\MotorTownEngineSim'
    $modScripts = Join-Path $modRoot 'Scripts'
    New-Item -ItemType Directory -Path $modScripts -Force | Out-Null
    $lua = Decode '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'
    $luaDst = Join-Path $modScripts 'main.lua'
    if (Test-Path $luaDst) {
        Copy-Item $luaDst ($luaDst + '.backup-' + (Get-Date -Format 'yyyy-MM-dd-HH-mm'))
    }
    Write-UTF8 $luaDst $lua
    Write-UTF8 (Join-Path $modRoot 'enabled.txt') ''
    $modList = Join-Path $modsParent 'Mods\mods.txt'
    if (Test-Path $modList) {
        $lines = @(Get-Content -LiteralPath $modList)
        $lines = @($lines | Where-Object { $_ -notmatch '^\s*MotorTownEngineSim\s*:' })
        $lines += 'MotorTownEngineSim : 1'
        Write-UTF8 $modList (($lines -join "`r`n") + "`r`n")
    }

    Say 'Setup completed. Game telemetry is still unverified.'
    Say ('Motor Town: ' + $gameExe)
    Say ('EngineSim: ' + $engineExe.FullName)
    Say ('Diagnostic file after driving: ' + (Join-Path $env:TEMP 'MotorTownEngineSim_diagnostics.txt'))
    if (-not $NoLaunch) {
        Start-EngineSimulator $engineExe $build
    }
    Write-Host 'SETUP FINISHED - GAME / AUDIO STILL UNVERIFIED' -ForegroundColor Yellow
    exit 0
} catch {
    Write-Host ('INSTALL FAILED: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('Log: ' + $Log) -ForegroundColor Yellow
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
