# Motor Town -> Engine Simulator live audio bridge (experimental v0.1)

**Status: source-level proof of concept, not game-tested or a ready-to-install audio mod.**
The bridge implements a UE4SS game-side telemetry exporter and a patch for the original
MIT-licensed Engine Simulator desktop application's RPM/dyno and throttle controls.
It has not been validated against a running Motor Town installation or compiled
with Engine Simulator's Windows dependencies.

## What it does
- Reads the **local player's** Motor Town vehicle through UE4SS reflection.
- Attempts to discover current RPM, throttle and running-state properties.
- Sends short telemetry messages over a file in `%TEMP%` at up to 20 Hz.
- Patches the *original open-source* Engine Simulator to follow Motor Town RPM via
  Engine Simulator's dynamometer hold, generating genuine simulated exhaust audio.
- Leaves Motor Town's driving physics untouched.
- Fails silent on telemetry loss and does not alter save files.

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
4. Clone `https://github.com/ange-yaghi/engine-sim` **with submodules**:
   `git clone --recurse-submodules https://github.com/ange-yaghi/engine-sim.git`
5. Run `python patch_engine_sim.py "C:\path\to\engine-sim"`.
6. Build Engine Simulator according to its original README on Windows (CMake,
   Visual Studio, SDL2, SDL2_image, Boost, Flex/Bison). Launch its built app.
7. Launch Motor Town, enter a vehicle, and inspect
   `%TEMP%\MotorTownEngineSim_telemetry.txt`.
   Expected format: `MTES1 2000.000 0.2500 1 1790000000`.
   Engine Simulator must be launched and its audio unmuted.
8. Mute Motor Town's stock engine sounds (if an appropriate game audio setting exists).

To uninstall: remove the UE4SS mod folder and restore Engine Simulator's backup
`engine_sim_application.cpp.before-mtes-...` from the source directory.

## Relevant sources
- Original Engine Simulator (MIT): https://github.com/ange-yaghi/engine-sim
- Motor Town UE4SS mod example: https://github.com/drpsyko101/MotorTownMods
- UE4SS game-thread timers: https://docs.ue4ss.com/dev/lua-api/global-functions/delayedactions.html
- Motor Town engine sound replacement proof: https://www.nexusmods.com/motortownbehindthewheel/mods/21

Engine Simulator credit: Ange Yaghi and contributors; original MIT LICENSE governs original simulator code.
This bridge contains no redistributed game files or Engine Simulator binaries.
