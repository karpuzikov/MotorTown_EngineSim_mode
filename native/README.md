# Native Motor Town EngineSim mod - source foundation

**Not a playable release.** This source exports the native UE4SS module entry
points, a tested read-only game-telemetry receiver, a fail-open PCM controller,
and an initial adapter that loads the genuine Engine Simulator engine scripts
and drives its synthesizer.

The development DLL writes normal-level `[MTES]` messages to `UE4SS.log` when
Unreal initialization completes, the first native update callback runs, valid
native telemetry arrives or changes gear/Engine Volume, or the feed goes stale.
The telemetry line reports actual RPM, throttle, gear and engine-volume gain;
`-1` indicates an unavailable/unknown engine-volume setting. Repeated frames
do not generate repeated messages. These diagnostics **do not** activate
replacement audio or mute any stock game sound, and successful portable tests
are not proof that the user's current Windows DLL has been rebuilt or tested.

The controller follows RPM/throttle/gear and clears data on telemetry or render
failure. Only complete non-silent source buffers authorize replacing stock audio;
partial buffers are discarded. Its PCM renderer accepts an Engine Volume gain
(including zero without restoring unwanted stock engine sound). The UE4SS Lua
exporter now reads the SDK `UMotorTownUserSettings.Values` entry for
`Sound_EngineVolume`, sending a new MTES4 gain field between 0 and 1 or `-1`
when absent/invalid. The native reader stores a validated optional gain and
`NativeAudioPipeline::process(sample, now)` uses it directly, falling back to
stock audio if unknown. **This setting lookup is not yet verified in-game;
the live DLL still does not play PCM or replace stock audio.**
The portable `GameAudioOutput` handoff now additionally tracks ownership of
one identified stock-engine emitter and one procedural PCM sink. It queues
validated PCM for the **matching vehicle** before muting its stock emitter;
it stops the sink and restores the emitter on stale telemetry, buffer underrun,
vehicle change, queue/start failure or loss of emitter identity. Tests verify
the mute/start and stop/restore operation order. No horn, tire, transmission
or ambient emitter is ever targeted by this contract. The real Unreal adapter
still has to implement its `StockEngineEmitter`/`ProceduralAudioSink` interfaces
and discover an actual stock engine emitter before any muting can occur.
The user's November 1 Motor Town SDK dump identifies stock engine/exhaust
loops in `MTEngineComponent.EngineSoundComponent.EngineAudioComponents` and
`MTEngineComponent.EngineSoundComponent.ExhaustAudioComponents`. The tested
`MotorTownStockEngineEmitters` treats these as one reversible group: it preserves
each original gain, rolls back partial mute failures, and reasserts muting if
the game overwrites a multiplier between PCM blocks. The read-only Lua probe
now reports these exact live arrays. **Neither a live UE4SS endpoint adapter
nor an Unreal PCM sink has been implemented yet.**
If a game component cannot be restored immediately, the portable audio output
stops PCM playback and retains its original gain snapshot for retries on later
updates; it never starts a different vehicle while restoration is pending.
The real adapter still must prove continuous stock-emitter suppression against
Motor Town's sound-update frequency before enabling muting in-game.
The `NativeAudioPipeline` now joins the native telemetry parser, engine synthesizer and
sound-ownership controller in one tested path. Each 50-ms telemetry sequence
advances synthesis once (rather than once per UE4SS frame), yielding nominal
2205-frame 44.1-kHz PCM blocks. It stops and restores stock audio if vehicle
metadata cannot resolve a real `.mr` profile, the stock engine emitter is
unidentified, the volume is invalid, ignition is off or telemetry expires.
On vehicle switches it restores the old emitter before compiling the new
engine. The pipeline exposes `VehicleProfileLookup` and `StockEmitterLookup`
interfaces for adapters; **neither interface has a Motor Town implementation
yet, and the UE4SS `on_update()` callback still only logs telemetry.** This
portable integration test is not evidence of sound playback inside the game.
Newly loaded engines remain on stock sound for at least one 50-ms packet so
their asynchronous synthesizer can warm up. A temporary PCM underrun restores
stock audio but preserves the loaded engine to retry on the next new packet,
avoiding a compile/underrun/reload loop. Duplicated or replayed packets cannot
generate extra audio blocks; volume and emitter validity are checked on every
callback. Missing data does not reset the per-session sequence high-water mark.
The caller must pass `GameTelemetryReader::current(now)` (or `nullopt` after
expiry), and the pipeline also expires unchanged samples after 250 ms.
The experimental Lua exporter now writes `MTES4` telemetry (vehicle
identity, live gear, RPM, throttle, ignition, engine type, max RPM and the
full reflected `EngineData` UObject identity and read-only engine volume) to a
separate temp file. The native DLL polls that file in `on_update()` in the
same game process. It rejects unknown gears, malformed packets and data older
than 250 ms from the producer's write, tolerates Lua exporter reloads via a
new session token, and logs observed gear transitions to UE4SS. The reader
continues accepting `MTES2` and `MTES3` for compatibility, but those older packets
lack a validated engine volume, and MTES2 also lacks the exact engine asset
identity needed for automatic profile selection. The original `MTES1`
companion packet is unchanged. This file handoff is temporary: direct native
Motor Town reflection is still needed for the final mod. No actual Unreal
audio routing is connected yet.

