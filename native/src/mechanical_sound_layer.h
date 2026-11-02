#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace mtes {

// Tones Engine Simulator cannot make: a Roots blower's whine and a turbo's
// whistle. Measured on a real Detroit Diesel two-stroke coach (MCI MC-9,
// 2026-11-02): whine lines locked to crank orders ~88, ~176 and ~225, 7-10 dB
// over the noise around them. The coach's broadband brightness comes from
// its exhaust curve (make_exhausts.py "detroit"), so it pulses with every
// firing (as static noise here it sounded like noise in game).
struct MechanicalSoundPreset {
    struct Tone { double crankOrder; double levelDb; }; // dB re the exhaust's level
    std::vector<Tone> tones;          // follow engine speed
    double fixedToneHz = 0;           // e.g. turbo whistle; 0 = none
    double fixedToneLevelDb = -120;
};

inline std::optional<MechanicalSoundPreset> mechanical_sound_preset(const std::string& name) {
    if (name == "detroit_two_stroke") {
        MechanicalSoundPreset preset;
        // Tuned with the "bus_detroit" exhaust: the lines stand out as much
        // as on the real coach at idle.
        // shortcut: the recording has no usable revs, so the whine keeps its
        // idle balance to the exhaust at every RPM; tune from a high-RPM one.
        preset.tones = {{88.0, -17.0}, {176.0, -17.0}, {225.0, -17.0}};
        preset.fixedToneHz = 11300;
        preset.fixedToneLevelDb = -50;
        return preset;
    }
    return std::nullopt;
}

class MechanicalSoundLayer final {
public:
    explicit MechanicalSoundLayer(MechanicalSoundPreset preset, double sampleRate = 44100.0)
        : m_preset(std::move(preset)), m_sampleRate(sampleRate) {
        m_tonePhases.assign(m_preset.tones.size(), 0.0);
    }

    // referenceLevel: linear RMS the dB levels are relative to.
    void add_to(std::int16_t* pcm, std::size_t frames, double rpm, double referenceLevel) {
        if (!(rpm > 0)) return;
        std::vector<double> toneAmp(m_preset.tones.size()), toneStep(m_preset.tones.size());
        for (std::size_t t = 0; t < m_preset.tones.size(); ++t) {
            const double hz = m_preset.tones[t].crankOrder * rpm / 60.0;
            toneStep[t] = 2 * Pi * hz / m_sampleRate;
            toneAmp[t] = hz < 0.45 * m_sampleRate
                ? referenceLevel * std::sqrt(2.0) * std::pow(10.0, m_preset.tones[t].levelDb / 20.0) : 0.0;
        }
        const double fixedAmp = m_preset.fixedToneHz > 0 && m_preset.fixedToneHz < 0.45 * m_sampleRate
            ? referenceLevel * std::sqrt(2.0) * std::pow(10.0, m_preset.fixedToneLevelDb / 20.0) : 0.0;
        const double fixedStep = 2 * Pi * m_preset.fixedToneHz / m_sampleRate;
        for (std::size_t i = 0; i < frames; ++i) {
            double sum = 0;
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
    MechanicalSoundPreset m_preset;
    double m_sampleRate;
    std::vector<double> m_tonePhases;
    double m_fixedPhase = 0;
};

} // namespace mtes
