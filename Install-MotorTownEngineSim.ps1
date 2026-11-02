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
