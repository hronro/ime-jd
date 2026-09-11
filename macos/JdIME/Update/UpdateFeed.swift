// The update feed's data model — pure Foundation, no networking or UI, so it
// is unit-testable (JdIMETests/UpdateFeedTests.swift). UpdateManager does the
// fetching and the presenting.
//
// The feed is GitHub's `releases/latest` endpoint for this repository. Every
// platform frontend that updates itself reads the same feed and applies the
// same rules (windows/src/update/feed.rs, android/.../update/ReleaseFeed.kt):
// compare the release's `MAJOR.MINOR.PATCH` against the running build, and
// pick the asset `.github/workflows/release.yml` names for this platform.

import Foundation

/// A release version, `MAJOR.MINOR.PATCH`, parsed from a Git tag (`v0.6.0`)
/// or a bundle version string (`0.6.0`). A `-prerelease` / `+build` suffix is
/// ignored: the feed only ever reports full releases, and the numeric triple
/// is all that decides whether one build is newer than another.
struct ReleaseVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ text: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.first == "v" || body.first == "V" {
            body = body.dropFirst()
        }
        if let cut = body.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            body = body[..<cut]
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // ASCII digits only: `Int(_:)` would also accept a leading sign.
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    /// `0.0.0` — the placeholder that plain Xcode/IDE builds carry (see
    /// project.yml). Such a build is not a release: it must never be told to
    /// "update", and the automatic check skips it entirely.
    var isPlaceholder: Bool {
        major == 0 && minor == 0 && patch == 0
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// One downloadable file attached to a release.
struct ReleaseAsset: Equatable {
    let name: String
    let url: URL
    let size: Int
    /// Lowercase hex SHA-256 from the API's `digest` field (`sha256:<hex>`),
    /// when GitHub supplied one. The download is checked against it.
    let sha256: String?
}

/// The newest release, as reported by the `releases/latest` endpoint (which
/// excludes drafts and pre-releases).
struct LatestRelease: Equatable {
    /// The Git tag, e.g. `v0.6.0`. Also the version the asset names carry.
    let tag: String
    let version: ReleaseVersion
    /// The human-readable release page (notes + downloads).
    let pageURL: URL
    let assets: [ReleaseAsset]

    /// Decode the endpoint's JSON. Nil when the payload is not a release
    /// with a version tag — a rate-limit error body, say.
    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = ReleaseVersion(tag),
              let page = (object["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        self.tag = tag
        self.version = version
        self.pageURL = page

        let rawAssets = object["assets"] as? [[String: Any]] ?? []
        self.assets = rawAssets.compactMap { raw in
            guard let name = raw["name"] as? String,
                  let url = (raw["browser_download_url"] as? String).flatMap(URL.init(string:))
            else { return nil }
            var sha256: String?
            if let digest = raw["digest"] as? String, digest.hasPrefix("sha256:") {
                let hex = String(digest.dropFirst("sha256:".count)).lowercased()
                if hex.count == 64, hex.allSatisfy(\.isHexDigit) {
                    sha256 = hex
                }
            }
            return ReleaseAsset(name: name, url: url, size: raw["size"] as? Int ?? 0, sha256: sha256)
        }
    }

    func asset(named name: String) -> ReleaseAsset? {
        assets.first { $0.name == name }
    }
}

enum UpdateFeed {
    /// `releases/latest` — drafts and pre-releases excluded by the endpoint.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/hronro/ime-jd/releases/latest")!
    /// Where a user goes to read notes or download by hand.
    static let releasesPageURL = URL(string: "https://github.com/hronro/ime-jd/releases")!
    /// Minimum gap between two automatic checks.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Release-asset filename of the macOS installer,
    /// `jd-ime-<tag>-macos-<arch>.pkg`, exactly as release.yml names it.
    static func installerName(tag: String, arch: String) -> String {
        "jd-ime-\(tag)-macos-\(arch).pkg"
    }

    /// The installer slice this machine should run: `arm64` on Apple silicon
    /// — even when the running build is the Intel slice under Rosetta, so an
    /// update fixes that — otherwise `x86_64`.
    static var hostArch: String {
        var flag: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &flag, &size, nil, 0) == 0, flag == 1 {
            return "arm64"
        }
        return "x86_64"
    }
}
