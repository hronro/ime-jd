//! The update feed's data model — plain `std`, no Win32, so the unit tests
//! here run on any host (`cargo test` on the Windows CI job, or
//! `rustc --test src/update/feed.rs` on a Mac).
//!
//! The feed is GitHub's `releases/latest` endpoint for this repository.
//! Every platform frontend that updates itself reads the same feed and
//! applies the same rules (macos/JdIME/Update/UpdateFeed.swift,
//! android/.../update/ReleaseFeed.kt): compare the release's
//! `MAJOR.MINOR.PATCH` against the running build, and pick the asset
//! `.github/workflows/release.yml` names for this platform.
//!
//! `extract_tag` reads just the tag — enough for the "new version" notice.
//! `extract_asset` reads the one asset the auto-installer needs (its download
//! URL, size, and SHA-256). Both are hand scans over the small, stable feed
//! schema rather than a JSON library, matching the rest of this crate's
//! minimal-dependency style; the keys involved never collide with the nested
//! `uploader` object, so a per-object key lookup is unambiguous.

/// Host + path of the `releases/latest` endpoint (drafts and pre-releases
/// excluded by the endpoint). Split for WinHTTP, which wants them apart.
pub const FEED_HOST: &str = "api.github.com";
pub const FEED_PATH: &str = "/repos/hronro/ime-jd/releases/latest";

/// Minimum gap between two automatic checks, in seconds.
pub const CHECK_INTERVAL_SECS: u64 = 24 * 60 * 60;

/// The page for one release: notes plus that version's downloads.
pub fn release_page_url(tag: &str) -> String {
    format!("https://github.com/hronro/ime-jd/releases/tag/{tag}")
}

/// A release version, `MAJOR.MINOR.PATCH`, parsed from a Git tag (`v0.6.0`)
/// or the version build.rs bakes in (`0.6.0`). A `-prerelease` / `+build`
/// suffix is ignored: the feed only ever reports full releases, and the
/// numeric triple is all that decides whether one build is newer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl Version {
    pub fn parse(text: &str) -> Option<Version> {
        let mut body = text.trim();
        if let Some(rest) = body.strip_prefix('v').or_else(|| body.strip_prefix('V')) {
            body = rest;
        }
        if let Some(cut) = body.find(['-', '+']) {
            body = &body[..cut];
        }
        let mut numbers = [0u32; 3];
        let mut count = 0;
        for part in body.split('.') {
            // ASCII digits only: `str::parse` would also accept a leading `+`.
            if count == 3 || part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            numbers[count] = part.parse().ok()?;
            count += 1;
        }
        if count != 3 {
            return None;
        }
        Some(Version {
            major: numbers[0],
            minor: numbers[1],
            patch: numbers[2],
        })
    }

    /// `0.0.0` — never a release. Nothing in this crate produces it (build.rs
    /// reads the real version), but the rule is shared with the other
    /// frontends, whose IDE builds do carry the placeholder.
    pub fn is_placeholder(self) -> bool {
        self == Version {
            major: 0,
            minor: 0,
            patch: 0,
        }
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// Extract the release tag (`"tag_name": "v0.6.0"`) from the feed's JSON.
///
/// A key scan rather than a parser: `tag_name` occurs exactly once in this
/// document, at the top level (assets carry `name`, the author `login`), and
/// its value is a plain tag. Anything that does not parse as a version —
/// including an error body like `{"message": "API rate limit exceeded"}` —
/// yields `None`.
pub fn extract_tag(json: &str) -> Option<String> {
    let key = "\"tag_name\"";
    let mut search = json;
    while let Some(at) = search.find(key) {
        let rest = search[at + key.len()..].trim_start();
        if let Some(rest) = rest.strip_prefix(':') {
            let rest = rest.trim_start();
            if let Some(rest) = rest.strip_prefix('"') {
                let value = read_string(rest)?;
                // A tag is `v` + version; reject anything else so a hostile
                // or broken feed can never put arbitrary text in the notice.
                if value.starts_with('v')
                    && Version::parse(&value).is_some()
                    && !value.contains(char::is_whitespace)
                {
                    return Some(value);
                }
                return None;
            }
        }
        search = &search[at + key.len()..];
    }
    None
}

/// Read a JSON string body up to its closing quote, decoding the simple
/// escapes. Returns `None` for escapes a tag can never legitimately need.
fn read_string(s: &str) -> Option<String> {
    let mut out = String::new();
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                '"' => out.push('"'),
                '\\' => out.push('\\'),
                '/' => out.push('/'),
                _ => return None,
            },
            c if c.is_control() => return None,
            c => out.push(c),
        }
    }
    None
}

