#include "engine_sim_backend.h"
#include "impulse_wav.h"
#include "overrun_fuel_cut.h"
#include "loudness_leveler.h"
#include "profile_level.h"

#include "compiler.h"
#include "crankshaft.h"
#include "engine.h"
#include "exhaust_system.h"
#include "ignition_module.h"
#include "impulse_response.h"
#include "simulator.h"
#include "synthesizer.h"
#include "transmission.h"
#include "units.h"
#include "vehicle.h"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <limits>

namespace mtes {
namespace {

// Engine Simulator's starter turns the crank to -starter_speed: negative
// v_theta for most models, positive for those scripted with a negative
// starter speed (e.g. the Honda B18C). The dynamometer keeps whichever
// direction the crank already turns, and drives a resting crank backwards.
void spin_forward(Engine *engine, double speed) {
    const double direction = engine->getStarterSpeed() < 0.0 ? 1.0 : -1.0;
    const double forward = direction * std::max(std::abs(speed), units::rpm(1.0));
    for (int i = 0; i < engine->getCrankshaftCount(); ++i) {
        auto &body = engine->getCrankshaft(i)->m_body;
        if (!(body.v_theta * direction > 0.0)) body.v_theta = forward;
    }
}

class EngineSimBackend final : public EngineBackend {
public:
    ~EngineSimBackend() override { stop(); }

    bool load(const std::string &script) override {
        stop();
        if (script.empty() || !std::filesystem::is_regular_file(script)) return false;

        // The script engine creates the actual pistons, crankshaft, firing
        // order, intake, exhaust, vehicle, and gearbox for each selected model.
        es_script::Compiler compiler;
        compiler.initialize();
        es_script::Compiler::Output output;
        bool compiled = false;
        try {
            // This upstream compiler caches its output in static storage;
            // invalidate the previous vehicle before loading another script.
            *es_script::Compiler::output() = es_script::Compiler::Output{};
            compiled = compiler.compile(script.c_str());
            if (compiled) output = compiler.execute();
        }
        catch (...) {
            compiled = false;
        }
        compiler.destroy();
        if (!compiled || !output.engine || !output.vehicle || !output.transmission) {
            // An incomplete script does not justify muting Motor Town audio.
            return false;
        }

        m_engine = output.engine;
        m_vehicle = output.vehicle;
        m_transmission = output.transmission;
        try {
            m_engine->calculateDisplacement();
            m_simulator = m_engine->createSimulator(m_vehicle, m_transmission);
            if (!m_simulator) {
                stop();
                return false;
            }
            m_simulator->setSimulationFrequency(
                static_cast<int>(m_engine->getSimulationFrequency()));

            auto audio = m_simulator->synthesizer().getAudioParameters();
            audio.inputSampleNoise = static_cast<float>(m_engine->getInitialJitter());
            audio.airNoise = static_cast<float>(m_engine->getInitialNoise());
            audio.dF_F_mix = static_cast<float>(m_engine->getInitialHighFrequencyGain());
            m_simulator->synthesizer().setAudioParameters(audio);
            m_rpmScale = profile_rpm_scale(script);
            m_calibrated = false;
            if (const auto gain = profile_output_gain(script)) {
                // Linear output at the profile's measured gain; the built-in
                // leveler only limits peaks above its target. Set before the
                // render thread starts. LoudnessLeveler shapes dynamics.
                auto &leveler = m_simulator->synthesizer().m_levelingFilter;
                leveler.p_maxLevel = static_cast<float>(*gain);
                leveler.p_minLevel = static_cast<float>(*gain * 0.001);
                m_profileGain = *gain;
                m_calibrated = true;
                m_leveler.reset();
            }

            const int exhausts = m_engine->getExhaustSystemCount();
            if (exhausts <= 0) {
                stop();
                return false;
            }
            for (int i = 0; i < exhausts; ++i) {
                const auto *response = m_engine->getExhaustSystem(i)->getImpulseResponse();
                if (!response) {
                    stop();
                    return false;
                }
                const auto impulse = impulse_wav_path(script, response->getFilename());
                const auto samples = load_impulse_wav(impulse.string());
                if (!usable_impulse_for_engine_sim(samples) ||
                    samples.size() > std::numeric_limits<unsigned int>::max()) {
                    stop();
                    return false;
                }
                m_simulator->synthesizer().initializeImpulseResponse(
                    samples.data(), static_cast<unsigned int>(samples.size()),
                    response->getVolume(), i);
            }
            m_simulator->startAudioRenderingThread();
            return true;
        }
        catch (...) {
            stop();
            return false;
        }
    }

