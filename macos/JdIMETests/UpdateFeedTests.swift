import XCTest
@testable import JdIME

final class UpdateFeedTests: XCTestCase {

    // MARK: - ReleaseVersion

    func testParsesTagsAndBundleVersions() {
        XCTAssertEqual(ReleaseVersion("v0.6.0"), ReleaseVersion(0, 6, 0))
        XCTAssertEqual(ReleaseVersion("0.6.0"), ReleaseVersion(0, 6, 0))
        XCTAssertEqual(ReleaseVersion("V1.2.3"), ReleaseVersion(1, 2, 3))
        XCTAssertEqual(ReleaseVersion(" v0.10.1\n"), ReleaseVersion(0, 10, 1))
        XCTAssertEqual(ReleaseVersion("01.002.3"), ReleaseVersion(1, 2, 3))
    }

    func testIgnoresPrereleaseAndBuildSuffixes() {
        XCTAssertEqual(ReleaseVersion("v1.0.0-rc1"), ReleaseVersion(1, 0, 0))
        XCTAssertEqual(ReleaseVersion("1.0.0+build.7"), ReleaseVersion(1, 0, 0))
        XCTAssertEqual(ReleaseVersion("v1.0.0-beta.2+exp"), ReleaseVersion(1, 0, 0))
    }

    func testRejectsMalformedVersions() {
        for bad in ["", "v", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "1..3", "v1.2.-3", "+1.2.3", "١.٢.٣", "1.2.3 4"] {
            XCTAssertNil(ReleaseVersion(bad), "\(bad.debugDescription) should not parse")
        }
    }

    func testOrdersNumericallyNotLexically() {
        XCTAssertLessThan(ReleaseVersion("0.9.9")!, ReleaseVersion("0.10.0")!)
        XCTAssertLessThan(ReleaseVersion("0.6.0")!, ReleaseVersion("1.0.0")!)
        XCTAssertLessThan(ReleaseVersion("0.6.0")!, ReleaseVersion("0.6.1")!)
        XCTAssertFalse(ReleaseVersion("0.6.0")! < ReleaseVersion("0.6.0")!)
        XCTAssertFalse(ReleaseVersion("0.6.0")! > ReleaseVersion("v0.6.0-rc1")!)
    }

    func testPlaceholderIsOnlyAllZeros() {
        XCTAssertTrue(ReleaseVersion("0.0.0")!.isPlaceholder)
        XCTAssertFalse(ReleaseVersion("0.0.1")!.isPlaceholder)
        XCTAssertEqual(ReleaseVersion("v0.6.0")!.description, "0.6.0")
    }

    // MARK: - LatestRelease

    private let feed = """
    {
      "url": "https://api.github.com/repos/hronro/ime-jd/releases/1",
      "html_url": "https://github.com/hronro/ime-jd/releases/tag/v0.6.0",
      "tag_name": "v0.6.0",
      "name": "v0.6.0",
      "draft": false,
      "prerelease": false,
      "author": { "login": "hronro", "html_url": "https://github.com/hronro" },
      "assets": [
        {
          "name": "jd-ime-v0.6.0-macos-arm64.pkg",
          "size": 2007998,
          "digest": "sha256:6262F6B63F96248C2B31C647684A5D6900867320CAEEDE0809CFAE3EF9910D80",
          "browser_download_url": "https://github.com/hronro/ime-jd/releases/download/v0.6.0/jd-ime-v0.6.0-macos-arm64.pkg"
        },
        {
          "name": "jd-ime-v0.6.0-macos-x86_64.pkg",
          "size": 2008447,
          "digest": null,
          "browser_download_url": "https://github.com/hronro/ime-jd/releases/download/v0.6.0/jd-ime-v0.6.0-macos-x86_64.pkg"
        },
        { "name": "broken-no-url", "size": 1 }
      ],
      "body": "notes"
    }
    """

