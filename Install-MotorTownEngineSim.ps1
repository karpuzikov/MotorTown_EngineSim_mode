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
