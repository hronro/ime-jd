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
//!   3. Clicking the notice retires it for that version and, on a background
//!      thread, downloads the release zip — verified against the feed's
//!      SHA-256 — and runs the installed `update.bat` elevated (one UAC
//!      prompt), which unpacks the zip and runs its `register.bat`.
//!      `register.bat` does the in-place swap of a DLL that every host
//!      process has mapped (rename-while-loaded), exactly as a manual
//!      upgrade does. Anything that fails falls back to opening the release
//!      page so the user can upgrade by hand. Applications already running
//!      keep the old DLL until they are next launched — Windows does not
//!      reload a DLL a process has already mapped — so the install fully
//!      applies to apps started afterwards (or after sign-out).
//!
//! Nothing that runs elevated comes from a place the user's own programs can
//! write. The download lies in the user's temporary folder, where any of
//! them could put another file in its place while the UAC prompt is up; so
//! the only thing started elevated is `update.bat` beside this DLL, under
//! Program Files, and it is told the SHA-256 of what was downloaded. It
//! reads the zip once, and unpacks it — into a folder of its own, there —
//! only if what it read has that SHA-256 (windows/update.bat).
//!
//! This mirrors the other frontends' installing half (macOS hands the `.pkg`
//! to Installer.app, Android hands the `.apk` to the PackageInstaller): each
//! downloads the platform's own release asset, verifies it against the feed
//! digest, and lets the OS do the privileged install behind a user prompt.
//!
//! The check sends nothing but the request itself (no identifiers beyond a
//! `User-Agent` naming this IME and its version). It is skipped inside
//! AppContainer (UWP) hosts, which can neither reach the network on our
//! behalf nor write the registry state, and it can be switched off — 自动检查
//! 更新 in the menu of the IME's mode icon, the `CheckForUpdates` value under
//! `HKCU\Software\hronro\ime-jd` (jd_userdict::switch).
//!
//! On the secure desktop — the sign-in screen, a UAC prompt — none of this
//! exists: no check, no notice, nothing to click. Whoever types there has
//! not signed in, and the host runs as SYSTEM, so a download, an installer or
//! a browser started from it would hand them the machine (`SECURE`).

mod feed;

use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use windows::Win32::Networking::WinHttp::{
    INTERNET_DEFAULT_HTTPS_PORT, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_ADDREQ_FLAG_ADD,
    WINHTTP_FLAG_SECURE, WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_QUERY_STATUS_CODE,
    WinHttpAddRequestHeaders, WinHttpCloseHandle, WinHttpConnect, WinHttpOpen, WinHttpOpenRequest,
    WinHttpQueryDataAvailable, WinHttpQueryHeaders, WinHttpReadData, WinHttpReceiveResponse,
    WinHttpSendRequest, WinHttpSetTimeouts,
};
use windows::Win32::Security::Cryptography::{
    BCRYPT_ALG_HANDLE, BCRYPT_HASH_HANDLE, BCRYPT_OPEN_ALGORITHM_PROVIDER_FLAGS,
    BCRYPT_SHA256_ALGORITHM, BCryptCloseAlgorithmProvider, BCryptCreateHash, BCryptDestroyHash,
    BCryptFinishHash, BCryptHashData, BCryptOpenAlgorithmProvider,
};
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_QUERY_VALUE, KEY_SET_VALUE, KEY_WOW64_64KEY,
    REG_OPTION_NON_VOLATILE, REG_QWORD, REG_SZ, RRF_RT_REG_QWORD, RRF_RT_REG_SZ, RegCloseKey,
    RegCreateKeyExW, RegGetValueW, RegOpenKeyExW, RegSetValueExW,
};
use windows::Win32::System::SystemInformation::GetSystemDirectoryW;
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
use windows::core::{PCWSTR, w};

pub use feed::Version;

use crate::host;

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
        format!("键道有新版本 {}，点击下载并安装", self.tag)
    }
}

