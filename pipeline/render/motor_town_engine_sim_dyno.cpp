// Offline dynamometer for generated Engine Simulator scripts.
//
//   motor_town_engine_sim_dyno SCRIPT.mr OUTPUT_DIR [RPM_STEP] [OUTPUT_GAIN]
//
// Compiles the script with Engine Simulator's own compiler, holds the
// crankshaft at each speed from 1000 rpm to redline at full throttle, and
// writes OUTPUT_DIR/dyno.json (measured torque and power, output level) plus
// one 44.1 kHz mono WAV per speed. Same simulator and synthesizer as the mod.
#include "impulse_wav.h"

#include "compiler.h"
#include "engine.h"
#include "exhaust_system.h"
#include "impulse_response.h"
#include "simulator.h"
#include "synthesizer.h"
#include "transmission.h"
#include "units.h"
#include "vehicle.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr double FrameSeconds = 1.0 / 60.0;
constexpr double SettleSeconds = 1.5;
constexpr double MeasureSeconds = 1.0;
constexpr int AudioSampleRate = 44100;

void write_wav(const std::filesystem::path &path, const std::vector<std::int16_t> &samples) {
    std::ofstream file(path, std::ios::binary);
    auto put32 = [&](std::uint32_t v) { file.write(reinterpret_cast<const char *>(&v), 4); };
    auto put16 = [&](std::uint16_t v) { file.write(reinterpret_cast<const char *>(&v), 2); };
    const std::uint32_t bytes = static_cast<std::uint32_t>(samples.size() * 2);
    file.write("RIFF", 4); put32(36 + bytes); file.write("WAVEfmt ", 8);
    put32(16); put16(1); put16(1); put32(AudioSampleRate); put32(AudioSampleRate * 2);
    put16(2); put16(16); file.write("data", 4); put32(bytes);
    file.write(reinterpret_cast<const char *>(samples.data()), bytes);
}

// The dynamometer drives a resting crankshaft backwards; start it turning
// the way the starter would.
void spin_forward(Engine *engine, double speed) {
    const double direction = engine->getStarterSpeed() < 0.0 ? 1.0 : -1.0;
    for (int i = 0; i < engine->getCrankshaftCount(); ++i) {
        auto &body = engine->getCrankshaft(i)->m_body;
        if (!(body.v_theta * direction > 0.0)) body.v_theta = direction * speed;
    }
}

struct DynoPoint {
    double rpm, torqueNm, powerHp, rmsDbfs, peakDbfs, clippedFraction;
};

