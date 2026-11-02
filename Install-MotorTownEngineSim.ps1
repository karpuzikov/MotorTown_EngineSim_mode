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
