#include "lua_mute_lease.h"

#include <chrono>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <utility>

#ifdef _WIN32
#include <Windows.h>
#endif

namespace mtes {
namespace {

std::string hex(std::string_view input) {
    constexpr char alphabet[] = "0123456789ABCDEF";
    std::string encoded;
    encoded.reserve(input.size() * 2);
    for (unsigned char c : input) {
        encoded.push_back(alphabet[c >> 4]);
        encoded.push_back(alphabet[c & 15]);
    }
    return encoded;
}

bool write_command(const std::filesystem::path& path, const std::string& value) {
    // The Lua game thread may read this request while the native worker is
    // writing it. Truncating the published file would expose empty/partial
    // commands, counting as spurious watchdog idle ticks.
    auto pending = path;
    pending += ".mtes-pending";
    {
        std::ofstream output(pending, std::ios::binary | std::ios::trunc);
        output << value << '\n';
        output.flush();
        if (!output.good()) return false;
    }
#ifdef _WIN32
    // Windows std::filesystem::rename replacement may fail if the target
    // exists; MoveFileExW is the atomic replacement primitive. An open Lua
    // reader may briefly deny deletion, so retry without blocking Unreal.
    for (int attempt = 0; attempt < 3; ++attempt) {
        if (MoveFileExW(pending.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING))
            return true;
        if (attempt < 2) Sleep(1);
    }
    return false;
#else
    std::error_code error;
    std::filesystem::rename(pending, path, error);
    return !error;
#endif
}

} // namespace

LuaMuteLeaseEmitter::LuaMuteLeaseEmitter(std::filesystem::path temp,
    std::string session, std::string vehicle, std::string asset)
    : m_request(temp / "MotorTownEngineSim_native_mute_request.txt"),
      m_ack(temp / "MotorTownEngineSim_native_mute_ack.txt"),
      m_diagnostics(temp / "MotorTownEngineSim_mute_diagnostics.txt"),
      m_session(std::move(session)), m_vehicleHex(hex(vehicle)),
      m_assetHex(hex(asset)) {
    const auto unique = std::chrono::steady_clock::now().time_since_epoch().count();
    std::ostringstream token;
    token << std::uppercase << std::hex << static_cast<std::uint64_t>(unique);
    m_token = token.str();
}

void LuaMuteLeaseEmitter::advance(std::uint64_t sequence) noexcept {
    m_sequence = sequence;
    m_prepared = false;
}

void LuaMuteLeaseEmitter::report_lost_ack(
    std::string_view reason, std::int64_t ageMs) noexcept {
    // Only record transitions from a *confirmed* lease: initial ACK delay
    // is normal. Avoid writing the response's session/token/vehicle to disk.
    if (!m_hadConfirmedAck) return;
    m_hadConfirmedAck = false;
    m_inGrace = false;
    try {
        std::ofstream out(m_diagnostics, std::ios::app);
        const auto utcMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
        if (out) out << "utc_ms=" << utcMs << " seq=" << m_sequence
                     << " reason=" << reason << " ack_age_ms=" << ageMs << '\n';
    } catch (...) { /* Diagnostics must not affect the fail-open path. */ }
}

// In-game (2026-11-01, Dory Wrecker) every lost ACK stopped the replacement,
// restored stock audio and re-leased: an audible stutter every few seconds.
// Lua rewrites the ACK in place (a read can land mid-write) and a game hitch
// delays its next ACK. Neither means Lua restored stock audio: Lua always
// writes MTESA0 BEFORE restoring a gain, and refuses to restore if it cannot.
// So a confirmed lease rides out such transient problems for a bounded time;
// MTESA0 and identity changes still stop playback at once.
bool LuaMuteLeaseEmitter::transient_failure(
    std::string_view reason, std::int64_t ageMs) noexcept {
    if (m_hadConfirmedAck &&
        std::chrono::steady_clock::now() - m_lastConfirmed < m_grace) {
        if (!m_inGrace) {
            m_inGrace = true;
            try {
                std::ofstream out(m_diagnostics, std::ios::app);
                const auto utcMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::system_clock::now().time_since_epoch()).count();
                if (out) out << "utc_ms=" << utcMs << " seq=" << m_sequence
                             << " reason=" << reason << " ack_age_ms=" << ageMs
                             << " grace=1\n";
            } catch (...) {}
        }
        m_prepared = true;
        return true;
    }
    report_lost_ack(reason, ageMs);
    return false;
}

