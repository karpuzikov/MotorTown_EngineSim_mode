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
