#include "impulse_wav.h"

#include <algorithm>
#include <fstream>
#include <iterator>

namespace mtes {
namespace {
constexpr std::size_t MaxBytes = 16 * 1024 * 1024;

std::uint16_t u16(const std::vector<std::uint8_t> &b, std::size_t i) {
    return static_cast<std::uint16_t>(b[i] | (b[i + 1] << 8));
}
std::uint32_t u32(const std::vector<std::uint8_t> &b, std::size_t i) {
    return static_cast<std::uint32_t>(b[i]) | (std::uint32_t(b[i + 1]) << 8) |
        (std::uint32_t(b[i + 2]) << 16) | (std::uint32_t(b[i + 3]) << 24);
}
bool tag(const std::vector<std::uint8_t> &b, std::size_t i, const char *name) {
    return std::equal(name, name + 4, b.begin() + static_cast<std::ptrdiff_t>(i));
}
} // namespace

std::filesystem::path impulse_wav_path(const std::string &script,
    const std::string &filename) {
    if (script.empty() || filename.empty()) return {};
    const std::filesystem::path file(filename);
    if (file.is_absolute()) return file;
    return std::filesystem::path(script).parent_path() / "sound-library" / file;
}

std::vector<std::int16_t> parse_impulse_wav(const std::vector<std::uint8_t> &bytes) {
    if (bytes.size() < 44 || bytes.size() > MaxBytes ||
        !tag(bytes, 0, "RIFF") || !tag(bytes, 8, "WAVE")) return {};
    const std::uint64_t end = std::uint64_t(u32(bytes, 4)) + 8;
    if (end > bytes.size() || end < 44) return {};

    std::uint16_t bits = 0;
    std::size_t start = 0, length = 0;
    bool gotFormat = false, gotData = false;
    for (std::size_t pos = 12; pos + 8 <= end;) {
        const std::size_t chunkSize = u32(bytes, pos + 4);
        const std::size_t chunk = pos + 8;
        if (chunkSize > end - chunk) return {};
        if (tag(bytes, pos, "fmt ")) {
            if (chunkSize < 16 || u16(bytes, chunk) != 1 || // uncompressed PCM
                u16(bytes, chunk + 2) != 1 || // mono
                u32(bytes, chunk + 4) != 44100) return {};
            bits = u16(bytes, chunk + 14);
            const std::uint16_t align = bits / 8;
            if ((bits != 16 && bits != 24) ||
                u16(bytes, chunk + 12) != align ||
                u32(bytes, chunk + 8) != 44100U * align) return {};
            gotFormat = true;
        }
        else if (tag(bytes, pos, "data") && !gotData) {
            start = chunk;
            length = chunkSize;
            gotData = true;
        }
        pos = chunk + chunkSize + (chunkSize & 1U);
    }
    if (!gotFormat || !gotData || length == 0 || length % (bits / 8) != 0) return {};

    std::vector<std::int16_t> samples;
    const std::size_t stride = bits / 8;
    samples.reserve(length / stride);
    for (std::size_t i = start; i < start + length; i += stride) {
        std::int32_t value = 0;
        if (bits == 16) {
            const std::uint16_t sample = u16(bytes, i);
            value = sample < 0x8000 ? sample : std::int32_t(sample) - 0x10000;
        }
        else {
            value = std::int32_t(bytes[i]) | (std::int32_t(bytes[i + 1]) << 8) |
                (std::int32_t(bytes[i + 2]) << 16);
            if (value & 0x800000) value -= 0x1000000;
            value >>= 8;
        }
        samples.push_back(static_cast<std::int16_t>(value));
    }
    return samples;
}

std::vector<std::int16_t> load_impulse_wav(const std::string &path) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    const std::streampos size = stream.tellg();
    if (!stream || size < 0 || size > static_cast<std::streamoff>(MaxBytes)) return {};
    stream.seekg(0);
    const std::vector<std::uint8_t> bytes{
        std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    return parse_impulse_wav(bytes);
}

bool usable_impulse_for_engine_sim(const std::vector<std::int16_t> &samples) {
    // The pinned synthesizer trims every sample <=100; a zero-length
    // convolution then divides by zero in its filter loop.
    return std::any_of(samples.begin(), samples.end(), [](std::int16_t sample) {
        return int(sample) < -100 || int(sample) > 100;
    });
}

} // namespace mtes
