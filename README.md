# Motor Town + Engine Simulator Bridge

Experimental Windows mod project to synchronize [Engine Simulator](https://github.com/ange-yaghi/engine-sim) combustion audio with the player's vehicle in [Motor Town: Behind The Wheel](https://store.steampowered.com/app/1369670/Motor_Town_Behind_The_Wheel/).

**Status: experimental prototype.** The source-level patch and installer packaging have been checked, but successful Windows compilation, telemetry detection on current game builds, and live in-game audio have **not** been verified. Do not treat this as a finished playable mod.

## Installation

1. Download `Install-MotorTownEngineSim.bat` from this repository.
2. Double-click the BAT on Windows 11 and accept any required UAC prompt.
3. The installer locates Motor Town, installs build dependencies if needed, downloads and patches Engine Simulator, builds it, and installs the UE4SS bridge.
4. Motor Town may need to be closed while its files are updated. The installer will wait rather than force-close it.

**Known limitation:** No fully native spatial audio replacement yet; the simulator runs as a separate audio source. Motor Town's game telemetry field names are not confirmed for all versions; see `bridge/README.md`.

## Files

- `Install-MotorTownEngineSim.bat`: single-file embedded PowerShell installer (latest launcher).
- `Install-MotorTownEngineSim.ps1`: standalone installer source (for development).
- `bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua`: UE4SS telemetry producer.
- `bridge/patch_engine_sim.py`: source patcher for Engine Simulator.
- `bridge/tests/test_patch.py`: patching tests.
- `bridge/README.md`: bridge design and diagnostic instructions.
- `archive/MotorTown_EngineSim_Bridge_Prototype_v0.1.zip`: earlier bridge source package, if included.

## Credits and license

- [Engine Simulator](https://github.com/ange-yaghi/engine-sim) by Ange Yaghi and contributors: MIT license (its original copyright notice must be retained).
- [MotorTownMods](https://github.com/drpsyko101/MotorTownMods): UE4SS integration reference.

This repository contains no redistributed Motor Town game files. Engine Simulator and other dependencies are obtained from their respective upstream sources during installation.
