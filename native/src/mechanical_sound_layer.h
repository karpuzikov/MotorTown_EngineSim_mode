#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <random>
#include <string>
#include <vector>

namespace mtes {

// Sound Engine Simulator cannot make: a Roots blower's whine, gear and
// injector clatter, a turbo's whistle - everything that is not exhaust gas.
// Measured on a real Detroit Diesel two-stroke coach (MCI MC-9, 2026-11-02):
// above 250 Hz it is 8-17 dB LOUDER than the exhaust's 125 Hz octave, with
// whine lines locked to crank orders ~88 and ~225 and a ~11 kHz turbo line.
// In game the simulated exhaust alone was 30-50 dB down there: "a muffled
// sports car".
struct MechanicalSoundPreset {
    // Noise level per octave band (63 Hz .. 8 kHz), dB relative to the
    // engine's own level, at idle.
    std::array<double, 8> octaveLevelsDb{};
    struct Tone { double crankOrder; double levelDb; };
    std::vector<Tone> tones;          // follow engine speed
    double fixedToneHz = 0;           // e.g. turbo whistle; 0 = none
    double fixedToneLevelDb = -120;
    double dbPerSpeedDoubling = 3.0;  // rises with RPM
    double fullLoadDb = 2.0;          // and with load
};

inline std::optional<MechanicalSoundPreset> mechanical_sound_preset(const std::string& name) {
    if (name == "detroit_two_stroke") {
        MechanicalSoundPreset preset;
        // Matched octave by octave to the real coach at idle; relative to the
        // exhaust it fades as RPM rises (the exhaust grows faster).
        preset.octaveLevelsDb = {-60, -40, 0, 9, 8, 16, 10, 0};
        preset.tones = {{88.0, 1.0}, {176.0, -7.0}, {225.0, 3.0}};
        preset.fixedToneHz = 11300;
        preset.fixedToneLevelDb = -16;
        preset.dbPerSpeedDoubling = -5.0;
        preset.fullLoadDb = 0.0;
        return preset;
    }
    return std::nullopt;
}

class MechanicalSoundLayer final {
public:
    explicit MechanicalSoundLayer(MechanicalSoundPreset preset, double sampleRate = 44100.0)
        : m_preset(std::move(preset)), m_sampleRate(sampleRate) {
        for (std::size_t band = 0; band < m_bands.size(); ++band)
            m_bands[band].design(63.0 * std::pow(2.0, double(band)), sampleRate);
        m_tonePhases.assign(m_preset.tones.size(), 0.0);
    }

    // referenceLevel: linear RMS the dB levels are relative to.
    void add_to(std::int16_t* pcm, std::size_t frames, double rpm, double load,
        double idleRpm, double referenceLevel) {
        if (!(rpm > 0) || !(idleRpm > 0)) return;
        const double rise = m_preset.dbPerSpeedDoubling * std::log2(std::max(rpm, idleRpm) / idleRpm) +
            m_preset.fullLoadDb * std::clamp(load, 0.0, 1.0);
        std::array<double, 8> bandGain{};
        for (std::size_t b = 0; b < bandGain.size(); ++b)
            bandGain[b] = referenceLevel * std::pow(10.0, (m_preset.octaveLevelsDb[b] + rise) / 20.0) *
                m_bands[b].unitNoiseCorrection;
        std::vector<double> toneAmp(m_preset.tones.size()), toneStep(m_preset.tones.size());
        for (std::size_t t = 0; t < m_preset.tones.size(); ++t) {
            const double hz = m_preset.tones[t].crankOrder * rpm / 60.0;
            toneStep[t] = 2 * Pi * hz / m_sampleRate;
            toneAmp[t] = hz < 0.45 * m_sampleRate
                ? referenceLevel * std::sqrt(2.0) * std::pow(10.0, (m_preset.tones[t].levelDb + rise) / 20.0) : 0.0;
        }
        const double fixedAmp = m_preset.fixedToneHz > 0 && m_preset.fixedToneHz < 0.45 * m_sampleRate
            ? referenceLevel * std::sqrt(2.0) * std::pow(10.0, (m_preset.fixedToneLevelDb + rise) / 20.0) : 0.0;
        const double fixedStep = 2 * Pi * m_preset.fixedToneHz / m_sampleRate;
        for (std::size_t i = 0; i < frames; ++i) {
            double sum = 0;
            const double white = m_noise(m_random);
            for (std::size_t b = 0; b < m_bands.size(); ++b) sum += bandGain[b] * m_bands[b].process(white);
            for (std::size_t t = 0; t < toneAmp.size(); ++t) {
                m_tonePhases[t] = std::fmod(m_tonePhases[t] + toneStep[t], 2 * Pi);
                sum += toneAmp[t] * std::sin(m_tonePhases[t]);
            }
            m_fixedPhase = std::fmod(m_fixedPhase + fixedStep, 2 * Pi);
            sum += fixedAmp * std::sin(m_fixedPhase);
            const double mixed = pcm[i] + sum * 32767.0;
            pcm[i] = static_cast<std::int16_t>(std::clamp(mixed, -32768.0, 32767.0));
        }
    }

private:
    static constexpr double Pi = 3.14159265358979323846;
    struct OctaveBand { // RBJ band-pass, one octave wide, 0 dB peak
        double b0 = 0, b2 = 0, a1 = 0, a2 = 0, x1 = 0, x2 = 0, y1 = 0, y2 = 0;
        double unitNoiseCorrection = 1; // unit-variance noise -> unit RMS in band
        void design(double centreHz, double sampleRate) {
            const double w = 2 * Pi * std::min(centreHz, 0.45 * sampleRate) / sampleRate;
            const double alpha = std::sin(w) * std::sinh(std::log(2.0) / 2 * 1.0 * w / std::sin(w));
            const double a0 = 1 + alpha;
            b0 = alpha / a0; b2 = -alpha / a0; a1 = -2 * std::cos(w) / a0; a2 = (1 - alpha) / a0;
            // Noise power through a band-pass ~ its bandwidth / Nyquist.
            const double bandwidthHz = centreHz / std::sqrt(2.0);
            unitNoiseCorrection = std::sqrt((sampleRate / 2) / bandwidthHz);
        }
        double process(double x) {
            const double y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1; x1 = x; y2 = y1; y1 = y;
            return y;
        }
    };
    MechanicalSoundPreset m_preset;
    double m_sampleRate;
    std::array<OctaveBand, 8> m_bands{};
    std::vector<double> m_tonePhases;
    double m_fixedPhase = 0;
    std::mt19937 m_random{0x424c4f57u};
    std::normal_distribution<double> m_noise{0.0, 1.0};
};

} // namespace mtes
