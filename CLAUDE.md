# Working rules for this repository

Follow AGENTS.md (Ponytail, "lazy senior dev": https://github.com/dietrichgebert/ponytail)
and these design principles (https://gist.github.com/Arro/6e51a6398e59fa20432c982902c65437):

- **YAGNI:** don't build it until you need it.
- **DRY:** extract a pattern after the second duplication, not before.
- **Fail fast:** explicit errors over silent failures.
- **Simple first:** write the obvious solution; optimize only if needed.
- **Delete aggressively:** less code, fewer bugs.
- **Semantic naming:** verbose, self-documenting names for variables, parameters
  and interfaces, written for humans and LLMs (`waitUntilObjectIsSaved`, not `wait`).
- **App name in identifiers:** spell out `MotorTownEngineSim` / `motor_town_engine_sim`
  in code. The short `MTES` / `mtes_` form is only for identifiers read outside the
  codebase: %TEMP% file names, telemetry/lease packet tags, log prefixes, DLL exports.

Project rules (from the owner): keep PR #1 open and unmerged until replacement audio
works in game; surgical changes with regression tests; never call a bug fixed because
tests pass, only after an in-game check.
