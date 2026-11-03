// Offline dynamometer for generated Engine Simulator scripts.
//
//   motor_town_engine_sim_dyno SCRIPT.mr OUTPUT_DIR [RPM_STEP] [find-mbt]
//
// Compiles the script with Engine Simulator's own compiler, holds the
// crankshaft at each speed from 1000 rpm to redline at full throttle, and
// writes OUTPUT_DIR/dyno.json (measured torque and power, output level) plus
// one 44.1 kHz mono WAV per speed. Same simulator and synthesizer as the mod.
//
// find-mbt first searches, every 1000 rpm, the spark advance that gives the
// most torque (MBT, as an engine calibrator would) and runs the sweep with it.
#include "impulse_wav.h"
#include "real_spec_profile.h"

#include "compiler.h"
#include "engine.h"
#include "exhaust_system.h"
#include "impulse_response.h"
#include "intake.h"
#include "combustion_chamber.h"
#include "crankshaft.h"
#include "piston_engine_simulator.h"
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
#include <iterator>
#include <stdexcept>
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
    double rpm, sparkAdvanceDeg, torqueNm, powerHp, rmsDbfs, peakDbfs, clippedFraction;
};

// Real engines' best-torque advance lies within this range.
constexpr double MbtSearchMinDeg = 5.0;
constexpr double MbtSearchMaxDeg = 45.0;
constexpr int MbtSearchEvaluations = 7;
constexpr double MbtSettleSeconds = 0.5;
constexpr double MbtMeasureRevolutions = 8.0;   // four 4-stroke cycles

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

mtes::FullLoadBoost g_boost; // shortcut: global for this one-engine tool

// Holds the crankshaft at rpm with the spark advanced by advanceDeg for
// settleSeconds, then returns the mean torque over measureSeconds.
double hold_torque_nm(Simulator *simulator, Engine *engine, double rpm, double advanceDeg,
                      double settleSeconds, double measureSeconds, std::vector<std::int16_t> *audio) {
    const double speed = units::rpm(rpm);
    mtes::apply_boost(engine, g_boost, rpm, 1.0);
    Function *timing = engine->getIgnitionModule()->getTimingCurve();
    timing->setOutputScale(1.0);
    const double scriptAdvance = timing->sampleTriangle(speed);
    timing->setOutputScale(std::abs(scriptAdvance) > 1e-9 ? units::angle(advanceDeg, units::deg) / scriptAdvance : 0.0);
    simulator->m_dyno.m_rotationSpeed = speed;
    spin_forward(engine, speed);
    for (double t = 0; t < settleSeconds; t += FrameSeconds) run_frame(simulator, nullptr, nullptr, nullptr);
    double torqueSum = 0.0;
    int torqueSteps = 0;
    for (double t = 0; t < measureSeconds; t += FrameSeconds) run_frame(simulator, audio, &torqueSum, &torqueSteps);
    const double crankRpm = std::abs(engine->getCrankshaft(0)->m_body.v_theta) / units::rpm(1.0);
    if (!std::isfinite(torqueSum) || std::abs(crankRpm - rpm) > 0.2 * rpm) {
        // Fail fast: a blown-up or stalled simulation reads as dyno max torque.
        std::cerr << "unstable at " << rpm << " rpm: crank " << crankRpm << " rpm, cylinder 1 "
                  << engine->getChamber(0)->m_system.pressure() / units::pressure(1.0, units::atm) << " atm, "
                  << engine->getChamber(0)->m_system.temperature() << " K\n";
        std::exit(3);
    }
    return torqueSteps ? torqueSum / torqueSteps / units::torque(1.0, units::Nm) : 0.0;
}

