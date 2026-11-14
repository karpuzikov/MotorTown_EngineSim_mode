#include "engine_sim_backend.h"
#include "impulse_wav.h"
#include "crank_speed_follower.h"
#include "profile_level.h"
#include "real_spec_profile.h"
#include "starter_policy.h"

#include "compiler.h"
#include "crankshaft.h"
#include "engine.h"
#include "exhaust_system.h"
#include "fuel.h"
#include "ignition_module.h"
#include "impulse_response.h"
#include "simulator.h"
#include "synthesizer.h"
#include "transmission.h"
#include "units.h"
#include "vehicle.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <optional>
#include <vector>
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
// clipping; the pedal-and-rpm level below then applies to all alike). Engine
// Simulator's own road-vehicle exhaust response (default_0) is 10x quieter
// than the sporty one the generated engines used before, and x8 then left the
// Mercedes OM 422 diesel 10 dB under the rest of 28 engines (11 dB spread; at
// x64 the spread is 3 dB). The leveler attacks at once, so the cap only matters
// for engines whose raw output is quiet. One of those is the unfired crank of
// the key turn: at x64 it played 20-36 dB under the idle (silence, then the
// engine: "binary on/off" in game); at x1024 it is 10-15 dB under it on every
// engine measured (V8, six, four, diesels, bikes), where the level laws below
// put it, and the idle itself does not change (offline, 2026-11-05).
constexpr float EngineSimLevelerMaxGain = 1024.0f;
// Volume of a rule's own exhaust response (#exhaust=), when it names one.
constexpr double VehicleExhaustImpulseVolume = 0.02;
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

// A car that already runs when it gets this simulator (traffic that came into
// earshot) must not be heard starting: the starter, a wide-open pedal and an
// rpm overshoot lasted ~1.2 s and sounded like every passing car flooring the
// pedal (in game, 2026-11-04). It starts where the game says it is: the crank
// at the game's rpm, no starter, and the first seconds of the run, while the
// pedal settles, are not played.
constexpr double WarmStartUnheardSeconds = 1.0;
// The dynamometer holds that speed while the first cylinders fire: unfired,
// the crank lost half its speed in 0.1 s and then overshot.
constexpr double WarmStartHeldSeconds = 0.25;
// The pedal a warm start begins with is a guess (the engines need 0.004-0.08):
// the follower finds the right one this many times faster for this long, or the
// pitch would glide by up to 9% over two seconds.
constexpr double WarmStartFasterFollowingSeconds = 1.5;
constexpr double WarmStartFasterFollowingScale = 4.0;
constexpr double OutputSampleRate = 44100.0;

std::atomic<MufflerTreble> g_muffler{MufflerTreble::Standard}; // settings.ini, see set_engine_sim_muffler

// Engine Simulator low-passes its air noise at 2 kHz, so a diesel had nothing above about 4 kHz ("like over the
// phone", owner, on EngineVoice's Volvo D13); 15 kHz picked by ear there (2026-11-11). Diesels only: on a petrol
// engine's mix it only added a scratching hiss.
constexpr float DieselAirNoiseFrequencyCutoff = 15000.0f;

// A distant (traffic) voice convolves with only the start of its exhaust's
// response: the long tail cost 0.24 of a core per voice (measured offline) and
// left the tone as it was (output spectrum within 0.1 dB in every octave band).
constexpr std::size_t DistantImpulseFrames = 4096;

