// SHA-256 (FIPS 180-4), for the updater to check a download against the
// digest GitHub publishes with each release asset — as macOS checks with
// CryptoKit and Windows with its own. Here so as not to need a crypto
// library the tarball would have to find on every distro.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace imejd {

class Sha256 {
public:
    Sha256();

    void update(const void *data, size_t size);
    void update(std::string_view data) { update(data.data(), data.size()); }

    /// The digest of everything given, in lowercase hex. The hasher is spent
    /// afterwards.
    std::string hexDigest();

private:
    void compress(const uint8_t *block);

    uint32_t state_[8];
    uint64_t length_ = 0;
    uint8_t buffer_[64];
    size_t buffered_ = 0;
};

} // namespace imejd
