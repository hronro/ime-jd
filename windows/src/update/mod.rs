//! Update check for the Windows IME — the counterpart of
//! macos/JdIME/Update/UpdateManager.swift and android/.../update/.
//!
//! This TIP has no window, menu, or process of its own: it is a DLL loaded
//! into every application the user types in. So the update path is the
//! smallest thing that works from there:
//!   1. On activation, at most once per `CHECK_INTERVAL_SECS` across all
//!      processes (the timestamp lives in the registry), a background thread
//!      GETs the release feed over WinHTTP and records the newest tag.
//!   2. While that tag is ahead of this build and the user has not acted on
//!      it, the candidate window carries a one-line notice under the
//!      candidates (candidate_window.rs).
//!   3. Clicking the notice opens the release page in the browser — the
//!      user downloads the zip and runs `register.bat` as before (in-place
//!      replacement of a DLL that every host process has mapped is exactly
//!      what that script already handles) — and retires the notice for that
//!      version.
//!
//! The check sends nothing but the request itself (no identifiers beyond a
//! `User-Agent` naming this IME and its version). It is skipped inside
//! AppContainer (UWP) hosts, which can neither reach the network on our
//! behalf nor write the registry state, and it can be switched off with the
//! `CheckForUpdates` value under `HKCU\Software\hronro\ime-jd` (see
//! windows/README.md).

mod feed;

use std::ffi::c_void;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::Networking::WinHttp::{
    INTERNET_DEFAULT_HTTPS_PORT, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_ADDREQ_FLAG_ADD,
    WINHTTP_FLAG_SECURE, WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_QUERY_STATUS_CODE,
    WinHttpAddRequestHeaders, WinHttpCloseHandle, WinHttpConnect, WinHttpOpen, WinHttpOpenRequest,
    WinHttpQueryDataAvailable, WinHttpQueryHeaders, WinHttpReadData, WinHttpReceiveResponse,
    WinHttpSendRequest, WinHttpSetTimeouts,
};
use windows::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TokenIsAppContainer};
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_SET_VALUE, REG_OPTION_NON_VOLATILE, REG_QWORD, REG_SZ,
    RRF_RT_REG_DWORD, RRF_RT_REG_QWORD, RRF_RT_REG_SZ, RegCloseKey, RegCreateKeyExW, RegGetValueW,
    RegSetValueExW,
};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
use windows::core::{PCWSTR, w};

pub use feed::Version;

/// This build's version, baked in by build.rs from core/build.zig.zon.
pub const CURRENT_VERSION: &str = env!("JD_VERSION");

/// A newer release the user has not acted on yet — what the candidate
/// window announces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Notice {
    pub tag: String,
    pub url: String,
}

impl Notice {
    /// The one-line text the candidate window draws.
    pub fn text(&self) -> String {
        format!("键道有新版本 {}，点击前往下载", self.tag)
    }
}

/// Process-wide cache of the registry-derived notice, so the candidate
/// window's per-show read is a mutex lock rather than registry I/O.
static NOTICE: Mutex<Option<Notice>> = Mutex::new(None);
static CHECK_IN_FLIGHT: AtomicBool = AtomicBool::new(false);

// HKCU state, shared by every host process. The key is created on first
// write; reads of a missing value fall back to defaults.
const REG_KEY: PCWSTR = w!(r"Software\hronro\ime-jd");
/// DWORD; anything but 0 (and absent) means "check". The user's opt-out.
const REG_CHECK_FOR_UPDATES: PCWSTR = w!("CheckForUpdates");
/// QWORD, Unix seconds of the last check (attempted, not necessarily successful).
const REG_LAST_CHECK: PCWSTR = w!("LastUpdateCheck");
/// SZ, the newest tag the feed reported.
const REG_LATEST: PCWSTR = w!("LatestVersion");
/// SZ, the tag whose notice the user clicked.
const REG_SEEN: PCWSTR = w!("SeenVersion");

