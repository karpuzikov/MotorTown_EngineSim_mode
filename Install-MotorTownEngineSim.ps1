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
