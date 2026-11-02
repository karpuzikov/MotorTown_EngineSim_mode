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
