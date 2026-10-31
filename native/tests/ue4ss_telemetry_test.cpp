#include <Mod/CppUserModBase.hpp>
#include <DynamicOutput/DynamicOutput.hpp>

#include <cassert>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <thread>
#include <vector>

extern "C" RC::CppUserModBase* start_mod();
extern "C" void uninstall_mod(RC::CppUserModBase*);

std::vector<int> RC::observed_gears;

int main() {
    auto* mod = start_mod();
    assert(mod);
    mod->on_unreal_init();
    const auto dir = std::filesystem::path(std::getenv("TMP"));
    const auto file = dir / "MotorTownEngineSim_native_telemetry.txt";
    auto write = [&](const char* packet) {
        std::ofstream out(file);
        out << packet;
    };
    write("MTES2 AABBCCDDEEFF0011 1 2400 0.25 1 3 54757363616E5F43 -1 0.0\n");
    mod->on_update();
    assert((RC::observed_gears == std::vector<int>{3}));
    mod->on_update();
    assert(RC::observed_gears.size() == 1);

    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    write("MTES2 AABBCCDDEEFF0011 2 2500 0.50 1 4 54757363616E5F43 -1 0.0\n");
    mod->on_update();
    assert((RC::observed_gears == std::vector<int>{3, 4}));
    uninstall_mod(mod);
}
