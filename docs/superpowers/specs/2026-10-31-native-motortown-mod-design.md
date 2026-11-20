# Native Motor Town engine-audio mod design

## User outcome

An ordinary downloadable mod: install once, start Motor Town, hear Engine Simulator
audio instead of the stock engine audio. There must be no simulator window, manual
launch, standalone audio process, or separate vehicle selector. Motor Town's
engine-volume control must govern the replacement. The selected engine and gear
must follow the player's actual vehicle. Other game sounds stay intact.

## Approaches and decision

- **Desktop companion**: already implemented in v0.2.11; cannot satisfy in-game
  sound replacement, volume routing, or the no-separate-process requirement.
- **Replace packaged game audio assets**: cannot synthesize configurable combustion
  in real time; fragile across game updates and engine variants.
- **Native UE4SS C++ mod**: load an audio-only simulation component into Motor Town,
  route generated PCM through Unreal's audio system, and disable only the stock
  local-vehicle engine emitters. Chosen as the only approach meeting the outcome.

## Architecture

1. UE4SS loads a C++ mod when Motor Town starts. There is no Engine Simulator app.
2. Read the controlled vehicle's RPM, throttle, gear, ignition, engine identity and
   audio components directly from game objects. No keyboard or guessed movement.
3. Map game vehicle/engine metadata to a matching Engine Simulator engine script.
   Engine Simulator supports many physical layouts but does not know which script
   corresponds to a given vehicle; exact matching requires model data or profiles.
4. Embed the headless simulator/audio engine and queue its PCM to a game-attached
   Unreal audio component, classified with the game's engine volume category.
5. Mute only original local-player engine emitters once replacement audio works;
   on initialization failure restore the stock audio and do not play a second source.
6. Installer distributes prebuilt, compatible DLLs, profile assets and UE4SS setup
   as needed. Installation is reversible and preserves unrelated UE4SS mods.

## Safety and constraints

- Initial target: Windows 11, Motor Town 0.7.19, single-player. Other game versions
  and multiplayer need explicit validation.
- No redistribution of proprietary Motor Town game assets.
- Native API and in-game audio hooks must be verified against a running game before
  a release is described as working. Development scaffolding alone is not a release.
- No silent stock-audio muting without a functioning replacement.
- Keep the existing v0.2.11 companion installation available until native parity.

## Work sequence

1. Fix/refine live reflection diagnostics for engine, gear, audio and vehicle fields.
2. Build a native UE4SS module and test that it loads with no desktop process.
3. Extract/test the headless combustion audio core and inject its PCM into Unreal.
4. Integrate game volume routing, original-emitter replacement, and sound profiles.
5. Validate across multiple vehicles and package a one-click public release.

## Acceptance

One install; Motor Town startup launches mod; only one appropriate engine soundtrack;
game Engine Volume applies; gear and RPM match the vehicle including autopilot;
engine switches with the vehicle; non-engine sounds remain; no companion UI/process;
uninstall restores original sound; user verification log confirms real behavior.
