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

std::optional<std::string> decode_name(const std::string &hex) {
    if (hex.empty() || hex.size() > 1024 || hex.size() % 2 != 0) return std::nullopt;
    std::string vehicle;
    vehicle.reserve(hex.size() / 2);
    for (std::size_t i = 0; i < hex.size(); i += 2) {
        const int hi = nibble(hex[i]);
        const int lo = nibble(hex[i + 1]);
        if (hi < 0 || lo < 0) return std::nullopt;
        const auto c = static_cast<char>((hi << 4) | lo);
        const auto byte = static_cast<unsigned char>(c);
        if (byte < 0x20 || byte == 0x7f) return std::nullopt;
        vehicle.push_back(c);
    }
    return vehicle;
}

std::optional<double> number(const std::string &text) {
    double value = 0;
    const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(),
        value, std::chars_format::general);
    if (error != std::errc{} || end != text.data() + text.size() || !std::isfinite(value))
        return std::nullopt;
    return value;
}
} // namespace

std::optional<GameTelemetrySample> parse_game_telemetry(std::string_view line) {
    if (line.size() > 3600) return std::nullopt;
    std::istringstream input{std::string(line)};
    input.imbue(std::locale::classic());
    std::string header, session, sequenceText, vehicleHex, assetHex, volumeText, extra;
    std::string cueHex, gainText, panText, lowpassText;
    GameTelemetrySample sample;
    int ignition = -1;
    if (!(input >> header >> session >> sequenceText >> sample.state.rpm >>
        sample.state.throttle >> ignition >> sample.state.gear >> vehicleHex >>
        sample.engine_type >> sample.max_rpm)) return std::nullopt;
    if (header == "MTES4" || header == "MTES5") {
        if (!(input >> assetHex >> volumeText)) return std::nullopt;
        const auto volume = number(volumeText);
        if (!volume || (*volume != -1 && (*volume < 0 || *volume > 1)))
            return std::nullopt;
        if (*volume != -1) sample.engine_volume = *volume;
    }
    else if (header == "MTES3") {
        if (!(input >> assetHex)) return std::nullopt;
    }
    else if (header != "MTES2") return std::nullopt;
    if (header == "MTES5") {
        // -1 gain: Lua could not read the stock emitter's attenuation.
        if (!(input >> cueHex >> gainText >> panText >> lowpassText)) return std::nullopt;
        const auto gain = number(gainText);
        const auto pan = number(panText);
        const auto lowpass = number(lowpassText);
        if (!gain || !pan || !lowpass || (*gain != -1 && (*gain < 0 || *gain > 8)) ||
            *pan < -1 || *pan > 1 || (*lowpass != 0 && (*lowpass < 10 || *lowpass > 30000)))
            return std::nullopt;
        if (*gain != -1) sample.mix = SpatialMix{*gain, *pan, *lowpass};
        if (cueHex != "-") {
            const auto cue = decode_name(cueHex);
            if (!cue) return std::nullopt;
            sample.engine_cue = std::move(*cue);
        }
    }
    if (input >> extra) return std::nullopt;
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
    const auto vehicle = decode_name(vehicleHex);
    const auto asset = assetHex.empty() || assetHex == "-"
        ? std::optional<std::string>{std::string{}} : decode_name(assetHex);
    if (sample.sequence == 0 || !vehicle || !asset ||
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
    sample.engine_asset = std::move(*asset);
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