/// Called from `ITfTextInputProcessorEx::ActivateEx`, i.e. whenever the user
/// switches to 键道 in some application. Refreshes the cached notice from the
/// registry and, if a check is due, runs one in the background.
pub fn on_activate() {
    refresh_notice();

    if !checks_enabled() || is_app_container() {
        return;
    }
    match Version::parse(CURRENT_VERSION) {
        Some(current) if !current.is_placeholder() => {}
        _ => return,
    }
    let now = unix_now();
    if let Some(last) = read_qword(REG_LAST_CHECK)
        && now.saturating_sub(last) < feed::CHECK_INTERVAL_SECS
    {
        return;
    }
    if CHECK_IN_FLIGHT.swap(true, Ordering::SeqCst) {
        return;
    }
    // Stamp before the request, so a failing feed is retried tomorrow rather
    // than on every activation (and so concurrent hosts don't all fetch).
    write_qword(REG_LAST_CHECK, now);
    let spawned = std::thread::Builder::new()
        .name("jd-update-check".into())
        .spawn(|| {
            if let Some(json) = fetch_feed()
                && let Some(tag) = feed::extract_tag(&json)
            {
                write_sz(REG_LATEST, &tag);
                refresh_notice();
            }
            CHECK_IN_FLIGHT.store(false, Ordering::SeqCst);
        });
    if spawned.is_err() {
        CHECK_IN_FLIGHT.store(false, Ordering::SeqCst);
    }
}

/// The notice to draw, if any. Cheap; read on every candidate-window show.
pub fn pending_notice() -> Option<Notice> {
    NOTICE.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// The user clicked the notice: open the release page and stop showing this
/// version's notice, here and in every other host (via the registry).
pub fn open_notice(notice: &Notice) {
    write_sz(REG_SEEN, &notice.tag);
    *NOTICE.lock().unwrap_or_else(|e| e.into_inner()) = None;
    open_url(&notice.url);
}

/// Recompute the notice from the registry: newest tag ahead of this build,
/// not yet acted on.
fn refresh_notice() {
    let notice = (|| {
        let current = Version::parse(CURRENT_VERSION)?;
        let tag = read_sz(REG_LATEST)?;
        let latest = Version::parse(&tag)?;
        if latest <= current || read_sz(REG_SEEN).as_deref() == Some(tag.as_str()) {
            return None;
        }
        Some(Notice {
            url: feed::release_page_url(&tag),
            tag,
        })
    })();
    *NOTICE.lock().unwrap_or_else(|e| e.into_inner()) = notice;
}

fn checks_enabled() -> bool {
    read_dword(REG_CHECK_FOR_UPDATES).unwrap_or(1) != 0
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// AppContainer (UWP / sandboxed Store app) hosts: no network on our behalf,
/// no writable HKCU — skip the check there; desktop hosts cover the user.
fn is_app_container() -> bool {
    unsafe {
        let mut token = HANDLE::default();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).is_err() {
            return false;
        }
        let mut flag: u32 = 0;
        let mut len: u32 = 0;
        let ok = GetTokenInformation(
            token,
            TokenIsAppContainer,
            Some(&mut flag as *mut u32 as *mut c_void),
            std::mem::size_of::<u32>() as u32,
            &mut len,
        )
        .is_ok();
        let _ = CloseHandle(token);
        ok && flag != 0
    }
}

fn open_url(url: &str) {
    let wide = wide_z(url);
    unsafe {
        ShellExecuteW(
            None,
            w!("open"),
            PCWSTR(wide.as_ptr()),
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        );
    }
}

// ---- WinHTTP ---------------------------------------------------------------

/// GET the feed; `None` on any failure (offline, proxy, non-200, oversized).
fn fetch_feed() -> Option<String> {
    let agent = wide_z(&format!("ime-jd-windows/{CURRENT_VERSION}"));
    unsafe {
        let session = WinHttpOpen(
            PCWSTR(agent.as_ptr()),
            WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
            PCWSTR::null(),
            PCWSTR::null(),
            0,
        );
        if session.is_null() {
            return None;
        }
        let result = fetch_with_session(session);
        let _ = WinHttpCloseHandle(session);
        result
    }
}

unsafe fn fetch_with_session(session: *mut c_void) -> Option<String> {
    unsafe {
        // resolve / connect / send / receive, ms.
        let _ = WinHttpSetTimeouts(session, 10_000, 10_000, 15_000, 15_000);
        let host = wide_z(feed::FEED_HOST);
        let connect = WinHttpConnect(
            session,
            PCWSTR(host.as_ptr()),
            INTERNET_DEFAULT_HTTPS_PORT,
            0,
        );
        if connect.is_null() {
            return None;
        }
        let result = fetch_with_connection(connect);
        let _ = WinHttpCloseHandle(connect);
        result
    }
}

unsafe fn fetch_with_connection(connect: *mut c_void) -> Option<String> {
    unsafe {
        let path = wide_z(feed::FEED_PATH);
        let request = WinHttpOpenRequest(
            connect,
            w!("GET"),
            PCWSTR(path.as_ptr()),
            PCWSTR::null(),
            PCWSTR::null(),
            std::ptr::null(),
            WINHTTP_FLAG_SECURE,
        );
        if request.is_null() {
            return None;
        }
        let result = read_response(request);
        let _ = WinHttpCloseHandle(request);
        result
    }
}

unsafe fn read_response(request: *mut c_void) -> Option<String> {
    unsafe {
        let headers: Vec<u16> =
            "Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28\r\n"
                .encode_utf16()
                .collect();
        WinHttpAddRequestHeaders(request, &headers, WINHTTP_ADDREQ_FLAG_ADD).ok()?;
        WinHttpSendRequest(request, None, None, 0, 0, 0).ok()?;
        WinHttpReceiveResponse(request, std::ptr::null_mut()).ok()?;

        let mut status: u32 = 0;
        let mut size = std::mem::size_of::<u32>() as u32;
        WinHttpQueryHeaders(
            request,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            PCWSTR::null(),
            Some(&mut status as *mut u32 as *mut c_void),
            &mut size,
            std::ptr::null_mut(),
        )
        .ok()?;
        if status != 200 {
            return None;
        }

        // The feed is ~15 KB; anything near the cap is not the feed.
        const MAX_BODY: usize = 1 << 20;
        let mut body: Vec<u8> = Vec::new();
        loop {
            let mut available: u32 = 0;
            WinHttpQueryDataAvailable(request, &mut available).ok()?;
            if available == 0 {
                break;
            }
            let start = body.len();
            if start + available as usize > MAX_BODY {
                return None;
            }
            body.resize(start + available as usize, 0);
            let mut read: u32 = 0;
            WinHttpReadData(
                request,
                body[start..].as_mut_ptr() as *mut c_void,
                available,
                &mut read,
            )
            .ok()?;
            body.truncate(start + read as usize);
            if read == 0 {
                break;
            }
        }
        String::from_utf8(body).ok()
    }
}

// ---- Registry (HKCU) -------------------------------------------------------

fn wide_z(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn read_dword(name: PCWSTR) -> Option<u32> {
    let mut data: u32 = 0;
    let mut size = std::mem::size_of::<u32>() as u32;
    unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            REG_KEY,
            name,
            RRF_RT_REG_DWORD,
            None,
            Some(&mut data as *mut u32 as *mut c_void),
            Some(&mut size),
        )
    }
    .is_ok()
    .then_some(data)
}

