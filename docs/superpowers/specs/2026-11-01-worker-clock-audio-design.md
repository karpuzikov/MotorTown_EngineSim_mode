# Native worker-clock engine audio design

## Goal

Motor Town's engine audio should remain continuous when Unreal/Lua telemetry
arrives late, while Engine Simulator remains the genuine PCM source and the
vehicle, RPM, throttle, engine volume, and stock-mute safety gate remain live.

## Evidence and constraints

- The existing native worker polls every 20 ms, but `NativeAudioPipeline`
  produces PCM only when Lua increments its telemetry sequence. A 150–186 ms
  delayed game frame therefore forces one expensive simulation/render burst.
- Genuine Windows stress tests intermittently miss hundreds of PCM samples
  even with a 16,384-frame synthesizer buffer, chunked DSP publication, and
  a safe tiny-tail rounding guard. Some bursts take longer than playback time.
- Keep Engine Simulator's authored physics frequency and unmodified game audio
  except the positively identified local player's engine/exhaust cue. Never
  synthesize from telemetry that is stale, paused, unignited, or unfocused.
- Preserve the current Windows build, installed UE4SS, and fail-open Lua mute
  acknowledgment. Do not publish a playable release without a game test.

## Approaches

1. Increase producer wait limits or PCM FIFO capacity. Small change, but
   misses actual playback deadlines and adds throttle-response latency.
2. **Selected:** clock PCM generation from the already-running 20 ms native
   worker using the latest fresh telemetry. This avoids large 150–186 ms
   per-frame simulation bursts, keeps engine synthesis authentic, and allows
   the Lua sequence to remain a freshness/identity signal only.
3. Replace the Engine Simulator asynchronous producer with a new streaming
   renderer. Much larger upstream patch and more lifetime/concurrency risk.

## Behavior

- A native worker PCM tick is at most once every 15–20 ms. On each tick,
  advance Engine Simulator by the elapsed wall-clock duration and queue the
  corresponding 44.1-kHz PCM. Do so even if the last valid Lua sequence did
  not change, provided its age remains within 250 ms.
- New telemetry instantly updates RPM, throttle, gear, and engine volume at
  the next worker tick. A session, vehicle, asset, emitter, ignition, volume,
  or foreground mismatch still stops native PCM and restores stock sound.
- First load still primes the simulator without stock mute. The Lua mute
  acknowledgment remains required before any XAudio2 playback.
- Preserve deterministic packet-driven mode for existing tests and provide
  an explicit worker-clock mode for the actual UE4SS DLL; add direct tests
  for duplicate-packet continuous audio and stopping on stale/focus-loss.

## Non-goals

No new engine assets, no global stock-audio suppression, no additional
Windows application, no UE4SS reinstall, and no user-facing release yet.
