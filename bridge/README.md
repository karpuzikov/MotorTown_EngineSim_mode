# Motor Town -> Engine Simulator live audio bridge (experimental v0.3.0)

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

## Direct engine-state fields (v0.3.0)

Motor Town stores the live engine state the game itself replicates for engine sound
on every `AMTVehicle` (published dumps: MotorTownMods `docs/Webhooks.md`,
`docs/LuaHttpServer/VehicleManagement.md`):

| Signal   | Path                                   | Type          |
|----------|----------------------------------------|---------------|
| RPM      | `NetLC_EngineHotState.CurrentRPM`      | float, RPM    |
| Ignition | `NetLC_EngineHotState.bIgnitionOn`     | bool          |
| Throttle | `Throttle`                             | float, 0..1   |

The exporter reads these paths directly every 50 ms. No reflection runs on the
hot path, and no getters are called.

Why v0.2.9-v0.2.11 never found RPM: RPM sits inside the struct
`NetLC_EngineHotState`. A struct *value* in UE4SS (`LuaUScriptStruct`) has only
`GetBaseAddress/GetStructAddress/IsValid/GetProperty/type`; unknown members read
as nil, so `struct:ForEachProperty(...)` raised "attempt to call a nil value".
v0.2.11's `false` -> `nil` callback fix was also correct (UE4SS `LuaUStruct.cpp`
consumes a returned `false` twice), but the struct failure remained.

If a game update renames a field, the exporter falls back to a bounded scan of
the vehicle's numeric/bool fields. Struct layouts come from
`StructProperty:GetStruct()`. The scan writes every field it read to
`%TEMP%\MotorTownEngineSim_discovery.txt`. Exact paths can still be set in
`RPM_PATH`, `THROTTLE_PATH` and `IGNITION_PATH` at the top of `main.lua`.

Other changes, based on lessons from other Motor Town UE4SS mods:
- Sampling starts 30 s after the mod loads. Polling during boot crashed the game for MTSpawner.
- The local controller is found with `FindAllOf("MotorTownPlayerController")` +
  `IsLocalController()`, and `MTVehicle` via `StaticFindObject` + `IsA`.
- A player seated in a vehicle without possessing it uses `LastVehicle`.
- If `LoopInGameThreadWithDelay` is unavailable, sampling falls back to
  `LoopAsync` + `ExecuteInGameThread`.

Simulator side (`MTES_BRIDGE_V2`): a missing or torn packet (mid-write, or the file held by
antivirus) reuses the last good packet for up to 15 frames, about 0.25 s, before muting.
Before, one bad read cut ignition and audio for a frame. RPM eases toward each 20 Hz
sample instead of stepping. The installer upgrades v0.2.10/v0.2.11 sources in place,
with a backup.

Tests model the UE4SS boundary as it actually behaves: struct values without
`ForEachProperty`, and `false` from an iterator callback breaking iteration. Every
exporter scenario also runs through the native UE4SS iterator stack operations.

## UE4SS iteration compatibility (v0.2.11)

The latest game log identifies `ForEachProperty` failing with "attempt to call a
nil value" after one property. The installed UE4SS f885e8d2 implementation consumes
a callback's boolean `false` in `Lua::get_bool`, then removes it again in the
iterator's continuation branch. This loses the original callback on the Lua stack.
The exporter now continues with an implicit nil return and stops only with `true`,
including property, function and function-parameter enumeration.

The regression runs the exporter against the same native Lua5.4 stack operations:
the old callbacks reproduce the failure, while the new callbacks enumerate all
members and retain the discovery budget. Unreal objects are still test doubles;
the actual game's engine field names and sound synchronization remain unverified.

## Simulator control (v0.2.10)

The previous native bridge only shut down after it had received its first valid
telemetry packet. Before that, Engine Simulator's standalone keyboard controls
remained active. The bridge now replaces that input function: ignition, throttle,
starter, dyno and audio volume are controlled exclusively by fresh telemetry.
Missing, malformed, stale or ignition-off packets keep audio muted from startup.
The existing information panel shows whether it is waiting, receiving running-engine
data, or receiving zero RPM / an engine-off state.

The companion starts in a 960x540 window and overrides script-requested fullscreen.
Its fullscreen, reload and exit shortcuts require focus, so Motor Town keystrokes
do not control the companion in the background. The installer recognizes the old
native patch and upgrades it with a backup, preserving the source checkout.

Native boundary tests reproduce startup without telemetry, live values, disconnect,
invalid/stale packets and keyboard interference. Windows rendering, actual game
property discovery and end-to-end sound synchronization remain unverified.

## Telemetry discovery (v0.2.9)

The supplied connection report confirms UE4SS and the exporter load and recognize
the player's Dory Wrecker. The failing boundary is discovery: RPM, throttle and
ignition mappings were all `nil`, so the exporter continuously sent zero values.
The previous scan only followed selected UObject components for one level and did
not inspect getter functions. It also used a struct's metaclass instead of its data
layout and silently hid reflection failures.

Discovery now follows simulation/physics/state components to a bounded depth, reads
UScriptStruct members through their own UStruct interface, and considers reflected
Const/BlueprintPure getter functions with a return value and no input/out parameters.
It prefers actual engine throttle over driver input, retries missing mappings, and
preserves explicit ignition-off states. Unknown throttle defaults to zero rather
than inventing a 30% input; ambiguous engine-speed units are not treated as RPM.
The latest scan records a bounded member inventory and any reflection failure in
`%TEMP%\MotorTownEngineSim_discovery.txt`; the connection report includes this
snapshot even after retry messages have filled the history log.
No game properties or driving-physics settings are written.

The Lua tests execute the actual exporter, substituting the Unreal object boundary.
They verify nested structs, read-only getters, changing RPM/throttle while driver
input is zero, late component availability, and ignition-off behavior. These tests
do not verify the live game's field names, sound synchronization, or stock muting.

## Limitations
- The field paths come from published dumps of current Motor Town builds and
  have not yet been checked by a drive test with this bridge. Whether `Throttle` follows
  autopilot is unverified. `%TEMP%\MotorTownEngineSim_discovery.txt` shows the
  values read for the current vehicle.
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
