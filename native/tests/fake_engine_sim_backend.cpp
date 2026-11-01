#include "engine_sim_backend.h"

#include <memory>

namespace mtes {
namespace {
class FakeBackend final : public EngineBackend {
public:
    bool load(const std::string&) override { return false; }
    bool advance(double, double, double, int) override { return false; }
    std::size_t read(std::int16_t*, std::size_t) override { return 0; }
    void stop() noexcept override {}
};
}
std::unique_ptr<EngineBackend> make_engine_sim_backend() {
    return std::make_unique<FakeBackend>();
}
}
