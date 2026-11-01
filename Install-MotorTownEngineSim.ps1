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
