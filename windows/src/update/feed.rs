//! The update feed's data model — plain `std`, no Win32, so the unit tests
//! here run on any host (`cargo test` on the Windows CI job, or
//! `rustc --test src/update/feed.rs` on a Mac).
//!
//! The feed is GitHub's `releases/latest` endpoint for this repository.
//! Every platform frontend that updates itself reads the same feed and
//! applies the same rules (macos/JdIME/Update/UpdateFeed.swift,
//! android/.../update/ReleaseFeed.kt): compare the release's
//! `MAJOR.MINOR.PATCH` against the running build, and point the user at the
//! release. Only the tag is extracted here — the Windows frontend opens the
//! release page rather than installing in place (see update/mod.rs), so it
//! needs no asset list and therefore no JSON library.

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
}