    func testParsesTheLatestReleaseFeed() throws {
        let latest = try XCTUnwrap(LatestRelease(json: Data(feed.utf8)))
        XCTAssertEqual(latest.tag, "v0.6.0")
        XCTAssertEqual(latest.version, ReleaseVersion(0, 6, 0))
        XCTAssertEqual(latest.pageURL.absoluteString, "https://github.com/hronro/ime-jd/releases/tag/v0.6.0")
        // The asset without a download URL is dropped, the others kept in order.
        XCTAssertEqual(latest.assets.map(\.name), ["jd-ime-v0.6.0-macos-arm64.pkg", "jd-ime-v0.6.0-macos-x86_64.pkg"])

        let arm = try XCTUnwrap(latest.asset(named: "jd-ime-v0.6.0-macos-arm64.pkg"))
        XCTAssertEqual(arm.size, 2007998)
        XCTAssertEqual(arm.url.absoluteString,
                       "https://github.com/hronro/ime-jd/releases/download/v0.6.0/jd-ime-v0.6.0-macos-arm64.pkg")
        // Digest hex is normalized to lowercase for comparison with CryptoKit's output.
        XCTAssertEqual(arm.sha256, "6262f6b63f96248c2b31c647684a5d6900867320caeede0809cfae3ef9910d80")

        let intel = try XCTUnwrap(latest.asset(named: "jd-ime-v0.6.0-macos-x86_64.pkg"))
        XCTAssertNil(intel.sha256)
        XCTAssertNil(latest.asset(named: "jd-ime-v0.6.0-macos-universal.pkg"))
    }

    func testRejectsPayloadsThatAreNotAVersionedRelease() {
        XCTAssertNil(LatestRelease(json: Data("not json".utf8)))
        XCTAssertNil(LatestRelease(json: Data(#"{"message": "API rate limit exceeded"}"#.utf8)))
        XCTAssertNil(LatestRelease(json: Data(#"{"tag_name": "nightly", "html_url": "https://x"}"#.utf8)))
        XCTAssertNil(LatestRelease(json: Data(#"{"tag_name": "v1.0.0"}"#.utf8)), "html_url is required")
        XCTAssertNil(LatestRelease(json: Data(#"[{"tag_name": "v1.0.0"}]"#.utf8)))
    }

    func testFeedWithoutAssetsStillParses() throws {
        let latest = try XCTUnwrap(LatestRelease(json: Data(
            #"{"tag_name": "v9.9.9", "html_url": "https://github.com/hronro/ime-jd/releases/tag/v9.9.9"}"#.utf8
        )))
        XCTAssertEqual(latest.version, ReleaseVersion(9, 9, 9))
        XCTAssertTrue(latest.assets.isEmpty)
    }

    func testMalformedDigestsAreDropped() throws {
        let json = """
        {"tag_name": "v1.0.0", "html_url": "https://x/", "assets": [
          {"name": "a", "browser_download_url": "https://x/a", "digest": "sha256:abc"},
          {"name": "b", "browser_download_url": "https://x/b", "digest": "md5:\(String(repeating: "0", count: 64))"},
          {"name": "c", "browser_download_url": "https://x/c", "digest": "sha256:\(String(repeating: "g", count: 64))"}
        ]}
        """
        let latest = try XCTUnwrap(LatestRelease(json: Data(json.utf8)))
        XCTAssertEqual(latest.assets.count, 3)
        XCTAssertTrue(latest.assets.allSatisfy { $0.sha256 == nil })
    }

    // MARK: - UpdateFeed

    func testInstallerNameMatchesTheReleaseWorkflow() {
        XCTAssertEqual(UpdateFeed.installerName(tag: "v0.6.0", arch: "arm64"), "jd-ime-v0.6.0-macos-arm64.pkg")
        XCTAssertEqual(UpdateFeed.installerName(tag: "v0.6.0", arch: "x86_64"), "jd-ime-v0.6.0-macos-x86_64.pkg")
    }

    func testHostArchIsAPublishedSlice() {
        XCTAssertTrue(["arm64", "x86_64"].contains(UpdateFeed.hostArch))
    }
}
