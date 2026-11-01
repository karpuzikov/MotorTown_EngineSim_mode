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
