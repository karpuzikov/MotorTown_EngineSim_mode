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

    def test_opt_in_gm_ls_v8_has_bounded_physics_cost(self):
        backend = (ROOT / 'src/engine_sim_backend.cpp').read_text()
        # A 10-kHz V8 consumed 120-144 ms per 150-ms frame on the actual
        # Windows runner; the async synthesizer then missed its deadline.
        # Keep all other models at authored quality; this is a bounded
        # experiment on the exact GM LS V8 prototype used for the Dory.
        self.assertIn('m_engine->getName() == "GM LS"', backend)
        self.assertIn('m_engine->getCylinderCount() == 8', backend)
        self.assertIn('std::min(authoredHz, 8000)', backend)
