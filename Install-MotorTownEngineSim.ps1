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
