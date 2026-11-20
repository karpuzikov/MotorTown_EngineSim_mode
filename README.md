# Motor Town + Engine Simulator Bridge

Experimental Windows mod project to synchronize combustion audio from [karpuzikov/engine-sim](https://github.com/karpuzikov/engine-sim) with the player's vehicle in [Motor Town: Behind The Wheel](https://store.steampowered.com/app/1369670/Motor_Town_Behind_The_Wheel/).

**Version: experimental v0.2.14 (legacy bridge); native mod in development.** The latest Windows report confirms live gear changes on the Tuscan (5, 4, 2, neutral) and discovers engine RPM, throttle and ignition, but the separate Engine Simulator still cannot follow gears: the MTES1 packet has no gear field. The native branch now **passes Windows headless PCM and three-engine switching tests** (boxer-four, V8, V10), but has **not passed in-game validation**. Unreal audio injection, stock-sound replacement, live game-gear and engine-volume integration, and automatic engine profiles remain **unimplemented**. This is **not** the finished downloadable native mod.

## Native mod: engines and settings

The native mod plays the petrol engines of **EngineVoice**, a stand-alone program built on the real Engine Simulator where
every Motor Town engine (142, one per real car and engine option) is checked to start, idle and rev, and the sound is picked
by ear:

- every engine runs as in Engine Simulator itself, with its road-car muffler;
- diesel engines are simulated exactly as petrol engines of the same build (their real displacement, cylinders, bore,
  stroke, compression and redline); only the GX160 kart keeps an exhaust response fitted to a real recording.

`settings.ini` in the mod folder (`ue4ss\Mods\MotorTownEngineSim`):

| Setting | Values | Effect |
|---|---|---|
| `volume` | `1.0` (default), `0.5` = half | Loudness relative to Motor Town's own engine sound |
| `muffler` | `standard` (default), `brighter`, `brightest` | How much treble the road-car muffler removes: Engine Simulator's own muffler recording, or the same with +8 dB / +14 dB above 2.5 kHz. Only the muffler file changes (made once by `pipeline/make_muffler_treble_variants.py`); the engine, the loudness and the CPU cost stay the same. Diesels, the MC-9 and the kart keep their own exhaust. All muffler files are whistle-free (checked by `pipeline/tests/test_no_whistles.py`). |

An unknown value keeps the default and is reported in `UE4SS.log` (`[MTES] settings.ini: ...`).

## Installation

1. Download `Install-MotorTownEngineSim.bat` from this repository.
2. Double-click the BAT on Windows 11 and accept any required UAC prompt.
3. The installer locates Motor Town, installs build dependencies if needed, downloads and patches Engine Simulator, builds it, and installs the UE4SS bridge.
4. Motor Town may need to be closed while its files are updated. The installer will wait rather than force-close it.

Fresh installs clone `karpuzikov/engine-sim`. Existing installs switch their `origin` remote to that fork while preserving the checkout, submodules, local patches, dependencies and build files. Third-party submodules continue to use their own upstream repositories.

The installer repairs Delta Studio's DirectX link configuration in place and rebuilds with retail libraries for Release. It does not require the DirectX debug runtime. MSVC `dumpbin` checks the resulting executable before launch and records its DLL dependencies in the installation log.

If startup fails or remains blank, the installer prints the last startup stage and any engine-script errors into its installation log. The live runtime log is `source/engine-sim/build-mtes/MotorTownEngineSim_runtime.log` under the project directory. It records graphics, asset, engine-script and audio initialization separately. Startup readiness does not verify rendering, sound or game telemetry.

**Known limitation:** No fully native spatial audio replacement yet; the simulator runs as a separate audio source. Motor Town's live fields still need verification. See `bridge/README.md` and the native mod design under `docs/superpowers/`.

## If the game does not affect Engine Simulator

With Motor Town running and the player seated in a vehicle, download and run `Collect-MotorTownEngineSim-Logs.bat`. Manual driving and autopilot are both valid for collecting diagnostics; no WASD input is required. It observes the telemetry file for three seconds and creates one `Connection_*.txt` report in the project's `logs` folder, then selects it in Explorer. The report includes UE4SS loading information, exporter diagnostics, packet freshness and values, and simulator startup logs. It does not reinstall anything or change game files/settings. An initialized simulator or a fresh packet does not prove synchronized audio or native sound replacement.

## Files

- `Install-MotorTownEngineSim.bat`: single-file embedded PowerShell installer (latest launcher).
- `Install-MotorTownEngineSim.ps1`: standalone installer source (for development).
- `Collect-MotorTownEngineSim-Logs.bat`: single-file, read-only game connection diagnostic collector.
- `bridge/UE4SS/Mods/MotorTownEngineSim/Scripts/main.lua`: UE4SS telemetry producer.
- `bridge/patch_engine_sim.py`: source patcher for Engine Simulator.
- `bridge/tests/test_patch.py`: patching tests.
- `bridge/tests/test_runtime_patch.py`: executable startup failure/success and safe patching checks.
- `bridge/package_installer.py`: regenerate the embedded source payloads and BAT after edits.
- `bridge/README.md`: bridge design and diagnostic instructions.
- `version-history/MotorTown_EngineSim_Bridge_Prototype_v0.1.zip`: earlier bridge source package, if included.

## Credits and license

- [Engine Simulator](https://github.com/ange-yaghi/engine-sim) by Ange Yaghi and contributors: MIT license (its original copyright notice must be retained).
- [MotorTownMods](https://github.com/drpsyko101/MotorTownMods): UE4SS integration reference.

This repository contains no redistributed Motor Town game files. Engine Simulator and other dependencies are obtained from their respective upstream sources during installation.
