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
