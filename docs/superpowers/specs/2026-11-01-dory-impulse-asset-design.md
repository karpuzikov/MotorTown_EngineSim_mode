# Dory V8 impulse-response packaging

## Intent

The in-game Dory has the exact installed Ford 302 profile and original V8
SoundCue, but the native mod never requests the verified stock-audio mute.
The selected Engine Simulator GM LS model references `smooth/smooth_39.wav`
through `ir_lib.default_0`; the development package currently omits all
impulse-response WAV files. The native backend requires readable impulse PCM
before starting its synthesizer.

## Options

- Bundle the single known WAV and resolve it beside the packaged `.mr` script
  under `assets/sound-library/` (chosen: small, deterministic, no game CWD
  dependency).
- Bundle the complete upstream sound library (unnecessary size for one
  curated profile).
- Change the game process's current working directory (unsafe global mutation).

## Requirements

- Preserve all stock sounds on failure; no broader muting or guessed profile.
- Stage the pinned `smooth_39.wav` with the bundled model.
- Resolve relative impulse names from the profile's `assets/` directory,
  regardless of the game process's current working directory.
- Verify actual CMake stage output and the resolver using independent tests.
- Keep the PR development-only until audible in-game testing passes.
