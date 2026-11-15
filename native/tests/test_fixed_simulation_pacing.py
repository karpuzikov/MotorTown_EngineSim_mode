"""Motor Town's telemetry clock must not be stretched by Engine Simulator."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class FixedSimulationPacingTests(unittest.TestCase):
    def test_native_backend_matches_game_duration_not_desktop_latency_feedback(self):
        backend = (ROOT / 'src/engine_sim_backend.cpp').read_text()
        # Pinned Simulator::startFrame adjusts m_steps by +/-10 percent when
        # its *desktop* synthesizer latency differs from a target. For the
        # in-game backend, target the present input latency exactly so it
        # simulates the game's requested duration without that feedback.
        self.assertIn('setTargetSynthesizerLatency(', backend)
        self.assertIn('getSynthesizerInputLatency()', backend)

    def test_physics_frequency_comes_from_one_cpu_budget_never_below_engine_simulators_default(self):
        backend = (ROOT / 'src/engine_sim_backend.cpp').read_text()
        # The scripts' own rates broke up a 17-kHz V12 and made a 13-kHz scooter
        # whistle (in game, 2026-11-14). The 8-kHz V8 experiment both changed
        # audible exhaust filter timing and failed the Windows PCM stress test:
        # the rate never drops below Engine Simulator's 10 kHz default.
        self.assertIn('setSimulationFrequency(simulation_frequency_for(m_engine->getCylinderCount()))', backend)
        self.assertIn('constexpr int SlowestSimulationFrequency = 10000;', backend)
        self.assertNotIn('experimentalGmLs', backend)
        self.assertNotIn('8000', backend)
