#requires -Version 7.0
<#
  One-command Windows development build for MotorTownEngineSim.
  The user's tutorial (S:\MyMods) and Motor Town installation are never edited.
  This builds an unverified DLL, NOT a playable release or installer.
#>
param(
    [string]$WorkDir = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Karpuzikov Tools\MotorTown EngineSim Mod'),
    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ue4ssCommit = 'f885e8d2d4dd25258082538f1a9fd56a1c3b1bf1'
$modBranch = 'feat/native-engine-audio'
$ue4ssRepo = 'https://github.com/UE4SS-RE/RE-UE4SS.git'
$modRepo = 'https://github.com/karpuzikov/MotorTown_EngineSim_mode.git'
$flexUrl = 'https://github.com/lexxmark/winflexbison/releases/download/v2.5.25/win_flex_bison-2.5.25.zip'
$flexSha256 = '8d324b62be33604b2c45ad1dd34ab93d722534448f55a16ca7292de32b6ac135'
$WorkDir = [IO.Path]::GetFullPath($WorkDir)

$ue4ssSource = Join-Path $WorkDir 'source\RE-UE4SS'
$modSource = Join-Path $WorkDir 'source\MotorTown_EngineSim_mode'
$buildDir = Join-Path $WorkDir 'build\UE4SS'
$devDll = Join-Path $buildDir 'dev-stage\ue4ss\Mods\MotorTownEngineSim\dlls\main.dll'

if ($PlanOnly) {
    Write-Host "Sources and dependencies: $WorkDir"
    Write-Host "Pinned UE4SS revision: $ue4ssCommit"
    Write-Host "Development DLL output: $devDll"
    Write-Host 'Plan only: no downloads, installations, game changes or build.'
    exit 0
}

function Get-PreferredVcpkgRoot {
    # The persistent setting, not this process's copy (a previous build in the
    # same PowerShell session may have changed $env:VCPKG_ROOT).
    foreach ($scope in @('User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable('VCPKG_ROOT', $scope)
        if ($value) { return $value }
    }
    return $env:VCPKG_ROOT
}

function Select-VcpkgRoot([string]$Preferred, [string]$LocalRoot, [string]$SystemRoot = 'C:\vcpkg') {
    if ($Preferred -and (Test-Path -LiteralPath ([IO.Path]::Combine($Preferred, '.vcpkg-root')) -PathType Leaf)) {
        $missing = -not (Test-Path -LiteralPath ([IO.Path]::Combine($Preferred, 'vcpkg.exe')) -PathType Leaf)
        return [pscustomobject]@{ Root = $Preferred.TrimEnd('\', '/'); Clone = $false; Bootstrap = $missing
            Reason = $(if ($missing) { 'VCPKG_ROOT; vcpkg.exe missing, bootstrapping it' } else { 'VCPKG_ROOT' }) }
    }
    if ($SystemRoot -and (Test-Path -LiteralPath ([IO.Path]::Combine($SystemRoot, 'vcpkg.exe')) -PathType Leaf)) {
        return [pscustomobject]@{ Root = $SystemRoot; Clone = $false; Bootstrap = $false; Reason = $SystemRoot }
    }
    $hasGit = Test-Path -LiteralPath ([IO.Path]::Combine($LocalRoot, '.git'))
    $hasExe = Test-Path -LiteralPath ([IO.Path]::Combine($LocalRoot, 'vcpkg.exe')) -PathType Leaf
    return [pscustomobject]@{ Root = $LocalRoot; Clone = -not $hasGit; Bootstrap = -not $hasExe; Reason = 'project-local' }
}

function Get-CMakeCacheValue([string]$CachePath, [string]$Name) {
    if (-not (Test-Path -LiteralPath $CachePath -PathType Leaf)) { return $null }
    foreach ($line in [IO.File]::ReadLines($CachePath)) {
        if ($line -match ('^' + [regex]::Escape($Name) + ':[A-Za-z]+=(.*)$')) { return $Matches[1].Trim() }
    }
    return $null
}

function Test-SamePath([string]$Left, [string]$Right) {
    if (-not $Left -or -not $Right) { return $false }
    $a = $Left.Replace('/', '\').TrimEnd('\')
    $b = $Right.Replace('/', '\').TrimEnd('\')
    return [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)
}

# CMake ignores a changed CMAKE_TOOLCHAIN_FILE in an existing cache, so a build
# directory first configured with another vcpkg must be reconfigured from scratch.
function Get-StaleBuildConfiguration([string]$BuildDir, [string]$VcpkgRoot) {
    $cache = [IO.Path]::Combine($BuildDir, 'CMakeCache.txt')
    if (-not (Test-Path -LiteralPath $cache -PathType Leaf)) { return $null }
    $root = $VcpkgRoot.TrimEnd('\', '/')
    $cachedToolchain = Get-CMakeCacheValue $cache 'CMAKE_TOOLCHAIN_FILE'
    if (-not (Test-SamePath $cachedToolchain ($root + '\scripts\buildsystems\vcpkg.cmake'))) {
        return "vcpkg toolchain '$cachedToolchain'"
    }
    # A Visual Studio update removes the MSVC version the cache points at; CMake then
    # refuses to configure ("not a full path to an existing compiler tool").
    $cachedCompiler = Get-CMakeCacheValue $cache 'CMAKE_CXX_COMPILER'
    if ($cachedCompiler -and -not (Test-Path -LiteralPath $cachedCompiler -PathType Leaf)) {
        return "compiler '$cachedCompiler', gone after a Visual Studio update"
    }
    # VCPKG_INSTALLED_DIR is passed with -D on every configure, so a different
    # cached value does not need a fresh configure.
    return $null
}

function Test-PathUnder([string]$Path, [string]$Root) {
    if (-not $Path -or -not $Root) { return $false }
    $p = $Path.Replace('\', '/').TrimEnd('/')
    $r = $Root.Replace('\', '/').TrimEnd('/')
    return [string]::Equals($p, $r, [StringComparison]::OrdinalIgnoreCase) -or
        $p.StartsWith($r + '/', [StringComparison]::OrdinalIgnoreCase)
}

# On the user's PC the VCPKG_ROOT vcpkg (C:\Users\...\AppData\Local\vcpkg, then
# without vcpkg.exe) was pulled into the configure even when another vcpkg was
# selected: post-build z-applocal called its missing vcpkg.exe (MSB3073, exit
# 9009) and the final cache reverted to its root, packages and applocal=ON.
# Refuse any configuration whose post-build step needs a missing vcpkg.exe, and
# any generated project that references a vcpkg other than the selected one.
function Assert-VcpkgConfiguration([string]$BuildDir, [string]$VcpkgRoot) {
    $cache = [IO.Path]::Combine($BuildDir, 'CMakeCache.txt')
    $root = $VcpkgRoot.TrimEnd('\', '/')
    if ((Get-CMakeCacheValue $cache 'VCPKG_APPLOCAL_DEPS') -notmatch '^(OFF|FALSE|0|NO)$') {
        $applocalRoot = Get-CMakeCacheValue $cache 'Z_VCPKG_ROOT_DIR'
        if (-not $applocalRoot -or -not (Test-Path -LiteralPath ([IO.Path]::Combine($applocalRoot, 'vcpkg.exe')) -PathType Leaf)) {
            throw "vcpkg post-build applocal is enabled but '$applocalRoot\vcpkg.exe' does not exist."
        }
    }
    $foreign = [Collections.Generic.List[string]]::new()
    foreach ($name in @('Z_VCPKG_ROOT_DIR', 'VCPKG_INSTALLED_DIR', '_VCPKG_INSTALLED_DIR')) {
        $value = Get-CMakeCacheValue $cache $name
        if ($value -and -not (Test-PathUnder $value $root)) {
            Write-Host "Note: CMake cache $name = '$value' (not the selected vcpkg $root)." -ForegroundColor Yellow
            $foreign.Add($value.Replace('\', '/').TrimEnd('/'))
        }
    }
    if ($foreign.Count -eq 0) { return }
    # Clues for whatever supplies the other vcpkg on this machine.
    $hints = @(Get-ChildItem env: | Where-Object { $_.Name -like '*VCPKG*' -or $_.Value -like '*\vcpkg*' } |
        ForEach-Object { "$($_.Name)=$($_.Value)" })
    if ($hints.Count -gt 0) { Write-Host ('Note: environment ' + ($hints -join '; ')) -ForegroundColor Yellow }
    $projects =@(Get-ChildItem -LiteralPath $BuildDir -Recurse -File -Filter '*.vcxproj' -ErrorAction SilentlyContinue)
    foreach ($path in ($foreign | Select-Object -Unique)) {
        foreach ($project in $projects) {
            $text = [IO.File]::ReadAllText($project.FullName)
            if ($text.IndexOf($path, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $text.IndexOf($path.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw "Generated project $($project.FullName) uses another vcpkg ('$path')."
            }
        }
    }
    Write-Host "Checked $($projects.Count) generated projects: none use another vcpkg." -ForegroundColor Green
}

function Invoke-Checked {
    param([string]$Description, [string]$Executable, [string[]]$Arguments)
    Write-Host "`n==> $Description" -ForegroundColor Cyan
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed (exit $LASTEXITCODE). See the build transcript."
    }
}

foreach ($name in @('git', 'cmake')) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Missing $name. Install Git for Windows and CMake before building."
    }
}

New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'logs') | Out-Null
$logPath = Join-Path $WorkDir ('logs\build-' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss') + '.log')
Start-Transcript -Path $logPath | Out-Null
$originalVcpkgRoot = $env:VCPKG_ROOT

try {
    Write-Host 'Motor Town EngineSim - native DLL development build' -ForegroundColor Yellow
    Write-Host "Build transcript: $logPath"
    Write-Host 'No files in S:\MyMods or your installed game will be changed.'

    New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'source') | Out-Null
    if (-not (Test-Path (Join-Path $ue4ssSource '.git'))) {
        if (Test-Path $ue4ssSource) { throw "Refusing non-Git source directory: $ue4ssSource" }
        Invoke-Checked 'Clone UE4SS source' 'git' @('clone', $ue4ssRepo, $ue4ssSource)
    }
    Invoke-Checked 'Fetch matching UE4SS revision' 'git' @('-C', $ue4ssSource, 'fetch', '--no-tags', 'origin', $ue4ssCommit)
    Invoke-Checked 'Select matching UE4SS revision' 'git' @('-C', $ue4ssSource, 'checkout', '--detach', $ue4ssCommit)
    Invoke-Checked 'Synchronize UE4SS dependency URLs' 'git' @('-C', $ue4ssSource, 'submodule', 'sync', '--recursive')

    # Official .gitmodules uses SSH. Rewrite for this operation only so Git
    # Credential Manager can open its normal browser login, without a PAT in
    # source or a new GitHub Actions secret. Never bypass access restrictions.
    Invoke-Checked 'Download authorized Unreal submodules (Git may request browser login)' 'git' @(
        '-C', $ue4ssSource, '-c', 'url.https://github.com/.insteadOf=git@github.com:',
        'submodule', 'update', '--init', '--recursive')

    if (-not (Test-Path (Join-Path $modSource '.git'))) {
        if (Test-Path $modSource) { throw "Refusing non-Git mod directory: $modSource" }
        Invoke-Checked 'Clone Motor Town mod development branch' 'git' @(
            'clone', '--branch', $modBranch, '--single-branch', $modRepo, $modSource)
    }
    Invoke-Checked 'Update Motor Town mod development branch safely' 'git' @(
        '-C', $modSource, 'pull', '--ff-only', 'origin', $modBranch)

    $verifyScript = Join-Path $modSource 'native\ue4ss-parent\verify_checkout.py'
    if (-not (Test-Path $verifyScript)) { throw "Missing UE4SS checkout verifier: $verifyScript" }
    if (Get-Command 'py' -ErrorAction SilentlyContinue) {
        Invoke-Checked 'Verify UE4SS ABI revision and private submodules' 'py' @('-3', $verifyScript, $ue4ssSource)
    } elseif (Get-Command 'python' -ErrorAction SilentlyContinue) {
        Invoke-Checked 'Verify UE4SS ABI revision and private submodules' 'python' @($verifyScript, $ue4ssSource)
    } else {
        throw 'Python 3 is required by the Engine Simulator build. Install Python 3 and retry.'
    }

    # The machine's own VCPKG_ROOT (user/system setting) wins: on the user's PC its
    # vcpkg.cmake was pulled into the configure even when another vcpkg was
    # selected, so any second vcpkg produced a mixed, broken build.
    $preferredVcpkg = Get-PreferredVcpkgRoot
    $vcpkg = Select-VcpkgRoot $preferredVcpkg (Join-Path $WorkDir 'dependencies\vcpkg')
    $vcpkgRoot = $vcpkg.Root
    Write-Host "vcpkg: $vcpkgRoot ($($vcpkg.Reason))"
    if ($vcpkg.Clone) {
        if (Test-Path $vcpkgRoot) { throw "Refusing non-Git vcpkg directory: $vcpkgRoot" }
        New-Item -ItemType Directory -Force -Path (Split-Path $vcpkgRoot -Parent) | Out-Null
        Invoke-Checked 'Download Microsoft vcpkg' 'git' @(
            'clone', 'https://github.com/microsoft/vcpkg.git', $vcpkgRoot)
    }
    if ($vcpkg.Bootstrap) {
        Invoke-Checked "Bootstrap vcpkg.exe in $vcpkgRoot" (Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat') @('-disableMetrics')
    }
    # Every vcpkg/CMake step below must see the vcpkg selected above, not an
    # inherited VCPKG_ROOT that may point at a removed installation.
    $env:VCPKG_ROOT = $vcpkgRoot
    Invoke-Checked 'Install original SDL2 and Boost build dependencies' (Join-Path $vcpkgRoot 'vcpkg.exe') @(
        'install', 'sdl2:x64-windows', 'sdl2-image:x64-windows', 'boost-filesystem:x64-windows')

    # Flex/Bison from the upstream release, pinned to a published SHA-256.
    $downloads = Join-Path $WorkDir 'downloads'
    $flexFolder = Join-Path $WorkDir 'dependencies\winflexbison'
    $flexZip = Join-Path $downloads 'win_flex_bison-2.5.25.zip'
    New-Item -ItemType Directory -Force -Path $downloads | Out-Null
    if (-not (Test-Path $flexZip)) {
        Write-Host '==> Download WinFlexBison 2.5.25' -ForegroundColor Cyan
        Invoke-WebRequest -Uri $flexUrl -OutFile $flexZip
    }
    if ((Get-FileHash -Path $flexZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $flexSha256) {
        throw "WinFlexBison archive checksum mismatch: $flexZip. Refusing to run it."
    }
    if (-not (Test-Path (Join-Path $flexFolder 'win_flex.exe'))) {
        Expand-Archive -Path $flexZip -DestinationPath $flexFolder -Force
    }
    $flexExe = Join-Path $flexFolder 'win_flex.exe'
    $bisonExe = Join-Path $flexFolder 'win_bison.exe'
    if (-not (Test-Path $flexExe) -or -not (Test-Path $bisonExe)) {
        throw "WinFlexBison executables missing after extraction: $flexFolder"
    }
    $env:PATH = "$flexFolder;$env:PATH"

    # CMake autodetects the user's installed VS (VS 18 2026 in the log).
    # Pin x64 and the shipping configuration to match the UE4SS CRT/ABI.
    $cmakeArgs = @(
        '-S', (Join-Path $modSource 'native\ue4ss-parent'),
        '-B', $buildDir,
        '-A', 'x64',
        "-DMTES_UE4SS_SOURCE=$ue4ssSource",
        "-DMTES_VCPKG_RUNTIME_BIN=$(Join-Path $vcpkgRoot 'installed\x64-windows\bin')",
        # CMake 4.4 rejects the pinned Engine Simulator's older GoogleTest
        # CMakeLists unless its compatibility floor is explicitly allowed.
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
        "-DCMAKE_TOOLCHAIN_FILE=$(Join-Path $vcpkgRoot 'scripts\buildsystems\vcpkg.cmake')",
        # Use only the selected vcpkg's packages, and never run a vcpkg.exe after
        # linking: mtes-stage-dev copies the runtime DLLs from that same tree.
        "-DVCPKG_INSTALLED_DIR=$((Join-Path $vcpkgRoot 'installed').Replace('\', '/'))",
        '-DVCPKG_APPLOCAL_DEPS=OFF',
        "-DFLEX_EXECUTABLE=$flexExe", "-DBISON_EXECUTABLE=$bisonExe"
    )
    $staleConfiguration = Get-StaleBuildConfiguration $buildDir $vcpkgRoot
    if ($staleConfiguration) {
        # --fresh (CMake 3.24+) rebuilds only the cache; compiled objects are kept.
        Write-Host "Build directory was configured with another $staleConfiguration. Reconfiguring from scratch." -ForegroundColor Yellow
        $cmakeArgs = @('--fresh') + $cmakeArgs
    }
    Invoke-Checked 'Configure native UE4SS + Engine Simulator DLL' 'cmake' $cmakeArgs
    Assert-VcpkgConfiguration $buildDir $vcpkgRoot
    Invoke-Checked 'Compile and stage native UE4SS DLL' 'cmake' @(
        '--build', $buildDir, '--config', 'Game__Shipping__Win64',
        '--target', 'mtes-stage-dev', 'mtes-stage-ue4ss-runtime', '--parallel', '4')

    if (-not (Test-Path $devDll -PathType Leaf) -or (Get-Item $devDll).Length -le 0) {
        throw "Build reported success but did not produce main.dll: $devDll"
    }
    Write-Host "`nDevelopment DLL: $devDll" -ForegroundColor Green
    Write-Host ('SHA256: ' + (Get-FileHash -Path $devDll -Algorithm SHA256).Hash)
    Write-Host 'This DLL is NOT YET a working engine sound replacement. Do not install it as one.' -ForegroundColor Yellow
}
finally {
    # Leave the caller's PowerShell session as it was.
    $env:VCPKG_ROOT = $originalVcpkgRoot
    Stop-Transcript | Out-Null
    Write-Host "Build log: $logPath"
}
