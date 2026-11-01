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
