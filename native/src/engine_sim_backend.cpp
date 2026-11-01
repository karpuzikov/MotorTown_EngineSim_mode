#include "engine_sim_backend.h"
#include "impulse_wav.h"

#include "compiler.h"
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

    bool advance(double seconds, double rpm, double throttle, int gear) override {
        if (!m_simulator || !m_engine || !m_transmission ||
            !std::isfinite(rpm) || !std::isfinite(throttle)) return false;

        // Follow Motor Town crankshaft speed; its driving physics remain
        // authoritative. The simulator's dynamometer holds that speed while
        // its own combustion model generates the audio samples.
        m_engine->getIgnitionModule()->m_enabled = true;
        m_engine->setSpeedControl(throttle);
        m_simulator->m_starterMotor.m_enabled = false;
        m_simulator->m_dyno.m_enabled = true;
        m_simulator->m_dyno.m_hold = true;
        m_simulator->m_dyno.m_rotationSpeed = units::rpm(rpm);
        if (m_transmission->getGear() != gear) m_transmission->changeGear(gear);
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
        m_simulator->startFrame(seconds);
        while (m_simulator->simulateStep()) {}
        m_simulator->endFrame();
        return true;
    }

    std::size_t read(std::int16_t *dst, std::size_t frames) override {
        if (!m_simulator || !dst || frames == 0) return 0;
        const auto count = static_cast<int>(std::min<std::size_t>(
            frames, std::numeric_limits<int>::max()));
        return static_cast<std::size_t>(
            std::max(0, m_simulator->readAudioOutput(count, dst)));
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
};

} // namespace

std::unique_ptr<EngineBackend> make_engine_sim_backend() {
    return std::make_unique<EngineSimBackend>();
}

} // namespace mtes