`ExactVehicleProfiles` adds a fail-closed vehicle-to-engine catalog. It loads
`engine_profiles.tsv` beside the eventual mod assets, with one exact
`EngineData` full name and one relative Engine Simulator `.mr` file per row,
separated by a tab. All referenced scripts must exist inside that mod folder;
duplicates, broken mappings, absolute paths and symlink escapes invalidate the
catalog. A different game engine asset is **never** mapped from a similar RPM
limit or an engine-type number. This is an adapter for installer-curated
profiles, **not a populated Motor Town vehicle database**; without verified
game engine identifiers and packaged scripts, the catalog selects nothing and
the original engine sound remains in control. The user will not need to edit
the catalog when the eventual native release is complete.

The actual Engine Simulator backend **passed Windows builds and real-PCM smoke
tests** using boxer-four, V8, and V10 engine profiles, including in-process
engine switching. It is not yet connected to Motor Town's Unreal audio
output, stock muting, game engine-volume control, or vehicle profile selector.
Do not install it as a replacement for the current experimental companion.

The planned mod is a C++ DLL loaded inside Motor Town by UE4SS. It needs no
Engine Simulator desktop process or window. Its development build depends on a
binary-compatible UE4SS source/SDK checkout. The source includes a tested
`native/ue4ss-parent` CMake entry point, which adds a supplied UE4SS checkout
and the native mod, validates both targets, and stages a DLL without touching
the game. A matching checkout with initialized Unreal submodules requires
Epic-linked GitHub source access under the official UE4SS C++ build guide.

On a Windows developer machine with Visual Studio 2022 and a compatible
`RE-UE4SS` checkout (including its required submodules):

```powershell
python native/ue4ss-parent/verify_checkout.py "C:\path\to\RE-UE4SS"
cmake -S native/ue4ss-parent -B native/build-ue4ss -G "Visual Studio 17 2022" -DMTES_UE4SS_SOURCE="C:\path\to\RE-UE4SS"
cmake --build native/build-ue4ss --config Game__Shipping__Win64 --target mtes-stage-dev
```

### Building the actual UE4SS DLL in GitHub Actions

The separate **Native UE4SS DLL (Windows development build)** workflow now
compiles the full `RE-UE4SS` source and this native DLL on Windows, using
revision `f885e8d2d4dd25258082538f1a9fd56a1c3b1bf1` from the observed
Motor Town UE4SS installation. It runs on pushes to the native development
branch and can also be started manually once available in GitHub Actions.
Unlike the portable CMake fixture test, the real build requires UE4SS's
private `deps/first/Unreal` (`Re-UE4SS/UEPseudo`) submodule.

For a repository maintainer to enable the real build:

1. Link Epic Games and GitHub accounts under the official UE4SS source access
   procedure, and verify that your GitHub account can read the private
   `Re-UE4SS/UEPseudo` repository.
2. In this repository, open **Settings → Secrets and variables → Actions**.
   Add a repository secret named `UEPSEUDO_PAT` containing a GitHub access
   token with read permission to that private source repository. Never put
   the token in source, issues, logs, or chat. Grant no write permission.
3. Rerun the Windows workflow (or push an update to the development branch).
   The first step fails explicitly if the secret is absent. The checkout
   preflight also refuses an uninitialized submodule or a mismatched UE4SS
   source revision.

A successful run will upload a `MotorTownEngineSim-UE4SS-dev-unverified`
artifact containing `main.dll`. This is **only a compiled DLL build check**:
no installer, actual Unreal PCM playback, stock engine muting or in-game load
verification is supplied by this workflow. It deliberately cannot publish
a GitHub release.

