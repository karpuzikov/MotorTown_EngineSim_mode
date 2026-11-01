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