/// This build's Windows arch as it appears in a release-asset name.
#[cfg(target_arch = "x86_64")]
pub const HOST_ARCH: &str = "x86_64";
#[cfg(target_arch = "aarch64")]
pub const HOST_ARCH: &str = "arm64";

/// The IME release zip for one arch, `jd-ime-<tag>-windows-<arch>.zip`,
/// exactly as release.yml names it (its `build-windows-ime` job). The zip
/// holds the DLL plus `register.bat` / `unregister.bat`.
pub fn installer_name(tag: &str, arch: &str) -> String {
    format!("jd-ime-{tag}-windows-{arch}.zip")
}

/// One downloadable file attached to a release — the counterpart of macOS
/// and Android's `ReleaseAsset`, trimmed to the fields the installer needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Asset {
    pub name: String,
    pub url: String,
    pub size: u64,
    /// Lowercase-hex SHA-256 from the API's `digest` field (`sha256:<hex>`),
    /// when GitHub supplied one. The download is verified against it.
    pub sha256: Option<String>,
}

/// Find the asset named `name` in the feed's `assets` array and read the
/// three fields the installer needs. `None` if the array or the asset is
/// absent, or the asset has no download URL.
pub fn extract_asset(json: &str, name: &str) -> Option<Asset> {
    let assets = assets_array(json)?;
    for object in objects(assets) {
        if json_string(object, "name").as_deref() == Some(name) {
            let url = json_string(object, "browser_download_url")?;
            let size = json_u64(object, "size").unwrap_or(0);
            let sha256 = json_string(object, "digest").and_then(|d| sha256_from_digest(&d));
            return Some(Asset {
                name: name.to_string(),
                url,
                size,
                sha256,
            });
        }
    }
    None
}

/// Split `https://host/path` into (host, path) for WinHTTP, which wants them
/// apart. The path keeps its leading `/` (defaulting to `/`).
pub fn split_https_url(url: &str) -> Option<(&str, &str)> {
    let rest = url.strip_prefix("https://")?;
    let cut = rest.find('/').unwrap_or(rest.len());
    let host = &rest[..cut];
    if host.is_empty() {
        return None;
    }
    let path = &rest[cut..];
    Some((host, if path.is_empty() { "/" } else { path }))
}

/// `sha256:<64 hex>` → the lowercase hex, or `None` for any other shape.
fn sha256_from_digest(digest: &str) -> Option<String> {
    let hex = digest.strip_prefix("sha256:")?.to_ascii_lowercase();
    (hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_hexdigit())).then_some(hex)
}

// ---- tiny JSON scanning (no dependency, see the module comment) ------------

/// The contents of the top-level `assets` array — the text between its `[`
/// and the matching `]`.
fn assets_array(json: &str) -> Option<&str> {
    let at = json.find("\"assets\"")?;
    let rest = json[at + "\"assets\"".len()..].trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    let rest = rest.strip_prefix('[')?;
    let end = matching(rest, b'[', b']')?;
    Some(&rest[..end])
}

/// Yield each top-level `{...}` object (braces included) within `slice`.
fn objects(slice: &str) -> impl Iterator<Item = &str> {
    let bytes = slice.as_bytes();
    let mut i = 0;
    std::iter::from_fn(move || {
        while i < bytes.len() {
            if bytes[i] == b'{' {
                let end = matching(&slice[i + 1..], b'{', b'}')?;
                let object = &slice[i..i + 1 + end + 1];
                i += 1 + end + 1;
                return Some(object);
            }
            i += 1;
        }
        None
    })
}