fn read_qword(name: PCWSTR) -> Option<u64> {
    let mut data: u64 = 0;
    let mut size = std::mem::size_of::<u64>() as u32;
    unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            REG_KEY,
            name,
            RRF_RT_REG_QWORD,
            None,
            Some(&mut data as *mut u64 as *mut c_void),
            Some(&mut size),
        )
    }
    .is_ok()
    .then_some(data)
}

fn read_sz(name: PCWSTR) -> Option<String> {
    unsafe {
        // Size query first (bytes, NUL included), then the value.
        let mut size: u32 = 0;
        RegGetValueW(
            HKEY_CURRENT_USER,
            REG_KEY,
            name,
            RRF_RT_REG_SZ,
            None,
            None,
            Some(&mut size),
        )
        .ok()
        .ok()?;
        let mut buf = vec![0u16; (size as usize).div_ceil(2).max(1)];
        RegGetValueW(
            HKEY_CURRENT_USER,
            REG_KEY,
            name,
            RRF_RT_REG_SZ,
            None,
            Some(buf.as_mut_ptr() as *mut c_void),
            Some(&mut size),
        )
        .ok()
        .ok()?;
        let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        Some(String::from_utf16_lossy(&buf[..end]))
    }
}

/// Open (creating on first use) the HKCU key for writing.
fn open_key_for_write() -> Option<HKEY> {
    let mut hkey = HKEY::default();
    unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            REG_KEY,
            None,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_SET_VALUE,
            None,
            &mut hkey,
            None,
        )
    }
    .ok()
    .ok()?;
    Some(hkey)
}

fn write_qword(name: PCWSTR, value: u64) {
    if let Some(hkey) = open_key_for_write() {
        unsafe {
            let _ = RegSetValueExW(hkey, name, None, REG_QWORD, Some(&value.to_le_bytes()));
            let _ = RegCloseKey(hkey);
        }
    }
}

fn write_sz(name: PCWSTR, value: &str) {
    if let Some(hkey) = open_key_for_write() {
        let wide = wide_z(value);
        let bytes: Vec<u8> = wide.iter().flat_map(|c| c.to_le_bytes()).collect();
        unsafe {
            let _ = RegSetValueExW(hkey, name, None, REG_SZ, Some(&bytes));
            let _ = RegCloseKey(hkey);
        }
    }
}
