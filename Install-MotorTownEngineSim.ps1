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
