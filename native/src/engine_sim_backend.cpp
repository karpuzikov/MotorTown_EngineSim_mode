#include "engine_sim_backend.h"
#include "impulse_wav.h"
#include "crank_speed_follower.h"
#include "profile_level.h"
#include "real_spec_profile.h"

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
#include <atomic>
#include <cmath>
#include <optional>
#include <filesystem>
#include <limits>

namespace mtes {
namespace {

// Engine Simulator's leveler (its own loudness control) with half its stock
// target: its gain smoothing lags each firing pulse and overshot the stock 30000
// target, clipping ~4% of samples. A level, not a tone, change.
constexpr float EngineSimLevelerTargetWithHeadroom = 15000.0f;
// Its stock maximum boost (x1.9) left a throttled diesel's idle 6-10 dB under
// every petrol engine; at x8 each engine reaches the target (measured: no
// clipping; the pedal-and-rpm level below then applies to all alike).
constexpr float EngineSimLevelerMaxGain = 8.0f;
// Volume of a rule's own exhaust response (#exhaust=), when it names one.
constexpr double VehicleExhaustImpulseVolume = 0.02;
// The starter cranks until the crank turns at this multiple of its own speed
// or half the game's rpm, whichever is higher; then the engine runs by itself.
// It cranks again only if the engine falls under this fraction of that speed
// (a one-cylinder engine's speed swings across a single threshold).
constexpr double StarterReleaseOfStarterSpeed = 1.2;
constexpr double StarterReleaseOfGameRpm = 0.5;
constexpr double StarterReengageFraction = 0.6;

// Motor Town simulates a drivetrain; Engine Simulator here does not. Its
// dynamometer stands in for it, but only at the extremes, so the engine's own
// combustion keeps shaping its crank speed (a rigid hold removed ~10 dB of
// 400-1600 Hz from the same engine at the same speed, 2026-11-04):
//  - a brake takes over the road load this far above the game's rpm, and
//  - the driveline turns the engine when it cannot keep up: more than 15%
//    below the game's rpm for 0.3 s (cranking a diesel, coasting down),
//    until it is within 5%.
constexpr double DrivetrainBrakeMarginAboveGameRpm = 0.10;
constexpr double DrivetrainMotoringBelowGameRpm = 0.15;
constexpr double DrivetrainMotoringReleasedBelowGameRpm = 0.05;
constexpr double DrivetrainMotoringDwellSeconds = 0.3;
constexpr double LoudnessGlideSeconds = 0.08;

// Engine Simulator's starter turns the crank to -starter_speed: negative
// v_theta for most models, positive for those scripted with a negative
// starter speed. The dynamometer keeps whichever direction the crank already
// turns, and drives a resting crank backwards.
void start_turning_forward(Engine *engine, double speed) {
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

    bool load(const std::string &engineSoundSpec) override {
        stop();
        const auto parsedSpec = parse_engine_sound_spec(engineSoundSpec);
        if (!parsedSpec) return false;
        const auto &spec = *parsedSpec;
        const auto &script = spec.script;
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
            audio.levelerTarget = EngineSimLevelerTargetWithHeadroom;
            audio.levelerMaxGain = EngineSimLevelerMaxGain;
            m_simulator->synthesizer().setAudioParameters(audio);
            // Generated profiles may carry a boost file; other scripts yield
            // the default (no boost).
            m_boost = read_full_load_boost(script);
            m_rpmScale = profile_rpm_scale(script);
            m_follower.reset();
            m_starterEngaged = true;
            m_motoring = false;
            m_secondsFarBelowGameRpm = 0.0;
            m_loudnessGain = -1.0; // first read() jumps to the target
            m_lastTargetRpm = -1.0;

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
                // The vehicle's own exhaust (make_exhausts.py) replaces the
                // engine script's generic muffler recording.
                const auto impulse = spec.exhaustImpulse.empty()
                    ? impulse_wav_path(script, response->getFilename())
                    : std::filesystem::path(spec.exhaustImpulse);
                const auto samples = load_impulse_wav(impulse.string());
                if (!usable_impulse_for_engine_sim(samples) ||
                    samples.size() > std::numeric_limits<unsigned int>::max()) {
                    stop();
                    return false;
                }
                m_simulator->synthesizer().initializeImpulseResponse(
                    samples.data(), static_cast<unsigned int>(samples.size()),
                    spec.exhaustImpulse.empty() ? response->getVolume() : VehicleExhaustImpulseVolume, i);
            }
            m_simulator->startAudioRenderingThread();
            return true;
        }
        catch (...) {
            stop();
            return false;
        }
    }