/// Given the text just *after* an opening delimiter, the index (within that
/// text) of the matching closing one, honoring nesting and skipping string
/// literals (with `\` escapes).
fn matching(after_open: &str, open: u8, close: u8) -> Option<usize> {
    let bytes = after_open.as_bytes();
    let mut depth = 0usize;
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'"' => {
                i += 1;
                while i < bytes.len() {
                    match bytes[i] {
                        b'\\' => i += 1,
                        b'"' => break,
                        _ => {}
                    }
                    i += 1;
                }
            }
            b if b == open => depth += 1,
            b if b == close => {
                if depth == 0 {
                    return Some(i);
                }
                depth -= 1;
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// The string value of top-level key `key` in one JSON `object`.
fn json_string(object: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let mut search = object;
    loop {
        let at = search.find(&needle)?;
        let after = &search[at + needle.len()..];
        if let Some(rest) = after.trim_start().strip_prefix(':')
            && let Some(rest) = rest.trim_start().strip_prefix('"')
            && let Some(value) = read_string(rest)
        {
            return Some(value);
        }
        search = after;
    }
}

/// The unsigned-integer value of top-level key `key` in one JSON `object`.
fn json_u64(object: &str, key: &str) -> Option<u64> {
    let needle = format!("\"{key}\"");
    let mut search = object;
    loop {
        let at = search.find(&needle)?;
        let after = &search[at + needle.len()..];
        if let Some(rest) = after.trim_start().strip_prefix(':') {
            let digits: String = rest.trim_start().chars().take_while(|c| c.is_ascii_digit()).collect();
            if !digits.is_empty() {
                return digits.parse().ok();
            }
        }
        search = after;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(major: u32, minor: u32, patch: u32) -> Version {
        Version {
            major,
            minor,
            patch,
        }
    }

    #[test]
    fn parses_tags_and_plain_versions() {
        assert_eq!(Version::parse("v0.6.0"), Some(v(0, 6, 0)));
        assert_eq!(Version::parse("0.6.0"), Some(v(0, 6, 0)));
        assert_eq!(Version::parse("V1.2.3"), Some(v(1, 2, 3)));
        assert_eq!(Version::parse(" v0.10.1\n"), Some(v(0, 10, 1)));
        assert_eq!(Version::parse("01.002.3"), Some(v(1, 2, 3)));
    }

    #[test]
    fn ignores_prerelease_and_build_suffixes() {
        assert_eq!(Version::parse("v1.0.0-rc1"), Some(v(1, 0, 0)));
        assert_eq!(Version::parse("1.0.0+build.7"), Some(v(1, 0, 0)));
        assert_eq!(Version::parse("v1.0.0-beta.2+exp"), Some(v(1, 0, 0)));
    }

    #[test]
    fn rejects_malformed_versions() {
        for bad in [
            "", "v", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "1..3", "v1.2.-3", "+1.2.3", "١.٢.٣",
            "1.2.3 4",
        ] {
            assert_eq!(Version::parse(bad), None, "{bad:?} should not parse");
        }
    }

    #[test]
    fn orders_numerically_not_lexically() {
        assert!(v(0, 9, 9) < v(0, 10, 0));
        assert!(v(0, 6, 0) < v(1, 0, 0));
        assert!(v(0, 6, 0) < v(0, 6, 1));
        assert_eq!(Version::parse("0.6.0"), Version::parse("v0.6.0-rc1"));
        assert!(v(0, 0, 0).is_placeholder());
        assert!(!v(0, 0, 1).is_placeholder());
        assert_eq!(v(0, 6, 0).to_string(), "0.6.0");
    }

    const FEED: &str = r#"{
      "url": "https://api.github.com/repos/hronro/ime-jd/releases/1",
      "html_url": "https://github.com/hronro/ime-jd/releases/tag/v0.6.0",
      "tag_name": "v0.6.0",
      "name": "v0.6.0",
      "author": { "login": "hronro", "html_url": "https://github.com/hronro" },
      "assets": [
        { "name": "jd-ime-v0.6.0-windows-x86_64.zip", "size": 1923234,
          "browser_download_url": "https://github.com/hronro/ime-jd/releases/download/v0.6.0/jd-ime-v0.6.0-windows-x86_64.zip" }
      ],
      "body": "notes mentioning \"tag_name\": \"v9.9.9\" should not matter"
    }"#;

    #[test]
    fn extracts_the_tag_from_the_feed() {
        assert_eq!(extract_tag(FEED).as_deref(), Some("v0.6.0"));
        assert_eq!(
            extract_tag(r#"{"tag_name":"v1.2.3"}"#).as_deref(),
            Some("v1.2.3")
        );
        assert_eq!(
            extract_tag("{ \"tag_name\" \t:\n \"v1.2.3-rc1\" }").as_deref(),
            Some("v1.2.3-rc1")
        );
        assert_eq!(
            release_page_url("v1.2.3"),
            "https://github.com/hronro/ime-jd/releases/tag/v1.2.3"
        );
    }

    #[test]
    fn rejects_payloads_that_are_not_a_versioned_release() {
        assert_eq!(extract_tag("not json"), None);
        assert_eq!(
            extract_tag(r#"{"message": "API rate limit exceeded"}"#),
            None
        );
        assert_eq!(extract_tag(r#"{"tag_name": "nightly"}"#), None);
        assert_eq!(extract_tag(r#"{"tag_name": 123}"#), None);
        assert_eq!(extract_tag(r#"{"tag_name": "v1.0.0\n"}"#), None);
        assert_eq!(extract_tag(r#"{"tag_name": "v1.0.0\u0020evil"}"#), None);
        assert_eq!(extract_tag(r#"{"tag_name": "v1.0.0"#), None, "unterminated");
        // The literal key inside another string value is not the field.
        assert_eq!(
            extract_tag(r#"{"body": "see \"tag_name\": x", "tag_name": "v2.0.0"}"#).as_deref(),
            Some("v2.0.0")
        );
    }

    // A trimmed but structurally faithful `releases/latest` payload: two
    // Windows IME assets (x86_64 + arm64), each with a nested `uploader`
    // object that carries its own `url` (and no clashing keys), one asset
    // whose `digest` is absent, and asset fields in GitHub's real order
    // (name early, size/digest/browser_download_url later).
    const FEED_WITH_ASSETS: &str = r#"{
      "html_url": "https://github.com/hronro/ime-jd/releases/tag/v0.6.0",
      "tag_name": "v0.6.0",
      "assets": [
        {
          "url": "https://api.github.com/repos/hronro/ime-jd/releases/assets/1",
          "id": 1,
          "name": "jd-ime-v0.6.0-windows-x86_64.zip",
          "label": null,
          "uploader": { "login": "hronro", "id": 7, "url": "https://api.github.com/users/hronro", "type": "User" },
          "content_type": "application/zip",
          "state": "uploaded",
          "size": 1923234,
          "download_count": 3,
          "digest": "sha256:AC0C7173E5F5D2177DE53FBF6AE0B7C781D43ECD5C515838C4D5679A5DD1DA87",
          "browser_download_url": "https://github.com/hronro/ime-jd/releases/download/v0.6.0/jd-ime-v0.6.0-windows-x86_64.zip"
        },
        {
          "url": "https://api.github.com/repos/hronro/ime-jd/releases/assets/2",
          "id": 2,
          "name": "jd-ime-v0.6.0-windows-arm64.zip",
          "uploader": { "login": "hronro", "id": 7, "url": "https://api.github.com/users/hronro" },
          "content_type": "application/zip",
          "size": 1921364,
          "browser_download_url": "https://github.com/hronro/ime-jd/releases/download/v0.6.0/jd-ime-v0.6.0-windows-arm64.zip"
        }
      ]
    }"#;

    #[test]
    fn builds_the_installer_name_from_tag_and_arch() {
        assert_eq!(
            installer_name("v0.6.0", "x86_64"),
            "jd-ime-v0.6.0-windows-x86_64.zip"
        );
        assert_eq!(
            installer_name("v1.2.3", "arm64"),
            "jd-ime-v1.2.3-windows-arm64.zip"
        );
        assert!(HOST_ARCH == "x86_64" || HOST_ARCH == "arm64");
    }

    #[test]
    fn extracts_the_asset_with_url_size_and_lowercased_sha256() {
        let a = extract_asset(FEED_WITH_ASSETS, "jd-ime-v0.6.0-windows-x86_64.zip")
            .expect("x86_64 asset");
        assert_eq!(a.name, "jd-ime-v0.6.0-windows-x86_64.zip");
        assert_eq!(
            a.url,
            "https://github.com/hronro/ime-jd/releases/download/v0.6.0/jd-ime-v0.6.0-windows-x86_64.zip"
        );
        assert_eq!(a.size, 1923234);
        // Uppercased in the fixture; stored lowercase.
        assert_eq!(
            a.sha256.as_deref(),
            Some("ac0c7173e5f5d2177de53fbf6ae0b7c781d43ecd5c515838c4d5679a5dd1da87")
        );
    }

    #[test]
    fn selects_the_right_asset_and_tolerates_a_missing_digest() {
        // The arm64 entry comes second and has no `digest`.
        let a = extract_asset(FEED_WITH_ASSETS, "jd-ime-v0.6.0-windows-arm64.zip")
            .expect("arm64 asset");
        assert_eq!(a.size, 1921364);
        assert_eq!(a.sha256, None);
        assert!(a.url.ends_with("jd-ime-v0.6.0-windows-arm64.zip"));
        // A name no asset carries.
        assert_eq!(extract_asset(FEED_WITH_ASSETS, "nope.zip"), None);
        // A payload with no assets array at all.
        assert_eq!(extract_asset(r#"{"tag_name":"v1.0.0"}"#, "x.zip"), None);
    }

    #[test]
    fn splits_https_urls_into_host_and_path() {
        assert_eq!(
            split_https_url("https://github.com/hronro/ime-jd/releases/download/v0.6.0/a.zip"),
            Some(("github.com", "/hronro/ime-jd/releases/download/v0.6.0/a.zip"))
        );
        assert_eq!(split_https_url("https://host.example"), Some(("host.example", "/")));
        assert_eq!(split_https_url("http://github.com/x"), None, "not https");
        assert_eq!(split_https_url("https:///nohost"), None, "empty host");
    }
}