### One-command local build (no GitHub Actions secret)

If a Windows user's GitHub account can open the private
`https://github.com/Re-UE4SS/UEPseudo` repository, they can try a local build
instead. This can use Git Credential Manager's normal browser login and does
not require adding a personal token to GitHub Actions. In PowerShell 7:

```powershell
$script = Join-Path $env:TEMP 'MotorTownEngineSim-build-local.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/karpuzikov/MotorTown_EngineSim_mode/feat/native-engine-audio/native/ue4ss-parent/build-local.ps1' -OutFile $script
pwsh -NoProfile -ExecutionPolicy Bypass -File $script
```

The downloaded script is reviewable in this repository. It detects the
existing Visual Studio/CMake tools, clones the pinned matching UE4SS revision,
downloads private submodules with the user's own Git credentials, prepares
local vcpkg and checksummed Flex/Bison dependencies, builds the real DLL, and
prints the staged DLL and transcript log paths. It uses a separate
`Documents\Karpuzikov Tools\MotorTown EngineSim Mod` directory rather than
changing the user's UE4SS `MyMods` tutorial or Motor Town installation. The
first download/build can take substantial time and disk space; Git may ask the
user to authenticate through their browser. Add `-PlanOnly` to preview paths
without downloading/building anything. The Windows Actions workflow checks
the helper's syntax and plan-only mode, but **the actual private-source build still needs a
live Windows run** to confirm it succeeds. Its output remains development-only.

The output is staged as
`native/build-ue4ss/dev-stage/ue4ss/Mods/MotorTownEngineSim/dlls/main.dll`.
This is a **development artifact only**, not an installer or verified working
mod. The parent build's portable tests compile tiny stand-in UE4SS targets to
verify CMake wiring and staging; they do not compile or load the real SDK.

When complete and game-verified, the installer will place a compiled DLL under
`ue4ss/Mods/MotorTownEngineSim/dlls/main.dll` and enable the mod. That native
installation path is **not** active yet. Never distribute this incomplete
module as if it were an engine-audio replacement.

## Headless engine integration research

The actual Engine Simulator code already separates its `engine-sim` static
simulation/audio library from the graphical `engine-sim-app` executable.
`Simulator::readAudioOutput()` returns 44.1 kHz mono PCM16 samples, which the
Unreal procedural source can consume; Delta Studio's graphics window and
desktop audio device are unnecessary at runtime. The `engine-sim-script-interpreter`
library is still needed to compile physical engine definitions (`.mr`).

The `impulse_wav` loader handles original 16-bit and 24-bit mono 44.1 kHz
impulse-response assets without opening an audio device, rejecting malformed
or incompatible files. The native tests run its parser against real assets
when `MTES_ENGINE_SIM_SOURCE` points to an engine-sim checkout.

The CMake project fetches the pinned Engine Simulator fork into its **build
directory**, then patches known upstream cleanup defects so repeated vehicle
switches can release physics and audio allocations, repairs the upstream
more-than-eight-cylinder write, and synchronizes PCM ring-buffer access. It also resolves `.mr`
imports relative to the script, and avoids writing `error_log.log` into the
game directory (opt in with `MTES_SCRIPT_LOG_PATH`). The desktop application
target is not built or launched.

For a Windows smoke test without UE4SS or Motor Town installed:

```powershell
cmake -S native -B native/build-windows -DMTES_HEADLESS_SMOKE=ON
cmake --build native/build-windows --config Release --target mtes-headless-smoke
native/build-windows/Release/mtes-headless-smoke.exe "<absolute path to engine-sim assets/main.mr>" "<optional next vehicle profile.mr>"
```

This requires Engine Simulator's original Windows build dependencies (including
Visual Studio, SDL2, Boost, Flex/Bison). The GitHub Windows workflow runs the
same smoke automatically on three distinct physical engine models (Subaru boxer
four, GM LS V8, and Lexus LFA V10), switching models in the same process; it
does **not** prove the
UE4SS DLL has loaded in-game.

Next integration boundaries are the Engine Simulator/UE4SS Windows SDK build,
the in-game USoundWaveProcedural output, matching real vehicle configurations,
and fail-safe muting restricted to the original engine emitters. **Do not enable
stock muting until real PCM is audible inside the game.**

Official documentation:
- https://docs.ue4ss.com/guides/creating-a-c%2B%2B-mod.html
- https://docs.ue4ss.com/guides/installing-a-c%2B%2B-mod.html
