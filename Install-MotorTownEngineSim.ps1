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
