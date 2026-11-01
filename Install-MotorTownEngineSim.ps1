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
