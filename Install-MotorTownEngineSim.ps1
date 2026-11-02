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
