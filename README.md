# Motor Town + Engine Simulator Bridge

Experimental Windows mod project to synchronize combustion audio from [karpuzikov/engine-sim](https://github.com/karpuzikov/engine-sim) with the player's vehicle in [Motor Town: Behind The Wheel](https://store.steampowered.com/app/1369670/Motor_Town_Behind_The_Wheel/).

**Version: experimental v0.2.8.** Windows compilation and DirectX runtime installation are confirmed by the user's logs. The v0.2.7 executable was then blocked by a missing `d3dx10d_43.dll`: the pinned Delta Studio CMake file linked debug DirectX libraries into Release builds. This version fixes configuration-specific linkage and checks the built executable's DLL imports before launch. Windows rendering, telemetry detection and synchronized live audio remain **unverified**.

## Installation

1. Download `Install-MotorTownEngineSim.bat` from this repository.
2. Double-click the BAT on Windows 11 and accept any required UAC prompt.
3. The installer locates Motor Town, installs build dependencies if needed, downloads and patches Engine Simulator, builds it, and installs the UE4SS bridge.
4. Motor Town may need to be closed while its files are updated. The installer will wait rather than force-close it.

Fresh installs clone `karpuzikov/engine-sim`. Existing installs switch their `origin` remote to that fork while preserving the checkout, submodules, local patches, dependencies and build files. Third-party submodules continue to use their own upstream repositories.

The installer repairs Delta Studio's DirectX link configuration in place and rebuilds with retail libraries for Release. It does not require the DirectX debug runtime. MSVC `dumpbin` checks the resulting executable before launch and records its DLL dependencies in the installation log.

If startup fails or remains blank, the installer prints the last startup stage and any engine-script errors into its installation log. The live runtime log is `source/engine-sim/build-mtes/MotorTownEngineSim_runtime.log` under the project directory. It records graphics, asset, engine-script and audio initialization separately. Startup readiness does not verify rendering, sound or game telemetry.

**Known limitation:** No fully native spatial audio replacement yet; the simulator runs as a separate audio source. Motor Town's game telemetry field names are not confirmed for all versions; see `bridge/README.md`.

## Files

- `Install-MotorTownEngineSim.bat`: single-file embedded PowerShell installer (latest launcher).
- `Install-MotorTownEngineSim.ps1`: standalone installer source (for development).
- `bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua`: UE4SS telemetry producer.
- `bridge/patch_engine_sim.py`: source patcher for Engine Simulator.
- `bridge/tests/test_patch.py`: patching tests.
- `bridge/tests/test_runtime_patch.py`: executable startup failure/success and safe patching checks.
- `bridge/package_installer.py`: regenerate the embedded source payloads and BAT after edits.
- `bridge/README.md`: bridge design and diagnostic instructions.
- `archive/MotorTown_EngineSim_Bridge_Prototype_v0.1.zip`: earlier bridge source package, if included.

## Credits and license

- [Engine Simulator](https://github.com/ange-yaghi/engine-sim) by Ange Yaghi and contributors: MIT license (its original copyright notice must be retained).
- [MotorTownMods](https://github.com/drpsyko101/MotorTownMods): UE4SS integration reference.

This repository contains no redistributed Motor Town game files. Engine Simulator and other dependencies are obtained from their respective upstream sources during installation.
