# Motor Town -> Engine Simulator live audio bridge (experimental v0.2.8)

**Status: experimental, not game-tested or a verified audio replacement.**
The bridge implements a UE4SS game-side telemetry exporter and a patch for the original
MIT-licensed Engine Simulator desktop application's RPM/dyno and throttle controls.
Windows compilation was confirmed by the user's v0.2.6 installation log.
Runtime rendering, telemetry and audio synchronization remain unverified.

## What it does
- Reads the **local player's** Motor Town vehicle through UE4SS reflection.
- Attempts to discover current RPM, throttle and running-state properties.
- Sends short telemetry messages over a file in `%TEMP%` at up to 20 Hz.
- Patches the *original open-source* Engine Simulator to follow Motor Town RPM via
  Engine Simulator's dynamometer hold, generating genuine simulated exhaust audio.
- Leaves Motor Town's driving physics untouched.
- Fails silent on telemetry loss and does not alter save files.

Synchronization must use the vehicle's live engine state, including RPM and engine
throttle under autopilot. Keyboard or WASD state is not a substitute for telemetry.
Autopilot integration remains unverified until game-side values are captured.

## Limitations
- Motor Town RPM/throttle property paths are **not yet verified** on game 0.7.19.
  Auto-discovery may choose the wrong property or none. Inspect
  `%TEMP%\MotorTownEngineSim_diagnostics.txt` and set `RPM_PATH`, `THROTTLE_PATH`,
  `IGNITION_PATH` in `main.lua` if necessary.
- Only the player's vehicle, not AI traffic, has Engine Simulator sound.
- The sound plays outside Motor Town, therefore no in-game 3D positioning,
  doppler, interior muffling or occlusion. In-game engine audio must be muted
  separately to prevent double playback.
- Does not automatically select an appropriate Engine Simulator script for each vehicle.
- Engine Simulator's dynamics may lag rapid RPM changes. Needs in-game tuning.
- Intended for single-player. Multiplayer compatibility not assessed.

## Installation (Windows, for developers)

1. Install **experimental UE4SS compatible with Motor Town** next to
   `MotorTown-Win64-Shipping.exe`. See the linked community mods.
2. Copy `UE4SS/Mods/MotorTownEngineSim` into
   `Motor Town/MotorTown/Binaries/Win64/ue4ss/Mods`.
3. Ensure the mod is active in UE4SS (place `MotorTownEngineSim : 1` in
   `ue4ss/Mods/mods.txt` if your UE4SS build uses that file).
4. Clone the user's fork **with submodules**:
   `git clone --recurse-submodules https://github.com/karpuzikov/engine-sim.git`
5. Run `python patch_engine_sim.py "C:\path\to\engine-sim"`.
6. Build Engine Simulator according to its README on Windows (CMake,
   Visual Studio, SDL2, SDL2_image, Boost, Flex/Bison). Launch with the build
   directory (`build-mtes`, not `build-mtes/Release`) as its working directory.
7. Launch Motor Town, enter a vehicle, and inspect
   `%TEMP%\MotorTownEngineSim_telemetry.txt`.
   Expected format: `MTES1 2000.000 0.2500 1 1790000000`.
   Engine Simulator must be launched and its audio unmuted.
8. Mute Motor Town's stock engine sounds (if an appropriate game audio setting exists).

To uninstall: remove the UE4SS mod folder and restore Engine Simulator's backup
`engine_sim_application.cpp.before-mtes-...` from the source directory.
For the startup diagnostics patch, restore the `*.before-mtes-runtime-*` source
backups as well, then rebuild.

## Startup diagnostics (v0.2.7)

The installer checks startup for up to 30 seconds. `MotorTownEngineSim_runtime.log`
in `source/engine-sim/build-mtes` records the last completed initialization stage.
`error_log.log` in the same directory contains engine-script compilation errors.
Both reports are copied to the project's `logs` folder and printed into the
installation transcript. A process still initializing after the check is reported
as pending; it is not described as working. A readiness marker means initialization
returned, not that rendering or audible synchronization has been tested.

## DirectX Release linkage (v0.2.8)

The pinned Delta Studio `CMakeLists.txt` originally linked both retail and debug
D3DX libraries for every build configuration. In particular, `d3dx10d.lib` preceded
`d3dx10.lib`, causing the reported `d3dx10d_43.dll` dependency despite a Release build.
The installer backs up this CMake file and adds `optimized`/`debug` qualifiers for
the D3DX9, D3DX10 and D3DX11 import libraries. Existing source, submodules and build
files are reused. No debug DLLs are downloaded or copied.

After rebuilding, `dumpbin /dependents` checks the executable. Any debug D3DX DLL
import stops installation before launch; the dependency list is recorded in the
installation log. `bridge/tests/test_directx_linkage.py` reproduces the original
link configuration and verifies repaired Release/Debug selections with real CMake.

Regenerate embedded payloads with `python bridge/package_installer.py` and run
`python -m unittest discover -s bridge/tests -v` after source changes.

## Relevant sources
- Simulator source used by the installer: https://github.com/karpuzikov/engine-sim
- Original Engine Simulator (MIT attribution): https://github.com/ange-yaghi/engine-sim
- Motor Town UE4SS mod example: https://github.com/drpsyko101/MotorTownMods
- UE4SS game-thread timers: https://docs.ue4ss.com/dev/lua-api/global-functions/delayedactions.html
- Motor Town engine sound replacement proof: https://www.nexusmods.com/motortownbehindthewheel/mods/21

Engine Simulator credit: Ange Yaghi and contributors; original MIT LICENSE governs original simulator code.
This bridge contains no redistributed game files or Engine Simulator binaries.
