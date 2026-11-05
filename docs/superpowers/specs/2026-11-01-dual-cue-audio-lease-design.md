# Dual-cue engine audio lease (development only)

The Dory Wrecker's running-game snapshot identifies two separate, verified stock sounds: `EngineComponent.AudioComponent` using `SC_V8Engine`, and `EngineComponent.IntakeAudioComponent` using `SC_Intake01`. Only the first is currently muted. The 0.3.4 diagnostic log also shows 450 rapid play/stop interruptions, all reported as missing/revoked stock-mute acknowledgments, but it does not show the first reason for revocation.

## Goal and constraints

- Replace both verified engine and intake sounds only when genuine native PCM is ready and both channels have been confirmed muted on the Unreal game thread.
- Capture each original `VolumeMultiplier` separately; invalidate the native ACK before restoring either channel. On any failure, restore *all* previously muted channels. Do not touch unrelated effects or vehicles.
- Preserve native fail-open safety: never play replacement PCM without an authenticated current ACK. Record meaningful reasons for ACK rejection and Lua restoration without treating a guessed timeout increase as a fix.
- Development PR #1 only. No playable release or merge before in-game testing.

## Approach

Extend the existing Lua lease to cover a small list of exactly verified channels, with one shared ACK for both. Keep the existing file protocol and native worker; add native rejection diagnostics and game-thread restoration reasons. This minimizes changed components. A generic Unreal audio scanner and a looser ACK grace period are rejected: the former could mute unrelated sounds and the latter could overlap unmuted stock audio.

## Acceptance evidence

Lua harness covers successful two-channel mute/restore, a failed second mute, a changed intake channel, and the four-tick watchdog; native tests distinguish rejection reasons after a live ACK. Windows CI and an in-game Dory drive remain separate required checks.