    bool advance(double seconds, double gameRpm, double throttle, int gear) override {
        if (!m_simulator || !m_engine || !m_transmission ||
            !std::isfinite(gameRpm) || !std::isfinite(throttle)) return false;
        const double rpm = gameRpm * m_rpmScale;

        // Follow Motor Town crankshaft speed; its driving physics remain
        // authoritative. The simulator's dynamometer holds that speed while
        // its own combustion model generates the audio samples.
        const double redlineRpm = m_engine->getRedline() / units::rpm(1.0);
        m_engine->getIgnitionModule()->m_enabled = !m_fuelCut.update(rpm, throttle, redlineRpm);
        m_engine->setSpeedControl(throttle);
        m_simulator->m_starterMotor.m_enabled = false;
        m_simulator->m_dyno.m_enabled = true;
        m_simulator->m_dyno.m_hold = true;
        // Motor Town RPM arrives every 50-150 ms. Stepping the dynamometer to
        // each new speed jerks the crankshaft, audible as an odd falling-RPM
        // sound in game. Ramp from the previous target across this frame.
        const double target = units::rpm(rpm);
        const double from = m_lastDynoSpeed >= 0.0 ? m_lastDynoSpeed : target;
        // The dynamometer drives a resting crankshaft BACKWARDS. Without a
        // starter every model ran in reverse: intake valves pumped gas into
        // a closed throttle (30 atm manifold), throttle response was inverted
        // and coasting whined like a drill. Spin it forward first.
        spin_forward(m_engine, from);
        // The clutch stays open (the dynamometer holds the game RPM), so the
        // simulated gearbox stays in neutral: Motor Town gears beyond the
        // profile's gearbox must never reach the simulator.
        (void)gear;
        m_transmission->setClutchPressure(0.0);

        // Engine Simulator's standalone GUI varies its physics step count by
        // +/-10% to chase a preferred input-audio latency. Motor Town supplies
        // the real playback clock: shortening a 150-ms simulation frame that
        // way produces fewer than the requested 6615 PCM samples and causes
        // irrecoverable underruns regardless of producer wait time. Equalize
        // the target to the currently measured latency before startFrame(),
        // disabling both automatic resampling branches without patching the
        // pinned third-party library or changing the actual engine model.
        m_simulator->setTargetSynthesizerLatency(
            m_simulator->getSynthesizerInputLatency());
#ifndef MTES_MEASURE_RAW_LEVELS // offline profile calibration measures fixed gain
        if (m_calibrated) {
            // The synthesizer's render thread reads this cap per sample, as
            // it reads upstream's own setAudioParameters() values: a single
            // aligned float store, changed slowly and smoothed per sample.
            m_simulator->synthesizer().m_levelingFilter.p_maxLevel =
                static_cast<float>(m_profileGain * m_leveler.update(seconds));
        }
#endif
        m_simulator->startFrame(seconds);
        const int steps = m_simulator->getFrameIterationCount();
        do {
            const double t = steps > 0
                ? std::min(1.0, (m_simulator->getCurrentIteration() + 1) / static_cast<double>(steps))
                : 1.0;
            m_simulator->m_dyno.m_rotationSpeed = from + (target - from) * t;
        } while (m_simulator->simulateStep());
        m_simulator->endFrame();
        m_lastDynoSpeed = target;
        return true;
    }

    std::size_t read(std::int16_t *dst, std::size_t frames) override {
        if (!m_simulator || !dst || frames == 0) return 0;
        const auto count = static_cast<int>(std::min<std::size_t>(
            frames, std::numeric_limits<int>::max()));
        const auto read = static_cast<std::size_t>(
            std::max(0, m_simulator->readAudioOutput(count, dst)));
        if (m_calibrated) m_leveler.observe(dst, read);
        return read;
    }

    void stop() noexcept override {
        // Requires native/patch_engine_sim_core.py applied to the build-only
        // Engine Simulator checkout: upstream forgets several allocations.
        m_lastDynoSpeed = -1.0;
        m_fuelCut.reset();
        m_calibrated = false;
        if (m_simulator) {
            m_simulator->releaseSimulation();
            delete m_simulator;
            m_simulator = nullptr;
        }
        if (m_engine) {
            m_engine->destroy();
            delete m_engine;
            m_engine = nullptr;
        }
        delete m_vehicle;
        delete m_transmission;
        m_vehicle = nullptr;
        m_transmission = nullptr;
    }

private:
    Engine *m_engine = nullptr;
    Vehicle *m_vehicle = nullptr;
    Transmission *m_transmission = nullptr;
    Simulator *m_simulator = nullptr;
    double m_lastDynoSpeed = -1.0; // rad/s; negative until the first frame
    OverrunFuelCut m_fuelCut;
    LoudnessLeveler m_leveler;
    double m_profileGain = 1.0;
    double m_rpmScale = 1.0;
    bool m_calibrated = false;
};

} // namespace

std::unique_ptr<EngineBackend> make_engine_sim_backend() {
    return std::make_unique<EngineSimBackend>();
}

} // namespace mtes
