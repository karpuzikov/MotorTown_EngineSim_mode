# Native Motor Town EngineSim mod - source foundation

**Not a playable release.** This source currently exports the native UE4SS
module entry points; it does not play sound, mute stock sounds, or select engines.
Do not install it as a replacement for the current experimental companion.

The planned mod is a C++ DLL loaded inside Motor Town by UE4SS. It needs no
Engine Simulator desktop process or window. Its development build depends on a
binary-compatible UE4SS source/SDK checkout. Per the official UE4SS C++ guide,
create a parent CMake project with `add_subdirectory(RE-UE4SS)` followed by
`add_subdirectory(MotorTown_EngineSim_mode/native)`, and build on Windows.

When complete and game-verified, the installer will place a compiled DLL under
`ue4ss/Mods/MotorTownEngineSim/dlls/main.dll` and enable the mod. That native
installation path is **not** active yet. Never distribute this empty module as
if it were an engine-audio replacement.

Official documentation:
- https://docs.ue4ss.com/guides/creating-a-c%2B%2B-mod.html
- https://docs.ue4ss.com/guides/installing-a-c%2B%2B-mod.html
