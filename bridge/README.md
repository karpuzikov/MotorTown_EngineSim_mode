# Motor Town -> Engine Simulator live audio bridge (experimental v0.2.15)

## Native telemetry bridge (development only)

The same in-game Lua exporter now writes a separate `MTES4` packet to
`%TEMP%\MotorTownEngineSim_native_telemetry.txt` every game tick (20 Hz). It
carries the actual reflected gear, vehicle identity and basic engine metadata
alongside RPM, throttle and ignition. It also includes an exact reflected
`EngineData` UObject full name when available, for future curated per-engine
`.mr` profile matching; unknown identities are not guessed. Unknown gear is `-99`, which the native
DLL rejects rather than pretending the transmission is in neutral. The native
UE4SS `on_update()` reader consumes this without an external application and
ignores stale files. Each Lua exporter load has its own session token, so
reloading the script can restart its packet sequence. The final field carries
`UMotorTownUserSettings.Values[Sound_EngineVolume].FloatValue` when the live
setting has a verified float type and a value between 0 and 1, including zero.
Unavailable, non-float and out-of-range values are `-1` (unknown), never an
assumed maximum or the master volume. The SDK confirms the field layout, but
the value and lookup still require a Windows in-game check. Native `MTES2` and
`MTES3` parsing remain supported, and the legacy `MTES1` file
remains compatible with v0.2.14 and v0.2.15.

This is a transitional in-process integration, not procedural audio playback
or stock engine-sound replacement.

The November 1 SDK-backed diagnostic probe reads
`EngineComponent.EngineSoundComponent.EngineAudioComponents` and
`EngineComponent.EngineSoundComponent.ExhaustAudioComponents` directly, showing
up to 16 component identities, assigned sounds and current volume multipliers
under `SDK engine audio targets:` in the discovery snapshot. This check is
independent of the general reflection budget and never modifies game audio.
The latest component list is also refreshed independently every five seconds
in `%TEMP%\MotorTownEngineSim_audio_targets.txt` and included in the read-only
diagnostic collector, so late-loaded engine/exhaust loops can be inspected
without repeating the expensive general reflection scan.

Version 0.2.15 also probes `EngineComponent.AudioComponent`,
`IntakeAudioComponent`, `JakeBrakeAudioComponent`, and
`AfterfireAudioComponents` when the nested `EngineSoundComponent` is not yet
available. It records engine ignition/RPM with each report and retains the
last running-engine snapshot instead of losing it on engine shutdown. These
fields are observed only; no component is muted or claimed by the native mod.

**Status: experimental, not game-tested or a verified audio replacement.**
The bridge implements a UE4SS game-side telemetry exporter and a patch for the original
MIT-licensed Engine Simulator desktop application's RPM/dyno and throttle controls.
Windows compilation was confirmed by the user's v0.2.6 installation log.
Runtime rendering, telemetry and audio synchronization remain unverified.

## Discovery diagnostics (v0.2.12)

The exporter now examines engine and gearbox objects ahead of unrelated seat and
physics objects. The bounded discovery report includes a dedicated list of
engine/gear/audio fields and candidate values, even beyond its first 300 general
inventory lines. It also logs live gear changes when a reflected integer field
is available. The MTES1 packet stays unchanged for compatibility.

This is diagnostic groundwork, **not** stock engine sound replacement or actual
gear control. The native in-process mod design and phased implementation plan
are in `docs/superpowers/`.

## Discovery diagnostics (v0.2.13)

The first v0.2.12 live report confirms nonzero vehicle RPM on the Atlas 4x2
semi and exposes `EngineComponent.EngineData.EngineProperty` plus the engine
`EnginesSound`, `EngineSoundComponent`, and `AudioComponent` objects. It also
confirms the previous depth-first scan exhausted the 2,000-member budget before
transmission state could be inspected (`gear=nil`). This revision:

- Explores peer engine/transmission components before nested sound assets.
- Prefers live EngineComponent throttle over player-input throttle (autopilot).
- Recognizes explicit `bIgnitionOn` and `IsIgnitionOn` engine state.
- Includes actual reflected object identities for relevant audio fields.
- Keeps the first lines of long discovery snapshots in the diagnostic collector.

These game fields are read-only; the diagnostic mod still does not mute stock
engine sounds or supply a compiled native audio replacement.

## Discovery diagnostics (v0.2.14)

The user's new Tuscan report confirms the exporter reads real gear changes (5, 4,
2 and 0) through `NetLC_TransmissionColdState.CurrentGear`. It also confirms
that `EngineComponent.GetThrottle()` was triggering a full 2,000-metadata scan
once per second. The revised scanner prioritizes nested engine specifications
and audio objects over unrelated vehicle horns and effects, records engine
component scans in the focused snapshot, and caches a verified engine throttle
mapping until the player changes vehicles or the mapping becomes invalid.

**Gear changes are observable in diagnostics but not transmitted to Engine
Simulator yet**; its current bridge still forces neutral. The native audio mod
and stock-engine replacement remain unfinished.

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
- Motor Town RPM/throttle paths have been observed on Atlas and Tuscan vehicles,
  but are not verified across all vehicle types. Auto-discovery may still choose
  the wrong property or none. Inspect
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
