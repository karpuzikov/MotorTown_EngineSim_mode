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