/// Process-wide cache of the registry-derived notice, so the candidate
/// window's per-show read is a mutex lock rather than registry I/O.
static NOTICE: Mutex<Option<Notice>> = Mutex::new(None);
static CHECK_IN_FLIGHT: AtomicBool = AtomicBool::new(false);
/// Whether this process is one of the secure desktop's: the IME has been
/// activated in secure mode here (`on_activate`). Set once and for the life
/// of the process — it does not move to a user's desktop — and while it is
/// set there is no check, no notice, and nothing is started.
static SECURE: AtomicBool = AtomicBool::new(false);

// HKCU state, shared by every host process. The key is created on first
// write; reads of a missing value fall back to defaults. The user's opt-out
// is a switch beside it (jd_userdict::switch).
const REG_KEY: PCWSTR = w!(r"Software\hronro\ime-jd");
/// QWORD, Unix seconds of the last check (attempted, not necessarily successful).
const REG_LAST_CHECK: PCWSTR = w!("LastUpdateCheck");
/// SZ, the newest tag the feed reported.
const REG_LATEST: PCWSTR = w!("LatestVersion");
/// SZ, the tag whose notice the user clicked.
const REG_SEEN: PCWSTR = w!("SeenVersion");

/// Called from `ITfTextInputProcessorEx::ActivateEx`, i.e. whenever the user
/// switches to 键道 in some application. Refreshes the cached notice from the
/// registry and, if a check is due, runs one in the background. `secure`
/// says that this is the secure desktop (tip.rs), where it does neither.
pub fn on_activate(secure: bool) {
    if secure {
        SECURE.store(true, Ordering::SeqCst);
    }
    if SECURE.load(Ordering::SeqCst) {
        return;
    }
    refresh_notice();

    if !jd_userdict::switch::checks_for_updates() || host::is_app_container() {
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

/// The notice to draw, if any — never on the secure desktop. Cheap; read on
/// every candidate-window show.
pub fn pending_notice() -> Option<Notice> {
    if SECURE.load(Ordering::SeqCst) {
        return None;
    }
    NOTICE.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// The user clicked the notice: retire it (here and, via the registry, in
/// every other host) and download + verify + install the new version off the
/// UI thread. Falls back to opening the release page on any failure, or from
/// an AppContainer host, which can neither reach the network on our behalf
/// nor elevate. On the secure desktop there is no notice to click, and a
/// click does nothing.
pub fn open_notice(notice: &Notice) {
    if SECURE.load(Ordering::SeqCst) {
        return;
    }
    write_sz(REG_SEEN, &notice.tag);
    *NOTICE.lock().unwrap_or_else(|e| e.into_inner()) = None;
    if host::is_app_container() {
        open_url(&notice.url);
        return;
    }
    let page = notice.url.clone();
    let spawned = std::thread::Builder::new()
        .name("jd-update-install".into())
        .spawn(move || install_update(&page));
    if spawned.is_err() {
        open_url(&notice.url);
    }
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

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
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

// ---- Download + verify + install ------------------------------------------

/// Background-thread worker: install the latest release, or open `page` if any
/// step fails so the user can still upgrade by hand.
fn install_update(page: &str) {
    if try_install().is_none() {
        open_url(page);
    }
}

/// Re-fetch the feed, download the release zip for this machine, verify it,
/// and have the installed `update.bat` install it, elevated. `None` at the
/// first failure.
fn try_install() -> Option<()> {
    // Nothing is downloaded that could not be installed.
    let script = installed_updater()?;
    let json = fetch_feed()?;
    let tag = feed::extract_tag(&json)?;
    let current = Version::parse(CURRENT_VERSION)?;
    if Version::parse(&tag)? <= current {
        return None;
    }
    let arch = feed::installer_arch(host::native_machine()?)?;
    let asset = feed::extract_asset(&json, &feed::installer_name(&tag, arch))?;

    let bytes = download(&asset.url)?;
    if asset.size != 0 && bytes.len() as u64 != asset.size {
        return None;
    }
    let sha256 = sha256_hex(&bytes)?;
    if let Some(expected) = &asset.sha256
        && sha256 != *expected
    {
        return None;
    }

    // The zip waits in the user's temporary folder, under a name of our own
    // choosing: nothing the feed says goes into a path or a command line.
    // What `update.bat` unpacks is what has this SHA-256, whatever lies
    // here by the time it looks.
    let dir = std::env::temp_dir().join("ime-jd-update");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).ok()?;
    let zip = dir.join("update.zip");
    std::fs::write(&zip, &bytes).ok()?;
    let started = updater_parameters(&script, &zip, &sha256)
        .is_some_and(|parameters| run_elevated(&parameters, script.parent()));
    if !started {
        let _ = std::fs::remove_dir_all(&dir);
    }
    started.then_some(())
}

/// The script that installs a downloaded release, installed beside this DLL
/// (windows/update.bat).
const UPDATER: &str = "update.bat";

/// `update.bat` beside this DLL — if this DLL is where register.bat puts
/// the two: in a folder under Program Files, which only an administrator
/// can write. Anywhere else the script could be anyone's by now, and it is
/// not run elevated.
fn installed_updater() -> Option<PathBuf> {
    let script = crate::beside_dll(UPDATER)?;
    is_within(script.parent()?, &program_files()?).then_some(script)
}

/// The folder 64-bit programs are installed in, as the machine's registry
/// has it: not the environment's word for it, which a user's own variables
/// can change, and not this process's, a 32-bit application's Program Files
/// being another folder.
fn program_files() -> Option<PathBuf> {
    let mut key = HKEY::default();
    // SAFETY: plain registry calls; the key is closed, and the buffer's
    // size is passed along with it.
    unsafe {
        RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            w!(r"SOFTWARE\Microsoft\Windows\CurrentVersion"),
            None,
            KEY_QUERY_VALUE | KEY_WOW64_64KEY,
            &mut key,
        )
        .ok()
        .ok()?;
        let mut buf = [0u16; 512];
        let mut size = size_of_val(&buf) as u32;
        let read = RegGetValueW(
            key,
            PCWSTR::null(),
            w!("ProgramFilesDir"),
            RRF_RT_REG_SZ,
            None,
            Some(buf.as_mut_ptr() as *mut c_void),
            Some(&mut size),
        );
        let _ = RegCloseKey(key);
        read.ok().ok()?;
        let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
        (end > 0).then(|| PathBuf::from(String::from_utf16_lossy(&buf[..end])))
    }
}

/// Whether `path` is `folder` or lies in it, letter case aside.
fn is_within(path: &Path, folder: &Path) -> bool {
    let mut path = path.components();
    folder.components().all(|part| {
        path.next().is_some_and(|own| {
            own.as_os_str()
                .to_string_lossy()
                .eq_ignore_ascii_case(&part.as_os_str().to_string_lossy())
        })
    })
}

/// What cmd is started with to run `script` on the downloaded `zip`:
/// `/d /s /c ""<script>" "<zip>" <sha256>"` — `/d`, so that no AutoRun
/// command from the user's registry runs elevated before it, and `/s`, so
/// that the outer quotes are the ones cmd takes off. `None` if a path has a
/// character that would not stay inside its quotes: a quote, or `%` and
/// `!`, which cmd expands even there — and the temporary folder is wherever
/// the user's environment says it is.
fn updater_parameters(script: &Path, zip: &Path, sha256: &str) -> Option<String> {
    let quoted = |path: &Path| {
        let text = path.to_str()?;
        let stays_quoted = !text.contains(|c: char| matches!(c, '"' | '%' | '!') || c.is_control());
        stays_quoted.then(|| format!("\"{text}\""))
    };
    if sha256.len() != 64 || !sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    Some(format!(
        "/d /s /c \"{} {} {sha256}\"",
        quoted(script)?,
        quoted(zip)?
    ))
}

/// GET a URL into memory, following GitHub's github.com → objects.github…
/// redirect (WinHTTP does this itself). `None` on failure or oversized body.
fn download(url: &str) -> Option<Vec<u8>> {
    let (host, path) = feed::split_https_url(url)?;
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
        let result = download_with_session(session, host, path);
        let _ = WinHttpCloseHandle(session);
        result
    }
}

unsafe fn download_with_session(session: *mut c_void, host: &str, path: &str) -> Option<Vec<u8>> {
    unsafe {
        // resolve / connect / send / receive, ms. The download can be big, so
        // the receive/read budget is longer than the feed's.
        let _ = WinHttpSetTimeouts(session, 10_000, 10_000, 30_000, 60_000);
        let host_w = wide_z(host);
        let connect = WinHttpConnect(
            session,
            PCWSTR(host_w.as_ptr()),
            INTERNET_DEFAULT_HTTPS_PORT,
            0,
        );
        if connect.is_null() {
            return None;
        }
        let result = download_with_connection(connect, path);
        let _ = WinHttpCloseHandle(connect);
        result
    }
}

unsafe fn download_with_connection(connect: *mut c_void, path: &str) -> Option<Vec<u8>> {
    unsafe {
        let path_w = wide_z(path);
        let request = WinHttpOpenRequest(
            connect,
            w!("GET"),
            PCWSTR(path_w.as_ptr()),
            PCWSTR::null(),
            PCWSTR::null(),
            std::ptr::null(),
            WINHTTP_FLAG_SECURE,
        );
        if request.is_null() {
            return None;
        }
        let result = read_body(request);
        let _ = WinHttpCloseHandle(request);
        result
    }
}

/// Send the request and read the whole body (WinHTTP follows the redirect on
/// its own). `None` unless the final status is 200 and the body fits.
unsafe fn read_body(request: *mut c_void) -> Option<Vec<u8>> {
    unsafe {
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

        // The IME zip is ~2 MB; the cap only guards against a runaway body.
        const MAX_DOWNLOAD: usize = 64 << 20;
        let mut body: Vec<u8> = Vec::new();
        loop {
            let mut available: u32 = 0;
            WinHttpQueryDataAvailable(request, &mut available).ok()?;
            if available == 0 {
                break;
            }
            let start = body.len();
            if start + available as usize > MAX_DOWNLOAD {
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
        Some(body)
    }
}

/// Lowercase-hex SHA-256 of `data` via CNG (BCrypt); `None` on any CNG error.
fn sha256_hex(data: &[u8]) -> Option<String> {
    unsafe {
        let mut alg = BCRYPT_ALG_HANDLE::default();
        if BCryptOpenAlgorithmProvider(
            &mut alg,
            BCRYPT_SHA256_ALGORITHM,
            PCWSTR::null(),
            BCRYPT_OPEN_ALGORITHM_PROVIDER_FLAGS(0),
        )
        .is_err()
        {
            return None;
        }
        let mut hash = BCRYPT_HASH_HANDLE::default();
        let mut digest = [0u8; 32];
        let ok = BCryptCreateHash(alg, &mut hash, None, None, 0).is_ok()
            && BCryptHashData(hash, data, 0).is_ok()
            && BCryptFinishHash(hash, &mut digest, 0).is_ok();
        let _ = BCryptDestroyHash(hash);
        let _ = BCryptCloseAlgorithmProvider(alg, 0);
        ok.then(|| digest.iter().map(|b| format!("{b:02x}")).collect())
    }
}

/// Start cmd elevated (the `runas` verb → one UAC prompt) with `parameters`,
/// in `dir`. True if the shell accepted the launch (the elevated script
/// then reports its own success or failure in its console). From a 32-bit
/// host the cmd that starts is the 32-bit one, and the script hands itself
/// over to the 64-bit one.
fn run_elevated(parameters: &str, dir: Option<&Path>) -> bool {
    // The system's cmd by its full path, from the system: neither
    // `%ComSpec%` nor a name for the shell to look up.
    let mut system = [0u16; 260];
    // SAFETY: the buffer's length goes with it.
    let len = unsafe { GetSystemDirectoryW(Some(&mut system)) } as usize;
    if len == 0 || len >= system.len() {
        return false;
    }
    let cmd = wide_z(&format!(
        "{}\\cmd.exe",
        String::from_utf16_lossy(&system[..len])
    ));
    let parameters = wide_z(parameters);
    let cwd = dir.map(|dir| wide_z(&dir.to_string_lossy()));
    let result = unsafe {
        ShellExecuteW(
            None,
            w!("runas"),
            PCWSTR(cmd.as_ptr()),
            PCWSTR(parameters.as_ptr()),
            cwd.as_ref()
                .map_or(PCWSTR::null(), |cwd| PCWSTR(cwd.as_ptr())),
            SW_SHOWNORMAL,
        )
    };
    // ShellExecuteW returns an HINSTANCE-shaped status; > 32 means success.
    result.0 as isize > 32
}

// ---- Registry (HKCU) -------------------------------------------------------

fn wide_z(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_is_offered_on_the_secure_desktop() {
        // A newer release on record, as after a check that found one.
        let notice = Notice {
            tag: "v9.9.9".into(),
            url: feed::release_page_url("v9.9.9"),
        };
        *NOTICE.lock().unwrap() = Some(notice.clone());
        assert_eq!(pending_notice(), Some(notice));

        // Activated in secure mode: no registry, no check — and no notice,
        // for as long as the process lives.
        on_activate(true);
        assert_eq!(pending_notice(), None);
        assert!(
            NOTICE.lock().unwrap().is_some(),
            "hidden, not looked up again"
        );
    }

    #[test]
    fn cmd_is_given_the_installed_script_the_zip_and_its_sha256() {
        let script = Path::new(r"C:\Program Files\ime-jd\update.bat");
        // Whatever a user's folder may be called, short of the three below.
        let zip =
            Path::new(r"C:\Users\张三 (x86) & co^\AppData\Local\Temp\ime-jd-update\update.zip");
        let sha256 = "0123456789abcdef".repeat(4);
        assert_eq!(
            updater_parameters(script, zip, &sha256),
            Some(format!(
                r#"/d /s /c ""C:\Program Files\ime-jd\update.bat" "C:\Users\张三 (x86) & co^\AppData\Local\Temp\ime-jd-update\update.zip" {sha256}""#
            ))
        );

        // A path cmd would read something else out of is not handed to it.
        for odd in [
            r#"C:\Temp\a"b\update.zip"#,
            r"C:\Temp\%X%\update.zip",
            r"C:\Temp\!X!\update.zip",
            "C:\\Temp\\a\nb\\update.zip",
        ] {
            assert_eq!(updater_parameters(script, Path::new(odd), &sha256), None);
            assert_eq!(updater_parameters(Path::new(odd), zip, &sha256), None);
        }
        // Nor is anything but a SHA-256.
        assert_eq!(updater_parameters(script, zip, "abc"), None);
        let padded = format!("{}&calc", &sha256[..59]);
        assert_eq!(updater_parameters(script, zip, &padded), None);
    }

    #[test]
    fn a_folder_holds_what_lies_in_it_whatever_the_letter_case() {
        let program_files = Path::new(r"C:\Program Files");
        let within = |path: &str| is_within(Path::new(path), program_files);
        assert!(within(r"C:\Program Files\ime-jd"));
        assert!(within(r"c:\PROGRAM FILES\ime-jd\"));
        assert!(within(r"C:\Program Files"));
        for elsewhere in [
            r"C:\Program Files (x86)\ime-jd",
            r"C:\Program Filesx\ime-jd",
            r"C:\Users\someone\Program Files\ime-jd",
            r"D:\Program Files\ime-jd",
            r"C:\",
        ] {
            assert!(!within(elsewhere), "{elsewhere}");
        }
    }

    #[test]
    fn program_files_is_the_64_bit_folder_whichever_dll_asks() {
        // On the 64-bit Windows the tests run on, in an i686 test build too.
        let folder = program_files().expect("the registry names it");
        assert!(folder.is_dir(), "{folder:?}");
        assert!(!folder.to_string_lossy().contains("(x86)"), "{folder:?}");
    }
}