// One frame of physics, then the synthesizer renders it on this thread.
void run_frame(Simulator *simulator, std::vector<std::int16_t> *audio, double *torqueSum, int *torqueSteps) {
    simulator->setTargetSynthesizerLatency(simulator->getSynthesizerInputLatency());
    simulator->startFrame(FrameSeconds);
    while (simulator->simulateStep()) {
        if (torqueSum) { *torqueSum += simulator->m_dyno.getTorque(); ++*torqueSteps; }
    }
    simulator->endFrame();
    simulator->synthesizer().renderAudio();
    std::int16_t buffer[4096];
    int read;
    while ((read = simulator->readAudioOutput(4096, buffer)) > 0) {
        if (audio) audio->insert(audio->end(), buffer, buffer + read);
    }
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: motor_town_engine_sim_dyno SCRIPT.mr OUTPUT_DIR [RPM_STEP] [OUTPUT_GAIN]\n";
        return 2;
    }
    const std::filesystem::path outputDir = argv[2];
    const double rpmStep = argc > 3 ? std::stod(argv[3]) : 500.0;
    // Being calibrated: one gain for every engine, chosen so the loudest stays below full scale.
    const float outputGain = argc > 4 ? std::stof(argv[4]) : 1.0f;
    std::filesystem::create_directories(outputDir);

    es_script::Compiler compiler;
    compiler.initialize();
    if (!compiler.compile(argv[1])) {
        std::cerr << "compile failed: " << argv[1] << " (see error_log.log)\n";
        return 1;
    }
    const es_script::Compiler::Output output = compiler.execute();
    compiler.destroy();
    if (!output.engine || !output.vehicle || !output.transmission) {
        std::cerr << "script has no engine, vehicle or transmission\n";
        return 1;
    }
    Engine *engine = output.engine;
    engine->calculateDisplacement();
    Simulator *simulator = engine->createSimulator(output.vehicle, output.transmission);
    simulator->setSimulationFrequency(static_cast<int>(engine->getSimulationFrequency()));
    auto audio = simulator->synthesizer().getAudioParameters();
    audio.inputSampleNoise = static_cast<float>(engine->getInitialJitter());
    audio.airNoise = static_cast<float>(engine->getInitialNoise());
    audio.dF_F_mix = static_cast<float>(engine->getInitialHighFrequencyGain());
    // One fixed gain for every engine instead of the automatic leveler, so
    // loudness differences come from the simulation itself.
    audio.levelerMinGain = outputGain;
    audio.levelerMaxGain = outputGain;
    simulator->synthesizer().setAudioParameters(audio);
    for (int i = 0; i < engine->getExhaustSystemCount(); ++i) {
        const ImpulseResponse *response = engine->getExhaustSystem(i)->getImpulseResponse();
        const auto samples = mtes::load_impulse_wav(response->getFilename());
        if (!mtes::usable_impulse_for_engine_sim(samples)) {
            std::cerr << "unusable impulse response " << response->getFilename() << "\n";
            return 1;
        }
        simulator->synthesizer().initializeImpulseResponse(
            samples.data(), static_cast<unsigned int>(samples.size()), response->getVolume(), i);
    }

    simulator->m_starterMotor.m_enabled = false;
    simulator->m_dyno.m_enabled = true;
    simulator->m_dyno.m_hold = true;
    engine->getIgnitionModule()->m_enabled = true;
    engine->setSpeedControl(1.0);
    output.transmission->setClutchPressure(0.0);

    const double redlineRpm = engine->getRedline() / units::rpm(1.0);
    std::vector<DynoPoint> points;
    for (double rpm = 1000.0; rpm <= redlineRpm + 1.0; rpm += rpmStep) {
        const double speed = units::rpm(rpm);
        simulator->m_dyno.m_rotationSpeed = speed;
        spin_forward(engine, speed);
        for (double t = 0; t < SettleSeconds; t += FrameSeconds) run_frame(simulator, nullptr, nullptr, nullptr);

        std::vector<std::int16_t> pcm;
        double torqueSum = 0.0;
        int torqueSteps = 0;
        for (double t = 0; t < MeasureSeconds; t += FrameSeconds) run_frame(simulator, &pcm, &torqueSum, &torqueSteps);

        double squares = 0.0, peak = 0.0;
        std::size_t clipped = 0;
        for (const auto s : pcm) {
            squares += double(s) * s;
            peak = std::max(peak, std::abs(double(s)));
            clipped += std::abs(int(s)) >= 32767;
        }
        const double rms = pcm.empty() ? 0.0 : std::sqrt(squares / pcm.size());
        const double torque = torqueSteps ? torqueSum / torqueSteps / units::torque(1.0, units::Nm) : 0.0;
        points.push_back({rpm, torque, torque * speed / 745.7,
            20.0 * std::log10(std::max(rms, 1.0) / 32768.0),
            20.0 * std::log10(std::max(peak, 1.0) / 32768.0),
            pcm.empty() ? 0.0 : double(clipped) / pcm.size()});
        char name[64];
        std::snprintf(name, sizeof(name), "wot_%05.0f_rpm.wav", rpm);
        write_wav(outputDir / name, pcm);
        std::cout << rpm << " rpm: " << torque << " N*m, " << points.back().powerHp << " hp, "
                  << points.back().rmsDbfs << " dBFS\n";
    }

    std::ofstream json(outputDir / "dyno.json");
    json << "{\"script\": \"" << std::filesystem::path(argv[1]).filename().string()
         << "\", \"redline_rpm\": " << redlineRpm
         << ", \"displacement_l\": " << engine->getDisplacement() / units::volume(1.0, units::L)
         << ", \"points\": [";
    for (std::size_t i = 0; i < points.size(); ++i) {
        const auto &p = points[i];
        json << (i ? ", " : "") << "{\"rpm\": " << p.rpm << ", \"torque_nm\": " << p.torqueNm
             << ", \"power_hp\": " << p.powerHp << ", \"rms_dbfs\": " << p.rmsDbfs
             << ", \"peak_dbfs\": " << p.peakDbfs << ", \"clipped_fraction\": " << p.clippedFraction << "}";
    }
    json << "]}\n";
    simulator->releaseSimulation();
    return 0;
}
