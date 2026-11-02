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
