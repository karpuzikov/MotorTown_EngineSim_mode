// Windows-only integration smoke test against the *actual* engine-sim library.
// This executable is never installed with the mod.
#include "engine_audio.h"
#include "engine_sim_backend.h"

#include <array>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <string>
#include <thread>

int main(int argc, char **argv) {
    if (argc < 2) {
        std::cerr << "Expected one or more absolute Engine Simulator .mr profile paths\n";
        return 2;
    }
    mtes::EngineAudio audio(mtes::make_engine_sim_backend());
    std::array<std::int16_t, 882> pcm{};
    for (int profile = 1; profile < argc; ++profile) {
        // The same backend must release and reload the real physical model
        // when Motor Town changes vehicles; no second process is launched.
        const auto start = std::chrono::steady_clock::now();
        std::size_t audible = 0;
        for (int frame = 0; frame < 120; ++frame) {
            const auto now = start + std::chrono::milliseconds(frame * 20);
            if (!audio.update("native-test-vehicle-" + std::to_string(profile),
                              argv[profile], {2400.0, 0.7, 2, true}, now)) {
                std::cerr << "Failed to load or advance " << argv[profile] << "\n";
                return 3;
            }
            const auto read = audio.render(pcm.data(), pcm.size(), now);
            for (std::size_t i = 0; i < read; ++i) {
                if (pcm[i] != 0) ++audible;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        std::cout << argv[profile] << " audible PCM samples: " << audible << "\n";
        if (audible < 100) return 4;

        // Reproduce the *real* in-game consumer. The old synth rendering
        // thread capped its ring buffer at 2000 frames, so an otherwise
        // healthy 882-frame desktop smoke passed while every 2205-frame
        // Motor Town packet failed open with a permanent underrun.
        std::array<std::int16_t, 2205> gamePcm{};
        int completeGamePackets = 0;
        for (int frame = 0; frame < 80; ++frame) {
            const auto now = start + std::chrono::milliseconds(2400 + frame * 50);
            if (!audio.update("native-test-vehicle-" + std::to_string(profile),
                              argv[profile], {2400.0, 0.7, 2, true}, now)) {
                std::cerr << "Failed to advance Motor Town-size PCM packet\n";
                return 6;
            }
            if (audio.render(gamePcm.data(), gamePcm.size(), now) == gamePcm.size() &&
                std::any_of(gamePcm.begin(), gamePcm.end(),
                    [](std::int16_t sample) { return sample != 0; })) {
                ++completeGamePackets;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        std::cout << argv[profile] << " complete Motor Town PCM packets: "
                  << completeGamePackets << "\n";
        if (completeGamePackets < 5) return 7;

        // A requested 50-ms Lua timer may run every ~67 ms when the game
        // thread misses the nominal deadline. Verify genuine synthesis also
        // sustains a 2955-frame block instead of passing only fake backends.
        std::array<std::int16_t, 2955> slowGamePcm{};
        int completeSlowGamePackets = 0;
        for (int frame = 0; frame < 80; ++frame) {
            const auto now = start + std::chrono::milliseconds(6400 + frame * 67);
            if (!audio.update("native-test-vehicle-" + std::to_string(profile),
                              argv[profile], {2400.0, 0.7, 2, true}, now)) {
                std::cerr << "Failed to advance slow-game PCM packet\n";
                return 8;
            }
            if (audio.render(slowGamePcm.data(), slowGamePcm.size(), now) ==
                    slowGamePcm.size() &&
                std::any_of(slowGamePcm.begin(), slowGamePcm.end(),
                    [](std::int16_t sample) { return sample != 0; })) {
                ++completeSlowGamePackets;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        std::cout << argv[profile] << " complete slow-game PCM packets: "
                  << completeSlowGamePackets << "\n";
        if (completeSlowGamePackets < 5) return 9;

        // In-game frames occasionally take ~150 ms. Run this phase on a
        // real wall clock (not synthetic 150-ms timestamps with 2-ms sleeps)
        // so the genuine asynchronous synthesizer has the same production
        // and consumption cadence as a slow game frame. Its 8192-frame
        // render batch must supply each complete 6615-frame PCM packet.
        audio.stop();
        const auto delayedVehicle =
            "native-delayed-vehicle-" + std::to_string(profile);
        if (!audio.update(delayedVehicle, argv[profile],
                          {2400.0, 0.7, 2, true}, std::chrono::steady_clock::now())) {
            std::cerr << "Failed to prime delayed-game engine\n";
            return 10;
        }
        std::array<std::int16_t, 6615> delayedGamePcm{};
        int completeDelayedGamePackets = 0;
        // A fresh upstream Synthesizer starts with roughly one second of
        // silent PCM already in its 44.1-kHz output ring. Consume it at the
        // same real-time cadence before measuring sustained engine audio.
        constexpr int WarmupPackets = 10;
        auto nextPacketAt = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(150);
        std::this_thread::sleep_until(nextPacketAt);
        for (int frame = -WarmupPackets; frame < 40; ++frame) {
            const auto now = std::chrono::steady_clock::now();
            if (!audio.update(delayedVehicle,
                              argv[profile], {2400.0, 0.7, 2, true}, now)) {
                std::cerr << "Failed to advance delayed-game PCM packet\n";
                return 10;
            }
            if (audio.render(delayedGamePcm.data(), delayedGamePcm.size(), now) ==
                    delayedGamePcm.size() &&
                std::any_of(delayedGamePcm.begin(), delayedGamePcm.end(),
                    [](std::int16_t sample) { return sample != 0; }) && frame >= 0) {
                ++completeDelayedGamePackets;
            }
            nextPacketAt += std::chrono::milliseconds(150);
            std::this_thread::sleep_until(nextPacketAt);
        }
        std::cout << argv[profile] << " complete delayed-game PCM packets: "
                  << completeDelayedGamePackets << "\n";
        // After the explicit warmup, more than four losses over six seconds
        // would audibly stutter in-game.
        if (completeDelayedGamePackets < 36) return 11;

        // Exercise the hardest bounded case too: an ~186-ms frame requests
        // exactly 8192 frames, the maximum native PCM packet and one full
        // patched synthesizer batch. The 150-ms test alone misses this edge.
        std::array<std::int16_t, 8192> maxGamePcm{};
        int completeMaxGamePackets = 0;
        auto nextMaxPacketAt = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(186);
        std::this_thread::sleep_until(nextMaxPacketAt);
        for (int frame = -4; frame < 20; ++frame) {
            const auto now = std::chrono::steady_clock::now();
            if (!audio.update(delayedVehicle, argv[profile],
                              {2400.0, 0.7, 2, true}, now)) {
                std::cerr << "Failed to advance maximum PCM packet\n";
                return 12;
            }
            if (audio.render(maxGamePcm.data(), maxGamePcm.size(), now) ==
                    maxGamePcm.size() &&
                std::any_of(maxGamePcm.begin(), maxGamePcm.end(),
                    [](std::int16_t sample) { return sample != 0; }) && frame >= 0) {
                ++completeMaxGamePackets;
            }
            nextMaxPacketAt += std::chrono::milliseconds(186);
            std::this_thread::sleep_until(nextMaxPacketAt);
        }
        std::cout << argv[profile] << " complete maximum-size PCM packets: "
                  << completeMaxGamePackets << "\n";
        if (completeMaxGamePackets < 18) return 13;
    }
    audio.stop();
    if (audio.is_replacing_stock()) return 5;
    return 0;
}
