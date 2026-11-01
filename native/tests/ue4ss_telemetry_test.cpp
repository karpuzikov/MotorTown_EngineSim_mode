#include <Mod/CppUserModBase.hpp>
#include <DynamicOutput/DynamicOutput.hpp>

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <thread>
#include <vector>

extern "C" RC::CppUserModBase* start_mod();
extern "C" void uninstall_mod(RC::CppUserModBase*);

std::vector<RC::LogRecord> RC::observed_logs;

int main() {
    auto* mod = start_mod();
    assert(mod);
    mod->on_unreal_init();
    const auto count_message = [](const std::wstring& marker) {
        return std::count_if(RC::observed_logs.begin(), RC::observed_logs.end(),
            [&](const RC::LogRecord& log) {
                return log.level == RC::LogLevel::Normal &&
                    log.message.find(marker) != std::wstring::npos;
            });
    };
    assert(count_message(L"Native initialized") == 1);
    // The game log must reveal which diagnostic build is installed.
    assert(count_message(L"Audio v0.4.0 active") == 1);
    const auto dir = std::filesystem::path(std::getenv("TMP"));
    const auto file = dir / "MotorTownEngineSim_native_telemetry.txt";
    auto write = [&](const char* packet) {
        std::ofstream out(file);
        out << packet;
    };
    write("MTES4 AABBCCDDEEFF0011 1 2400 0.25 1 3 54757363616E5F43 -1 0.0 454E47 0\n");
    mod->on_update();
    assert(count_message(L"Native update callback") == 1);
    assert(count_message(L"Native telemetry received") == 1);
    const auto& initial = RC::observed_logs.back();
    assert(initial.level == RC::LogLevel::Normal);
    assert(initial.values.size() == 4);
    assert(initial.values[0] == 3);    // Gear
    assert(initial.values[1] == 2400); // RPM
    assert(initial.values[2] == 0.25); // Throttle
    assert(initial.values[3] == 0);    // Engine volume, not unknown
    mod->on_update();
    assert(count_message(L"Native update callback") == 1);
    assert(count_message(L"Native telemetry received") == 1);

    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    write("MTES4 AABBCCDDEEFF0011 2 2500 0.50 1 4 54757363616E5F43 -1 0.0 454E47 0.7\n");
    mod->on_update();
    assert(count_message(L"Native telemetry received") == 2);
    assert(RC::observed_logs.back().values[0] == 4);
    assert(RC::observed_logs.back().values[3] == 0.7);

    std::this_thread::sleep_for(std::chrono::milliseconds(310));
    mod->on_update();
    mod->on_update();
    assert(count_message(L"Native telemetry lost") == 1);
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    write("MTES4 AABBCCDDEEFF0011 3 2550 0.5 1 4 54757363616E5F43 -1 0.0 454E47 0.7\n");
    mod->on_update();
    assert(count_message(L"Native telemetry received") == 3);
    uninstall_mod(mod);
}
