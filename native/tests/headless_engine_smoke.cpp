// Windows-only integration smoke test against the *actual* engine-sim library.
// This executable is never installed with the mod.
#include "engine_audio.h"
#include "engine_sim_backend.h"

#include <array>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <thread>

int main(int argc, char **argv) {
    if (argc != 2) {
        std::cerr << "Expected absolute Engine Simulator .mr profile path\n";
        return 2;
    }
    mtes::EngineAudio audio(mtes::make_engine_sim_backend());
    const auto start = std::chrono::steady_clock::now();
    std::array<std::int16_t, 882> pcm{};
    std::size_t audible = 0;
    for (int frame = 0; frame < 120; ++frame) {
        const auto now = start + std::chrono::milliseconds(frame * 20);
        if (!audio.update("native-test-vehicle", argv[1],
                          {2400.0, 0.7, 2, true}, now)) {
            std::cerr << "Failed to load or advance engine script\n";
            return 3;
        }
        const auto read = audio.render(pcm.data(), pcm.size(), now);
        for (std::size_t i = 0; i < read; ++i) {
            if (pcm[i] != 0) ++audible;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    std::cout << "Audible PCM samples: " << audible << "\n";
    if (audible < 100) return 4;
    audio.stop();
    if (audio.is_replacing_stock()) return 5;
    return 0;
}