// Golden-section search for the advance with the most torque.
double find_mbt_deg(Simulator *simulator, Engine *engine, double rpm) {
    const double measure = MbtMeasureRevolutions * 60.0 / rpm;
    auto torque = [&](double deg) { return hold_torque_nm(simulator, engine, rpm, deg, MbtSettleSeconds, measure, nullptr); };
    const double ratio = (std::sqrt(5.0) - 1.0) / 2.0;
    double a = MbtSearchMinDeg, b = MbtSearchMaxDeg;
    double c = b - ratio * (b - a), d = a + ratio * (b - a);
    double fc = torque(c), fd = torque(d);
    for (int i = 2; i < MbtSearchEvaluations; ++i) {
        if (fc > fd) { b = d; d = c; fd = fc; c = b - ratio * (b - a); fc = torque(c); }
        else { a = c; c = d; fc = fd; d = a + ratio * (b - a); fd = torque(d); }
    }
    return fc > fd ? c : d;
}

double interpolate(const std::vector<std::pair<double, double>> &table, double x) {
    if (x <= table.front().first) return table.front().second;
    for (std::size_t i = 1; i < table.size(); ++i) {
        if (x <= table[i].first) {
            const double t = (x - table[i - 1].first) / (table[i].first - table[i - 1].first);
            return table[i - 1].second + t * (table[i].second - table[i - 1].second);
        }
    }
    return table.back().second;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        std::cerr << "usage: motor_town_engine_sim_dyno SCRIPT.mr OUTPUT_DIR [RPM_STEP] [find-mbt]\n";
        return 2;
    }
    const std::filesystem::path outputDir = argv[2];
    const double rpmStep = argc > 3 ? std::stod(argv[3]) : 500.0;
    const bool findMbt = argc > 4 && std::string(argv[4]) == "find-mbt";
    g_boost = mtes::read_full_load_boost(argv[1]);
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
    simulator->synthesizer().setAudioParameters(audio);
    mtes::use_real_spec_sound(simulator);
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
    std::vector<std::pair<double, double>> mbt;
    if (findMbt) {
        for (double rpm = 1000.0; rpm < redlineRpm + 999.0; rpm += 1000.0) {
            const double at = std::min(rpm, redlineRpm);
            mbt.emplace_back(at, find_mbt_deg(simulator, engine, at));
            std::cout << "MBT " << at << " rpm: " << mbt.back().second << " deg\n";
        }
    }
    std::vector<DynoPoint> points;
    for (double rpm = 1000.0; rpm <= redlineRpm + 1.0; rpm += rpmStep) {
        const double speed = units::rpm(rpm);
        Function *timing = engine->getIgnitionModule()->getTimingCurve();
        timing->setOutputScale(1.0);
        const double advance = mbt.empty()
            ? timing->sampleTriangle(speed) / units::angle(1.0, units::deg)
            : interpolate(mbt, rpm);
        std::vector<std::int16_t> pcm;
        const double torque = hold_torque_nm(simulator, engine, rpm, advance, SettleSeconds, MeasureSeconds, &pcm);

        double squares = 0.0, peak = 0.0;
        std::size_t clipped = 0;
        for (const auto s : pcm) {
            squares += double(s) * s;
            peak = std::max(peak, std::abs(double(s)));
            clipped += std::abs(int(s)) >= 32767;
        }
        const double rms = pcm.empty() ? 0.0 : std::sqrt(squares / pcm.size());
        points.push_back({rpm, advance, torque, torque * speed / 745.7,
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
        json << (i ? ", " : "") << "{\"rpm\": " << p.rpm << ", \"spark_advance_deg\": " << p.sparkAdvanceDeg
             << ", \"torque_nm\": " << p.torqueNm
             << ", \"power_hp\": " << p.powerHp << ", \"rms_dbfs\": " << p.rmsDbfs
             << ", \"peak_dbfs\": " << p.peakDbfs << ", \"clipped_fraction\": " << p.clippedFraction << "}";
    }
    json << "], \"mbt_spark_advance\": [";
    for (std::size_t i = 0; i < mbt.size(); ++i)
        json << (i ? ", " : "") << "[" << mbt[i].first << ", " << mbt[i].second << "]";
    json << "]}\n";
    simulator->releaseSimulation();
    return 0;
}
