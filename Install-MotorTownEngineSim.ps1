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
    $over = Decode 'H4sIAAAAAAAC/41UwW7iMBC98xXTHqpwANrDXqig0narqtIiVQX1itxkklhre5A9XoS2++87cQIJWg7NAWT7vTfzxjMegXyzGaw2T+vt97eXH89P2/e7OaCrtEPIybEnI/8WA5AzByg9WfnBUEOlLAKjQYvsD9PRUYuYPGxo72BXH4LOAyiPEB1TzGss7iGwcoUyJBF+4eGDlC+OoVpsoYP6MFi0mrqEzG51jk9tVosFuGjMjj18foLdBm2jUU3Q/mQMHjl6d58UVrw5pgmW2z0JGBg+KNlzDnPGAhZCU8UAnlke/4cnJ8CedHMjolMfndOuOq52FpYL+HY7vW3pgzQnywq59ZKN0+Klcpo1uRUV0aRNu0WXSiCRyF2QkAUrz+hTuadDfKlMwIuU4uBo+gXpDleTOQc1++sddlR4kEvVHOZzcZu1pscwh8ueT6qeWDVmj0ID2cul2njlgtUhCKmpTV4rV+EzKp9N7sZf4wTkRxM5r1+ldUP0mEmWPbcJvkbm5gKbjKS0IrI+306OxSbXYoENnls99WcKlqiPbU9n5wG6qM2kxKQs10UQtEGXy5TlpAJPChmfmYzdrklXPIAjHRD2tcCa8Th133BEVCw0rSn6HOFqMApnJ5Ol5PFOJlrMkqO76W3ZWim71LqBcyVJzYL02Jnan4TpTPeYZPsnVStJWFWYXfUD8gDXqUubN2EOe6WT7VIG9vR6XJ9Em2/e1nrIMvo3Hp+lniXIIag7p7KEmVQM3l5X152nv6N/fCKFiuwEAAA='
    $hdr = Decode 'H4sIAAAAAAAC/3VU204bMRB936+YgEQ3os2t6guBSFQgykNaBFGpVFWR2Z1N3O7aK3vcEEH+veO9ZI2U7sPKnsvxOTNjD4cwX1w/LD/f317dXC+/j6NjmaWYwfLx9uvHCe9UkrsU4XwjVao3drCeRceoUpkFvsySQVHMAlNCssA3hkIQ50ZKFGhLkSC8RJzmEoI5LTDHAsls2Qj8pdo95QimLOACRoPRNLTS2mgiXgSuJ61zME4pqVZsz0RucRrtplE0HMJijYDPpTaEBjZGElrQKt8CaQZDSJwxqAicRfPOAmHBsYLJpNJgQtpsBx7mHn/zDiwJPpsV/EGyUxBs0GWJKaxYGRTOEihNkKP4y8eqlVQIwqVSt/wGUc0WRRooj8MqnGhHfa7F22Z4oclamI7Xz/nlj+Xd5eILnML4Fwt/2dX1uHr8dn8Fii03yLhFecfVv4zb8PcdRL9OkBnEHM4lhddXTpxBG9tnpuSMaovqoy2lZ2eyaTtIFVcG3rK8uINmVkdzzcuF3qjrqhQPslhSq3NAz3QUEOhJ9d/TanCwcqUEBzQuyW1DJXgsUj8OtTHXHFj9sNTJunNUZ8SS1c06IL/hcg/8sDXL/YTxvkX3S4/WP8TQA3eAvQuWzbdqfORr2auLZTOpePLi5qg+u6pU/x0IaSn4uD2987o7e7Yw+TQajUKkN+yD8E4RjL0tbmX1fMdPTiDYjw9KTLTiyRaO74zSG64p3wOSyTIRls73FZ/Vk+Avf6xcnpdk+kGD637MKoTTmolffoDWMTl0dKV3f7dD5rW/yeDHhBOOkfNCcwPUPFq7aAd8l4XSaltoZ2H/HkX/AFj/9ysMBQAA'
    $legacyOver = Decode 'H4sIAAAAAAAC/51UTW/bMAy951fwVDiHOu1hlxTpgLVZ0UOAogm2Y6DIjC1MH4ZENwiG/vdRsuc5bZA11cHWB/lIPT5xBDwmE1is5sv1t+fH+4f5+sf1FIIWLwhUIYimUA6CMo0W5DyQg4WLk5XbWdhVaIFQo0Hye1ABtHrBfNTBrhigc1XOgkcjlA0Jt0TbKIswt2X8LfsA0plNE6L9pI2NyaLHHESvq31QMoDwCI0l18gKixuG5zxq7ySGAM7qPWyd1m4XQFEA6YX9FSqxJXh+WrSwv9M3jkCcqoSNcxoM/RThzlmLkrCAGWyFDnjT2y5o1d/c0L99tYXMoygG55mh8XgQJo538OSbAXoc0tlAbTJM34xdct9Yq2wJFxdpVRu4ncGXq/zq0NOs+5Jd3pZILc3ZOC0eS6siwQtXNDptmjVasdEpDWdPQPGChCf0qQz50O8NO0dci711+RmhOvvK6ePG8XxZYwcFX1kEXOHplFnJWnLGMIXT3PRRvKOk0r+AA/jT1K5YUMGoENg5cikrYUt8QOGzy+vxeb4B6U43JKsnz+JtPGac/XuMmNQSiaIQYqZcEgZbHm4nRpgGqvhqpPE4FUpiq40UPEGwJsk7nR0GGmTx2s+QS570fijmt1LnZ/tdKM29QKOlrmvEJiAMgtQuID9UP2gkhQqirpnCkJ8lqA9rsNPU/+0/LffzHt1xtA/V+byiHuqpreTr6A81EQt3CAYAAA=='
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
