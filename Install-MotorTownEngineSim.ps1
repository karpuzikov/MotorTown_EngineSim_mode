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
    $runtimePatch = Decode 'H4sIAAAAAAAC/91Ya1MjuRX9KzfeKuJmoA3sTpI1A1UeMKxrhkfZnp2k4i2X6L7GyrSljqSGcSb891xJbbvbtMG8voQqoB/qo6tzz31IP2oTpr6hqjWh1mjAWb/dG3a/nPc7Z+3h77u1LaiNkcWohikzYzuIiyjJYmxMDOqhyoThEwzHi4HVQAPxU6rY9YSBFBHSXQ4DH/B7hKnhUhwWn460UcgmpWfaxH7w0lPFxTU9GgguEi4QbiSPwZrX9dZ9ltf1SAptgBCaTf8BbExQa3aNAfwYCKAfMroFChNm+A3CiCco2ASBJVrCrVTfNNyOUYAZI2Qa1Z81HMsom6AwGiw5wDV8ETySMYYe0U0n86VAQmYMamfSSNWXt6ItrsnYHp/MSaQBA+LRfcWlbjZZmgb7HorewYcPkNtsL90wFHFCI+4GwjqArIjGqMkD//xRm/lLq6gxYVyEUZraQRhzkw+5wpFUaAfN6RzUwrAxczE6E4eabCRTEh4x66dwPKhZIDYy3ttP/bjgvdIXZUXZcRWCvNuCouGWmzmTrcU8UJgzp7BoBRfccJbw/2C97uSyGWyMOyQRRurcgqk+ksLgd3Nx9S+MTLN5jDc8wtZlhy65okd/390NKnDJ+nrV8xhJBHLq3vm3Ck2mBOzsl6i8p5onKsbQmygIo0RqnBuyFAoFxAV1kEPCzU64F/51UJt9bNR0FiCVWJ0ZkzamPBwQXkZhJNUCJg+wY0wMo8hxfGQRDdHExL8z4hTwu+WLGzDIVGytYyIGRm8yodmIItGyBKwEmDJlp4e5Qz3fcCFgxHiSKfKmwlQqA4RsARM0kCoZUSTRlNyU4Mi1CbNsoJaZojH7EEsQ0pANt9yaA2OWjLYX+olLfl6AscxI2Cy8gwMQeFsp1gJHhQ+2D19TpdVCsMHV67e6/S+Xw267dfyPssdK1hS1XYm27H1wMowfgCyGxWxAjOQhrIjfUtT4R3f+X2TzHhRz/LyowAYqJVXwgIYLRYEWkacaOGl1PrePm5ShAngHDiS8HTNTD4rGnvl8/FF+b9VFliSpUVulwVtQHW7kQ2Wy1InUUrQFZx+HF5/gv/Z/5+jivN3tXnSD+0vfrVx6GIbBg2G6vKxMfBPWoqN3tLgZWWVPVa6twst+CSH0EOHhXBXSOhf49uetyKnd/eEKRbEIrihI/7dlcTL0c4VHVEgMnlIz85VSmLytazSG1K6D+8XnnnDcxza3XyuWjnmkGyyLOXVEDmof9Ng2ffpgUKMw8TeXRPrMOT4mp7ptY8Khexv8/cFaRnokPoL68vd/OphBN5vnUmApBsxYyVufDnL2hi4yaVGn5bWUi0cuO6i7YuWjGezyytJ1wEYO88xBmjU8GkZMmw9cmMNlWwObRijAKE4cSRC7DC3VtAkruLtbUb5PqzwBhZJk47haEUwTrWdMUFyr8EhOUlpph2qIisZMXOMJ3dbr+TBrirO54W61NT6yy7VZbTfcGW1Rc5DhOiL6LFlc1BB4xHzlhfnmLcsbWfo4KdbUXoTiCTOsYuGVgB9RQc4l7RBIPytd7+PwSsqELh2ZMUVffqnC/KLuEo8H9JuGievh1kgTDsD62Mcz6Ejx1DThHh7UYzQUYZoU64NraEsD/QaL+vNCc5cI+Im2SZQ+GpvQ6p8O2+ennfP2sNc5G152uq3z31r0qPWRyiJsNmbtuc02N0j8JggH1Ln5+kf5pZzinwecU1TCXStv9WnvWeKXskjs2tPIpU9qcPP3vhyX6LV8X2U8ibet98IF2avyTLs000Jfj3NUGWZ61jFsH7oC37LZq0sMok2g/TGtIK6vo7We/dpKLUe0PbjLhMqBYWHbsfasKyjorZjBtyirw21WvEJfAb7ymML8AHZ/3Zu1rksjfkN+PTZ2yM7fqvaE1Xi//uUxuPe/7FQaaH03/8Yt5oTcR65GFOVOclagT9EUqnOwfdhD4296ZkqxOM2rXbNZeNpsFmDnzdny6qifscq+Ujymsw06RmEu1Jmw1diXN+qqb+jwxZ3AzEU+k6bdQdJOQsNoPlk4ryOLJqu3Yr1E04hOeXCumZet2N9gvLLcWCX13PbSQf4uEzpFqts6VV1FqsfvuPGWu6+MtrY0ByT24Mo11OA66pwlQzuqCdJGPqwyKJbZFQWwTtHlWDIDGvZvse2aMdLRn3B6TNC0drpqNo/osItar92gpJk5lkXaCZd2a0hUrwe79xDsC3B/Xo279xLcX1bjvn8J7vsHeSgBr++0kyWnTYYx12nCpi1xTXp4R0GhSP3D2MCma6Keaf3J3oPzbD95nkt/eFM92c8PTnYAO6UJqooEmjzp24xhma47vitCk0LvE2Lqwy6PNV8mmM1JLNl2J2ru831bMUTMEmnTVkIFfiLdZoOyHZnIruwWutj73A/LUt2tr85SHd2K7BF2PYCNDVhHBq+ig9ezaC94HcU83aLHpPV22lpKzGtZ1NYRSzEo6fJ115zPEDzLvK47k3lL8/IZnmden129pW0W/nmGnbylWSfPdabtJ9/Ul26CwB7c/XH3PxkQ1p6VHAAA'
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