    bool advance(double seconds, double gameRpm, double throttle, bool combustion) override {
        if (!m_simulator || !m_engine || !std::isfinite(gameRpm) || !std::isfinite(throttle)) return false;
        const double targetRpm = gameRpm * m_rpmScale;
        const double redlineRpm = m_engine->getRedline() / units::rpm(1.0);
        m_targetLoudnessGain.store(std::pow(10.0,
            engine_loudness_gain_db(targetRpm, redlineRpm, throttle) / 20.0));
        const double starterReleaseRpm = std::max(
            StarterReleaseOfStarterSpeed * std::abs(m_engine->getStarterSpeed()) / units::rpm(1.0),
            StarterReleaseOfGameRpm * targetRpm);

        // The engine runs free, as in the Engine Simulator application: ignition
        // on or off, the starter while it is cranking, no clutch (neutral), so
        // its own combustion sets the crank's speed. See the drivetrain notes
        // above for the dynamometer.
        m_engine->getIgnitionModule()->m_enabled = combustion;
        m_transmission->setClutchPressure(0.0);
        if (!combustion) {
            m_follower.reset();
            m_starterEngaged = true; // the next key turn cranks
            m_motoring = false;
            m_secondsFarBelowGameRpm = 0.0;
        }
        m_simulator->m_dyno.m_enabled = combustion;

        // Motor Town RPM arrives every 50-150 ms: aim at a target that moves
        // smoothly across the frame instead of stepping.
        const double fromRpm = m_lastTargetRpm >= 0.0 ? m_lastTargetRpm : targetRpm;
        m_lastTargetRpm = targetRpm;

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
        m_simulator->startFrame(seconds);
        const int steps = m_simulator->getFrameIterationCount();
        do {
            const double progress = steps > 0
                ? std::min(1.0, (m_simulator->getCurrentIteration() + 1) / static_cast<double>(steps))
                : 1.0;
            const double engineRpm = std::abs(m_engine->getRpm());
            const double followedRpm = fromRpm + (targetRpm - fromRpm) * progress;
            const double pedal = combustion
                ? m_follower.update(m_simulator->getTimestep(), followedRpm, engineRpm, redlineRpm)
                : 0.0;
            m_engine->setSpeedControl(pedal);
            apply_boost(m_engine, m_boost, targetRpm, throttle);
            const double smoothedRpm = m_follower.smoothedRpm();
            m_starterEngaged = combustion && (m_starterEngaged
                ? smoothedRpm < starterReleaseRpm
                : smoothedRpm < StarterReengageFraction * starterReleaseRpm);
            m_simulator->m_starterMotor.m_enabled = m_starterEngaged;

            const double deficit = followedRpm > 0.0 ? 1.0 - smoothedRpm / followedRpm : 0.0;
            if (m_motoring) {
                if (deficit < DrivetrainMotoringReleasedBelowGameRpm) {
                    m_motoring = false;
                    m_secondsFarBelowGameRpm = 0.0;
                }
            }
            else {
                m_secondsFarBelowGameRpm = deficit > DrivetrainMotoringBelowGameRpm
                    ? m_secondsFarBelowGameRpm + m_simulator->getTimestep() : 0.0;
                m_motoring = m_secondsFarBelowGameRpm >= DrivetrainMotoringDwellSeconds;
            }
            if (m_motoring) start_turning_forward(m_engine, units::rpm(followedRpm));
            m_simulator->m_dyno.m_hold = m_motoring;
            m_simulator->m_dyno.m_rotationSpeed = units::rpm(
                m_motoring ? followedRpm : followedRpm * (1.0 + DrivetrainBrakeMarginAboveGameRpm));
        } while (m_simulator->simulateStep());
        m_simulator->endFrame();
        return true;
    }

    std::size_t read(std::int16_t *dst, std::size_t frames) override {
        if (!m_simulator || !dst || frames == 0) return 0;
        const auto count = static_cast<int>(std::min<std::size_t>(
            frames, std::numeric_limits<int>::max()));
        const auto read = static_cast<std::size_t>(
            std::max(0, m_simulator->readAudioOutput(count, dst)));
        // ~80 ms glide: pedal and gear changes swell, never click.
        const double target = m_targetLoudnessGain.load();
        if (m_loudnessGain < 0) m_loudnessGain = target;
        for (std::size_t i = 0; i < read; ++i) {
            m_loudnessGain += (target - m_loudnessGain) * (1.0 / (LoudnessGlideSeconds * 44100.0));
            dst[i] = static_cast<std::int16_t>(std::lround(dst[i] * m_loudnessGain));
        }
        return read;
    }

    void stop() noexcept override {
        // Requires native/patch_engine_sim_core.py applied to the build-only
        // Engine Simulator checkout: upstream forgets several allocations.
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
    CrankSpeedFollower m_follower;
    bool m_starterEngaged = true;
    bool m_motoring = false;
    double m_secondsFarBelowGameRpm = 0.0;
    std::atomic<double> m_targetLoudnessGain{1.0}; // advance() thread -> read() thread
    double m_loudnessGain = -1.0;                  // read() thread only; negative until the first read
    double m_lastTargetRpm = -1.0; // negative until the first frame
    double m_rpmScale = 1.0;
    FullLoadBoost m_boost;
};

} // namespace

std::unique_ptr<EngineBackend> make_engine_sim_backend() {
    return std::make_unique<EngineSimBackend>();
}

} // namespace mtes
