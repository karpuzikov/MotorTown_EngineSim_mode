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
#include <cstdlib>
#include <optional>
#include <vector>
#include <filesystem>
#include <limits>

namespace mtes {
namespace {

// One CPU budget for every engine: Engine Simulator steps as fast as the budget allows the engine's cylinders.
// The scripts' own rate (2 x redline) cost the Aventador's V12 at 17 000 Hz 2.4x a V8 at 10 000 Hz, and its
// sound broke up in game; it left the single-cylinder scooter at 13 000 Hz, where the fluid simulation whistled
// at 2.25 kHz (gone at 20 000 Hz) (owner, in game, 2026-11-14).
constexpr double SimulationCylinderStepsPerSecond = 90000.0; // a V8 at 11 250 Hz: V8s at 10-11 000 Hz play clean
constexpr int SlowestSimulationFrequency = 10000; // Engine Simulator's default; slower, its fluid simulation blows up
constexpr int FastestSimulationFrequency = 40000; // the fastest of Ange Yaghi's demo engines
int simulation_frequency_for(int cylinders) {
    const double budgeted = SimulationCylinderStepsPerSecond / std::max(cylinders, 1);
    return std::clamp(static_cast<int>(budgeted), SlowestSimulationFrequency, FastestSimulationFrequency);
}

// Loudness is physics: Engine Simulator's core gives every engine's sound as the pressure 1 m away, in pascals (its
// exhaust, intake mouth and block), and one scale for every engine turns pascals into samples. A truck is louder
// than a kei car because it moves more gas, faster, not by a setting. The scale puts the loudest engine of the fleet
// at full load (the MCI MC-9's two-stroke 6V92TA, 104 dB(A) at 1 m; its peaks 37 Pa) at the leveler's ceiling, so the
// leveler only limits peaks and never evens engines out.
constexpr float SamplesPerPascalAtOneMetre = 400.0f;
// The leveler (Engine Simulator's own loudness control) as a peak limiter only, with half its stock 30000 target:
// its gain smoothing lags each firing pulse and overshot 30000, clipping ~4% of samples.
constexpr float EngineSimLevelerTargetWithHeadroom = 15000.0f;
// A silencer is passive: it can only take sound away, so every exhaust's impulse response is scaled to a gain of 1
// at its loudest frequency (searched in 1/12-octave steps over 20 Hz-10 kHz). It shapes the tone; it does not
// decide how loud an engine is. The scripts' own response volumes were picked by ear, per engine.
constexpr double ExhaustResponseLowestHz = 20.0;
constexpr double ExhaustResponseHighestHz = 10000.0;
constexpr double ExhaustResponseFrequencyStep = 1.0594630943592953; // 2^(1/12)
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

// A distant (traffic) voice convolves with only the start of its exhaust's
// response: the long tail cost 0.24 of a core per voice (measured offline) and
// left the tone as it was (output spectrum within 0.1 dB in every octave band).
constexpr std::size_t DistantImpulseFrames = 4096;

// The volume Engine Simulator's synthesizer scales an impulse response by (it uses volume * sample / 32767, up to
// the last sample over 100 and at most 10 000 samples) so that its loudest frequency has a gain of 1.
double passive_impulse_volume(const std::vector<std::int16_t> &samples) {
    std::size_t length = 0;
    for (std::size_t n = 0; n < samples.size(); ++n) if (std::abs(samples[n]) > 100) length = n + 1;
    length = std::min<std::size_t>(length, 10000);
    double loudestGain = 0.0;
    for (double hz = ExhaustResponseLowestHz; hz <= ExhaustResponseHighestHz; hz *= ExhaustResponseFrequencyStep) {
        const double step = 2.0 * 3.14159265358979323846 * hz / OutputSampleRate;
        double real = 0.0, imaginary = 0.0;
        for (std::size_t n = 0; n < length; ++n) {
            real += samples[n] * std::cos(step * n);
            imaginary -= samples[n] * std::sin(step * n);
        }
        loudestGain = std::max(loudestGain, std::hypot(real, imaginary));
    }
    return 32767.0 / loudestGain;
}

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
            m_simulator = m_engine->createSimulator(m_vehicle, m_transmission);
            if (!m_simulator) {
                stop();
                return false;
            }
            m_simulator->setSimulationFrequency(simulation_frequency_for(m_engine->getCylinderCount()));

            auto audio = m_simulator->synthesizer().getAudioParameters();
            audio.inputSampleNoise = static_cast<float>(m_engine->getInitialJitter());
            audio.airNoise = static_cast<float>(m_engine->getInitialNoise());
            // The core's input is already radiated sound pressure (it is dQ/dt); Engine Simulator's "high frequency
            // gain" mixed in the time derivative of its old pressure signal, which here would differentiate twice
            // and make loudness grow with pitch: at 0.01 it made a 3-litre six 20 dB louder than a 13-litre truck.
            audio.dF_F_mix = 0.0f;
            audio.levelerTarget = EngineSimLevelerTargetWithHeadroom;
            audio.levelerMaxGain = SamplesPerPascalAtOneMetre;
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
                const auto volume = static_cast<float>(passive_impulse_volume(samples));
                m_simulator->synthesizer().initializeImpulseResponse(
                    samples.data(), static_cast<unsigned int>(samples.size()), volume, i);
                // The air box is a reactive chamber sized to the engine like a silencer: the intake mouth's
                // sound passes the first exhaust's response too.
                if (i == 0) m_simulator->synthesizer().initializeImpulseResponse(
                    samples.data(), static_cast<unsigned int>(samples.size()), volume,
                    m_simulator->intakeSoundChannel());
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
        m_targetLoudnessGain.store(1.0);  // how loud the engine is comes from the simulation (SamplesPerPascalAtOneMetre)
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
            // The game's throttle is the engine's load: under more throttle than the game's rpm alone needs,
            // the dynamometer holds the crank at the game's rpm and takes the extra torque, as Engine
            // Simulator's own dynamometer does, so the cylinders burn and sound loaded (the speed follower
            // alone fed only the fuel to spin at that speed).
            m_engine->setSpeedControl(std::max(pedal, throttle));
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
            const bool loaded = throttle > pedal;
            const bool held = driven || loaded || m_secondsHeldAtGameRpm > 0.0;
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