bool LuaMuteLeaseEmitter::prepare() {
    m_prepared = false;
    if (m_sequence == 0 || m_session.size() != 16 || m_vehicleHex.empty() ||
        m_assetHex.empty() || m_request.empty() || m_ack.empty()) {
        report_lost_ack("invalid_identity");
        return false;
    }
    if (!write_command(m_request, "MTESM1 " + m_session + " " +
        std::to_string(m_sequence) + " " + m_token + " " + m_vehicleHex +
        " " + m_assetHex)) {
        return transient_failure("request_write_failed");
    }
    m_requested = true;

    // A previous game launch or old session may leave a matching-looking
    // response on disk; the ACK must be recent AND tied to this mute token.
    std::error_code error;
    const auto changed = std::filesystem::last_write_time(m_ack, error);
    if (error) return transient_failure("ack_stat_failed");
    const auto age = decltype(changed)::clock::now() - changed;
    // A slow frame can take 150-185 ms between Lua updates.
    constexpr auto MaxAckAge = std::chrono::milliseconds(190);
    if (age < -MaxAckAge || age > MaxAckAge) {
        return transient_failure("ack_age_expired",
            std::chrono::duration_cast<std::chrono::milliseconds>(age).count());
    }
    std::ifstream response(m_ack, std::ios::binary);
    std::string tag, session, number, token, vehicle, asset, extra;
    if (!(response >> tag)) return transient_failure("ack_malformed");
    if (tag == "MTESA0") {
        report_lost_ack("ack_revoked");
        return false;
    }
    if (!(response >> session >> number >> token >> vehicle >> asset) ||
        (response >> extra)) {
        return transient_failure("ack_malformed");
    }
    if (tag != "MTESA1" || session != m_session || token != m_token ||
        vehicle != m_vehicleHex || asset != m_assetHex) {
        report_lost_ack("ack_identity_mismatch");
        return false;
    }
    if (number.empty() || number.size() > 20 ||
        number.find_first_not_of("0123456789") != std::string::npos) {
        return transient_failure("ack_malformed");
    }
    std::uint64_t acknowledged = 0;
    try { acknowledged = std::stoull(number); }
    catch (...) { return transient_failure("ack_malformed"); }
    // Liveness is the 190-ms ACK age; the sequence only rejects replays.
    // In game (Dory Wrecker) Lua routinely trailed by 3-6 packets: the
    // old limit of 2 dropped the sound in and out every ~2 s.
    if (acknowledged > m_sequence || m_sequence - acknowledged > MaxAckLag) {
        return transient_failure("ack_sequence_gap");
    }
    m_prepared = true;
    m_hadConfirmedAck = true;
    m_inGrace = false;
    m_lastConfirmed = std::chrono::steady_clock::now();
    return true;
}

bool LuaMuteLeaseEmitter::mute() {
    return m_prepared; // Lua already checked and muted the exact stock cue.
}

bool LuaMuteLeaseEmitter::restore() noexcept {
    m_prepared = false;
    if (!m_requested) return true;
    try {
        const bool written = write_command(m_request, "MTESM0 " + m_session +
            " " + m_token);
        if (written) {
            m_requested = false;
            m_hadConfirmedAck = false;
            m_inGrace = false;
            // A new handoff may not replay an ACK from before this STOP.
            m_token += "A";
        }
        return written;
    }
    catch (...) { return false; }
}

LuaMuteLeaseLookup::LuaMuteLeaseLookup(std::filesystem::path temp)
    : m_temp(std::move(temp)) {}

void LuaMuteLeaseLookup::cancel() noexcept {
    if (m_current) (void)m_current->restore();
}

std::shared_ptr<StockEngineEmitter> LuaMuteLeaseLookup::stock_for(
    const GameTelemetrySample& sample) {
    if (sample.session.size() != 16 || sample.sequence == 0 ||
        sample.vehicle.empty() || sample.engine_asset.empty() || m_temp.empty())
        return {};
    if (!m_current || m_session != sample.session ||
        m_vehicle != sample.vehicle || m_asset != sample.engine_asset) {
        if (m_current && !m_current->restore()) return {};
        m_current = std::make_shared<LuaMuteLeaseEmitter>(
            m_temp, sample.session, sample.vehicle, sample.engine_asset);
        m_session = sample.session;
        m_vehicle = sample.vehicle;
        m_asset = sample.engine_asset;
    }
    m_current->advance(sample.sequence);
    return m_current;
}

} // namespace mtes
