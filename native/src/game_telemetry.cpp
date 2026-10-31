#include "game_telemetry.h"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <fstream>
#include <locale>
#include <sstream>

namespace mtes {
namespace {
constexpr auto MaxAge = std::chrono::milliseconds(250);

int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

std::optional<std::string> decode_vehicle(const std::string &hex) {
    if (hex.empty() || hex.size() > 1024 || hex.size() % 2 != 0) return std::nullopt;
    std::string vehicle;
    vehicle.reserve(hex.size() / 2);
    for (std::size_t i = 0; i < hex.size(); i += 2) {
        const int hi = nibble(hex[i]);
        const int lo = nibble(hex[i + 1]);
        if (hi < 0 || lo < 0) return std::nullopt;
        const auto c = static_cast<char>((hi << 4) | lo);
        if (c == '\0' || c == '\r' || c == '\n') return std::nullopt;
        vehicle.push_back(c);
    }
    return vehicle;
}
} // namespace

std::optional<GameTelemetrySample> parse_game_telemetry(std::string_view line) {
    if (line.size() > 1200) return std::nullopt;
    std::istringstream input{std::string(line)};
    input.imbue(std::locale::classic());
    std::string header, session, sequenceText, vehicleHex, extra;
    GameTelemetrySample sample;
    int ignition = -1;
    if (!(input >> header >> session >> sequenceText >> sample.state.rpm >>
        sample.state.throttle >> ignition >> sample.state.gear >> vehicleHex >>
        sample.engine_type >> sample.max_rpm) || (input >> extra)) return std::nullopt;
    // Extraction into uint64_t accepts a minus sign on some standard
    // implementations, turning -1 into UINT64_MAX and poisoning the feed.
    if (session.size() != 16 ||
        !std::all_of(session.begin(), session.end(), [](char c) { return nibble(c) >= 0; }) ||
        sequenceText.empty() ||
        !std::all_of(sequenceText.begin(), sequenceText.end(),
            [](char c) { return c >= '0' && c <= '9'; })) return std::nullopt;
    const auto [end, error] = std::from_chars(sequenceText.data(),
        sequenceText.data() + sequenceText.size(), sample.sequence);
    if (error != std::errc{} || end != sequenceText.data() + sequenceText.size())
        return std::nullopt;
    const auto vehicle = decode_vehicle(vehicleHex);
    if (header != "MTES2" || sample.sequence == 0 || !vehicle ||
        !std::isfinite(sample.state.rpm) || sample.state.rpm < 0 ||
        sample.state.rpm > 25000 || !std::isfinite(sample.state.throttle) ||
        sample.state.throttle < 0 || sample.state.throttle > 1 ||
        (ignition != 0 && ignition != 1) ||
        sample.state.gear < -2 || sample.state.gear > 32 ||
        sample.engine_type < -1 || sample.engine_type > 1000 ||
        !std::isfinite(sample.max_rpm) || sample.max_rpm < 0 ||
        sample.max_rpm > 25000) return std::nullopt;
    sample.state.ignition = ignition == 1;
    sample.session = std::move(session);
    sample.vehicle = std::move(*vehicle);
    return sample;
}

bool GameTelemetryFeed::accept(std::string_view line, Clock::time_point received) {
    auto sample = parse_game_telemetry(line);
    if (!sample || (m_latest && sample->session == m_latest->session &&
        sample->sequence <= m_latest->sequence)) return false;
    m_latest = std::move(sample);
    m_received = received;
    return true;
}

std::optional<GameTelemetrySample> GameTelemetryFeed::current(Clock::time_point now) const {
    if (!m_latest || now < m_received || now - m_received > MaxAge) return std::nullopt;
    return m_latest;
}

GameTelemetryReader::GameTelemetryReader(std::filesystem::path file)
    : m_file(std::move(file)) {}

void GameTelemetryReader::poll(GameTelemetryFeed::Clock::time_point now) {
    if (m_lastPoll && now >= *m_lastPoll && now - *m_lastPoll <
        std::chrono::milliseconds(50)) return;
    m_lastPoll = now;
    if (m_file.empty()) return;
    // A valid packet from an earlier game launch must not become "fresh"
    // simply because the DLL has just started reading the old temp file.
    std::error_code error;
    const auto modified = std::filesystem::last_write_time(m_file, error);
    if (error) return;
    const auto age = decltype(modified)::clock::now() - modified;
    if (age < -std::chrono::milliseconds(500) ||
        age > std::chrono::milliseconds(500)) return;
    std::ifstream file(m_file);
    std::string line;
    // An older file does not gain a new 250-ms lifetime just because the
    // consumer noticed it late. Carry the producer write age into steady time.
    const auto sourceAge = std::chrono::duration_cast<GameTelemetryFeed::Clock::duration>(
        std::max(age, decltype(age)::zero()));
    if (std::getline(file, line)) m_feed.accept(line, now - sourceAge);
}

std::optional<GameTelemetrySample> GameTelemetryReader::current(
    GameTelemetryFeed::Clock::time_point now) const {
    return m_feed.current(now);
}

} // namespace mtes