void shorten_impulse(std::vector<std::int16_t> &samples) {
    if (samples.size() <= DistantImpulseFrames) return;
    samples.resize(DistantImpulseFrames);
    const std::size_t fade = DistantImpulseFrames / 2;
    for (std::size_t i = 0; i < fade; ++i) {
        auto &sample = samples[DistantImpulseFrames - fade + i];
        sample = static_cast<std::int16_t>(std::lround(sample * (1.0 - double(i + 1) / double(fade))));
    }
}

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
            m_classLoudnessDb = engine_class_loudness_db(m_engine->getDisplacement() * 1000.0);
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
            // A diesel meters its own fuel: the script's injection pump follows the speed control.
            if (m_engine->getIgnitionModule()->isCompressionIgnition())
                audio.airNoiseFrequencyCutoff = DieselAirNoiseFrequencyCutoff;
            m_simulator->synthesizer().setAudioParameters(audio);
            // Generated profiles may carry a boost file; other scripts yield
            // the default (no boost).
            m_boost = read_full_load_boost(script);
            m_rpmScale = profile_rpm_scale(script);
            m_follower.reset();
            m_starterEngaged = true;
            m_hasRun = false;
            m_motoring = false;
            m_secondsFarBelowGameRpm = 0.0;
            m_loudnessGain = -1.0; // first read() jumps to the target
            m_lastTargetRpm = -1.0;
            m_framesToDiscard.store(0);
            m_secondsHeldAtGameRpm = 0.0;
            m_secondsFollowingFaster = 0.0;

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
                const auto impulse = muffler_variant_path(spec.exhaustImpulse.empty()
                    ? impulse_wav_path(script, response->getFilename())
                    : std::filesystem::path(spec.exhaustImpulse), script, g_muffler.load());
                auto samples = load_impulse_wav(impulse.string());
                if (spec.distant) shorten_impulse(samples);
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

    void set_game_max_rpm(double maxRpm) override {
        m_gameMaxRpm = std::isfinite(maxRpm) && maxRpm > 0 ? maxRpm : 0.0;
    }

    bool advance(double seconds, double gameRpm, double throttle, bool combustion) override {
        if (!m_simulator || !m_engine || !std::isfinite(gameRpm) || !std::isfinite(throttle)) return false;
        const double redlineRpm = m_engine->getRedline() / units::rpm(1.0);
        const double targetRpm = engine_rpm_for_game_rpm(
            gameRpm * m_rpmScale, m_gameMaxRpm * m_rpmScale, redlineRpm);
        m_targetLoudnessGain.store(std::pow(10.0, m_classLoudnessDb / 20.0));
        const double starterReleaseRpm = starter_release_rpm(
            m_engine->getStarterSpeed() / units::rpm(1.0), targetRpm);

        // The engine runs free, as in the Engine Simulator application: ignition
        // on or off, the starter while it is cranking, no clutch (neutral), so
        // its own combustion sets the crank's speed. See the drivetrain notes
        // above for the dynamometer.
        m_engine->getIgnitionModule()->m_enabled = combustion;
        m_transmission->setClutchPressure(0.0);
        if (!combustion) {
            m_follower.reset();
            m_starterEngaged = !m_hasRun; // the first key turn cranks, fired or not
            m_motoring = false;
            m_secondsFarBelowGameRpm = 0.0;
        }
        // The key turn before the engine first catches is cranked unfired and
        // driven at the game's speed: the starter alone stalled the 13-litre
        // diesel on its compression within 0.8 s (silence), as the generated
        // starter (200 lb-ft for every engine) is far under such an engine's need.
        const bool crankingUnfired = !combustion && !m_hasRun && targetRpm < starterReleaseRpm;
        m_simulator->m_dyno.m_enabled = combustion || crankingUnfired;

        // Motor Town RPM arrives every 50-150 ms: aim at a target that moves
        // smoothly across the frame instead of stepping.
        const bool firstFrame = m_lastTargetRpm < 0.0;
        const double fromRpm = firstFrame ? targetRpm : m_lastTargetRpm;
        m_lastTargetRpm = targetRpm;
        if (firstFrame && combustion && targetRpm >= starterReleaseRpm) {
            // Already running at the game's speed: nothing to crank or hear.
            start_turning_forward(m_engine, units::rpm(targetRpm));
            m_starterEngaged = false;
            m_hasRun = true;
            m_secondsHeldAtGameRpm = WarmStartHeldSeconds;
            m_secondsFollowingFaster = WarmStartFasterFollowingSeconds;
            m_framesToDiscard.store(static_cast<std::size_t>(
                WarmStartUnheardSeconds * OutputSampleRate));
        }

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
                ? m_follower.update(m_simulator->getTimestep(), followedRpm, engineRpm, redlineRpm,
                    m_secondsFollowingFaster > 0.0 ? WarmStartFasterFollowingScale : 1.0)
                : 0.0;
            m_secondsFollowingFaster = std::max(0.0, m_secondsFollowingFaster - m_simulator->getTimestep());
            m_engine->setSpeedControl(pedal);
            apply_boost(m_engine, m_boost, targetRpm, throttle);
            const double smoothedRpm = m_follower.smoothedRpm();
            if (combustion && smoothedRpm >= starterReleaseRpm) m_hasRun = true;
            m_starterEngaged = starter_engaged(m_starterEngaged, combustion, m_hasRun,
                smoothedRpm, targetRpm, starterReleaseRpm);
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
            const bool driven = m_motoring || crankingUnfired;
            const bool held = driven || m_secondsHeldAtGameRpm > 0.0;
            if (driven) start_turning_forward(m_engine, units::rpm(followedRpm));
            m_secondsHeldAtGameRpm = std::max(0.0, m_secondsHeldAtGameRpm - m_simulator->getTimestep());
            m_simulator->m_dyno.m_hold = held;
            m_simulator->m_dyno.m_rotationSpeed = units::rpm(
                held ? followedRpm : followedRpm * (1.0 + DrivetrainBrakeMarginAboveGameRpm));
        } while (m_simulator->simulateStep());
        m_simulator->endFrame();
        return true;
    }

    std::size_t read(std::int16_t *dst, std::size_t frames) override {
        if (!m_simulator || !dst || frames == 0) return 0;
        // A warm start's run-up passes unheard.
        while (m_framesToDiscard.load() > 0) {
            std::array<std::int16_t, 1024> unheard;
            const auto asked = std::min(m_framesToDiscard.load(), unheard.size());
            const auto passed = static_cast<std::size_t>(std::max(0,
                m_simulator->readAudioOutput(static_cast<int>(asked), unheard.data())));
            if (passed == 0) return 0; // not produced yet
            m_framesToDiscard.store(m_framesToDiscard.load() - std::min(passed, asked));
        }
        const auto count = static_cast<int>(std::min<std::size_t>(
            frames, std::numeric_limits<int>::max()));
        const auto read = static_cast<std::size_t>(
            std::max(0, m_simulator->readAudioOutput(count, dst)));
        if (read == 0) return 0;
        // Pedal and gear changes swell and fade, never click or drop.
        const double target = m_targetLoudnessGain.load();
        if (m_loudnessGain < 0) m_loudnessGain = target;
        for (std::size_t i = 0; i < read; ++i) {
            m_loudnessGain = glide_loudness_gain(m_loudnessGain, target, 1.0 / OutputSampleRate);
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
    bool m_hasRun = false; // the engine has caught since it was loaded
    bool m_motoring = false;
    double m_secondsFarBelowGameRpm = 0.0;
    double m_secondsHeldAtGameRpm = 0.0;     // warm start
    double m_secondsFollowingFaster = 0.0;   // warm start
    double m_classLoudnessDb = 0.0;                // this engine's size, from load()
    // advance() thread -> read() thread. Silent until the first advance() says
    // how loud: a read before it took 0 dB as the level, 24 dB over the real one,
    // and the slow fall then played it as a loud start.
    std::atomic<double> m_targetLoudnessGain{0.0};
    double m_gameMaxRpm = 0.0;                     // advance() thread; 0 = unknown
    double m_loudnessGain = -1.0;                  // read() thread only; negative until the first read
    double m_lastTargetRpm = -1.0; // negative until the first frame
    std::atomic<std::size_t> m_framesToDiscard{0}; // advance() thread -> read() thread
    double m_rpmScale = 1.0;
    FullLoadBoost m_boost;
};

} // namespace

std::unique_ptr<EngineBackend> make_engine_sim_backend() {
    return std::make_unique<EngineSimBackend>();
}

void set_engine_sim_muffler(MufflerTreble muffler) noexcept {
    g_muffler.store(muffler);
}

} // namespace mtes
