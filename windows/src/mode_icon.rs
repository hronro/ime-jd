//! The IME mode icon: the glyph Windows shows in the taskbar, beside the
//! input indicator, while 键道 is the input method of the window in front —
//! where Windows' own IMEs keep their settings. It is a TSF language-bar
//! item under the GUID Windows reserves for that spot (`GUID_LBI_INPUTMODE`),
//! added to a thread's language bar when the IME activates there (tip.rs)
//! and removed when it deactivates.
//!
//! 键道 has one input mode, so the icon is a plain 中 — drawn here at the
//! taskbar's scale, white on a dark taskbar and black on a light one, the
//! way Windows draws its own tray glyphs, and drawn again when the theme or
//! the scale changes. A click on it reaches the IME in the application in
//! front, whose window keeps the focus; a right click opens the menu there —
//! the user dictionary's window and switch, and the daily update check
//! (settings.rs) — and a left click, which would switch modes, does nothing. In a Store app the menu does not open — the window
//! in front belongs to another process — and a sandbox could change none of
//! it anyway (settings.rs again). Nor does it from the keyboard (Win+B),
//! which leaves the taskbar in front.

use std::cell::RefCell;
use std::ffi::c_void;

use windows::Win32::Foundation::{
    E_INVALIDARG, E_NOTIMPL, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM,
};
use windows::Win32::Graphics::Direct2D::Common::{
    D2D_RECT_F, D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_COLOR_F, D2D1_PIXEL_FORMAT,
};
use windows::Win32::Graphics::Direct2D::{
    D2D1_DRAW_TEXT_OPTIONS_NONE, D2D1_FACTORY_TYPE_SINGLE_THREADED, D2D1_FEATURE_LEVEL_DEFAULT,
    D2D1_RENDER_TARGET_PROPERTIES, D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1_RENDER_TARGET_USAGE_NONE,
    D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE, D2D1CreateFactory, ID2D1Factory,
};
use windows::Win32::Graphics::DirectWrite::{
    DWRITE_FACTORY_TYPE_SHARED, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL,
    DWRITE_FONT_WEIGHT_NORMAL, DWRITE_MEASURING_MODE_NATURAL, DWriteCreateFactory, IDWriteFactory,
    IDWriteFontCollection,
};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, COLOR_WINDOWTEXT, CreateBitmap, CreateCompatibleDC,
    CreateDIBSection, DIB_RGB_COLORS, DeleteDC, DeleteObject, GdiFlush, GetMonitorInfoW,
    GetSysColor, HBITMAP, MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromPoint, SelectObject,
};
use windows::Win32::System::Ole::{
    CONNECT_E_ADVISELIMIT, CONNECT_E_CANNOTCONNECT, CONNECT_E_NOCONNECTION,
};
use windows::Win32::UI::Accessibility::{HCF_HIGHCONTRASTON, HIGHCONTRASTW};
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForSystem, GetDpiForWindow,
    SetThreadDpiAwarenessContext,
};
use windows::Win32::UI::TextServices::{
    GUID_LBI_INPUTMODE, ITfLangBarItem, ITfLangBarItem_Impl, ITfLangBarItemButton,
    ITfLangBarItemButton_Impl, ITfLangBarItemMgr, ITfLangBarItemSink, ITfMenu, ITfSource,
    ITfSource_Impl, ITfThreadMgr, TF_LANGBARITEMINFO, TF_LBI_ICON, TF_LBI_STYLE_BTN_BUTTON,
    TF_LBI_CLK_RIGHT, TF_LBI_STYLE_SHOWNINTRAY, TfLBIClick,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreateIconIndirect, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu,
    DestroyWindow, FindWindowW, HICON, ICONINFO, MF_CHECKED, MF_GRAYED, MF_SEPARATOR, MF_STRING,
    PostMessageW, RegisterClassExW, SPI_GETHIGHCONTRAST, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
    SystemParametersInfoW, TPM_BOTTOMALIGN, TPM_LEFTALIGN, TPM_NONOTIFY, TPM_RETURNCMD,
    TPM_RIGHTALIGN, TPM_RIGHTBUTTON, TPM_TOPALIGN, TPM_WORKAREA, TRACK_POPUP_MENU_FLAGS,
    TrackPopupMenuEx, WM_DISPLAYCHANGE, WM_DPICHANGED, WM_NULL, WM_SETTINGCHANGE, WNDCLASSEXW,
    WS_EX_TOOLWINDOW, WS_POPUP,
};
use windows::core::{
    BOOL, BSTR, ComObject, GUID, IUnknown, Interface, PCWSTR, Ref, Result, implement, w,
};

use crate::candidate_window::read_hkcu_dword;
use crate::{dll_hmodule, guids, host, settings};

/// The glyph: 键道's one input mode is Chinese.
const GLYPH: &str = "中";
const FONT_FAMILY: PCWSTR = w!("Microsoft YaHei UI");
/// The mode icon's size at 100% scale, from Microsoft's IME guidelines; it
/// grows with the taskbar's DPI.
const ICON_SIZE: i32 = 16;
/// The glyph's em size, as a share of the icon: Windows' own tray glyphs
/// leave about a pixel either side.
const GLYPH_SCALE: f32 = 0.875;

const DESCRIPTION: &str = "键道";
const TOOLTIP: &str = "键道输入法";

const OWNER_CLASS: PCWSTR = w!("JdImeModeIconOwner");

// The menu's items.
const ITEM_USER_DICT_WINDOW: u32 = 1;
const ITEM_USER_DICT: u32 = 2;
const ITEM_UPDATE_CHECKS: u32 = 3;

/// The one connection `ITfSource` hands out: TSF's sink for this item.
const SINK_COOKIE: u32 = 1;

#[implement(ITfLangBarItemButton, ITfLangBarItem, ITfSource)]
struct ModeIcon {
    sink: RefCell<Option<ITfLangBarItemSink>>,
    /// The secure desktop (the sign-in screen, a UAC prompt): nothing there
    /// may start a program, so the menu changes nothing.
    secure: bool,
}

/// The item on this thread's language bar, and the hidden window that owns
/// its menu and hears of theme and scale changes.
struct Active {
    item: ComObject<ModeIcon>,
    owner: HWND,
}

thread_local! {
    static ACTIVE: RefCell<Option<Active>> = const { RefCell::new(None) };
}

/// Put the mode icon on this thread's language bar.
pub fn add(thread_mgr: &ITfThreadMgr, secure: bool) {
    remove(thread_mgr);
    let Ok(manager) = thread_mgr.cast::<ITfLangBarItemMgr>() else {
        return;
    };
    let Some(owner) = create_owner() else {
        return;
    };
    let item = ComObject::new(ModeIcon {
        sink: RefCell::new(None),
        secure,
    });
    let button: ITfLangBarItemButton = item.to_interface();
    // SAFETY: a plain call; the bar holds its own reference to the item.
    if unsafe { manager.AddItem(&button) }.is_err() {
        // SAFETY: the window is this thread's own.
        unsafe {
            let _ = DestroyWindow(owner);
        }
        return;
    }
    ACTIVE.with(|active| *active.borrow_mut() = Some(Active { item, owner }));
}

/// Take it off again, at deactivation.
pub fn remove(thread_mgr: &ITfThreadMgr) {
    let Some(active) = ACTIVE.with(|active| active.borrow_mut().take()) else {
        return;
    };
    if let Ok(manager) = thread_mgr.cast::<ITfLangBarItemMgr>() {
        let button: ITfLangBarItemButton = active.item.to_interface();
        // SAFETY: a plain call.
        let _ = unsafe { manager.RemoveItem(&button) };
    }
    // SAFETY: the window is this thread's own.
    unsafe {
        let _ = DestroyWindow(active.owner);
    }
}

impl ITfLangBarItem_Impl for ModeIcon_Impl {
    fn GetInfo(&self, info: *mut TF_LANGBARITEMINFO) -> Result<()> {
        if info.is_null() {
            return Err(E_INVALIDARG.into());
        }
        let mut description = [0u16; 32];
        for (slot, unit) in description.iter_mut().zip(DESCRIPTION.encode_utf16()) {
            *slot = unit;
        }
        // SAFETY: TSF hands a struct to fill.
        unsafe {
            *info = TF_LANGBARITEMINFO {
                clsidService: guids::CLSID_JD_IME,
                guidItem: GUID_LBI_INPUTMODE,
                dwStyle: TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAY,
                ulSort: 0,
                szDescription: description,
            };
        }
        Ok(())
    }

    fn GetStatus(&self) -> Result<u32> {
        Ok(0)
    }

    fn Show(&self, _show: BOOL) -> Result<()> {
        Err(E_NOTIMPL.into())
    }

    fn GetTooltipString(&self) -> Result<BSTR> {
        Ok(BSTR::from(TOOLTIP))
    }
}

impl ITfLangBarItemButton_Impl for ModeIcon_Impl {
    /// The right button opens the menu. The left one switches an IME's
    /// mode, and 键道 has only the one, so it does nothing. The item's
    /// rectangle TSF passes is no help — its size is in another scale than
    /// its origin at 200% — but the point is where the click was.
    fn OnClick(&self, click: TfLBIClick, pt: &POINT, _area: *const RECT) -> Result<()> {
        if click == TF_LBI_CLK_RIGHT {
            show_menu(self.secure, *pt);
        }
        Ok(())
    }

    /// Only for a menu-style item, which this is not: the taskbar asks for
    /// its menu by clicking.
    fn InitMenu(&self, _menu: Ref<'_, ITfMenu>) -> Result<()> {
        Ok(())
    }

    fn OnMenuSelect(&self, _id: u32) -> Result<()> {
        Ok(())
    }

    fn GetIcon(&self) -> Result<HICON> {
        draw_icon(icon_size(), glyph_color())
    }

    fn GetText(&self) -> Result<BSTR> {
        Ok(BSTR::from(DESCRIPTION))
    }
}

impl ITfSource_Impl for ModeIcon_Impl {
    fn AdviseSink(&self, riid: *const GUID, punk: Ref<'_, IUnknown>) -> Result<u32> {
        // SAFETY: TSF passes a valid IID, or nothing.
        if unsafe { riid.as_ref() } != Some(&ITfLangBarItemSink::IID) {
            return Err(CONNECT_E_CANNOTCONNECT.into());
        }
        if self.sink.borrow().is_some() {
            return Err(CONNECT_E_ADVISELIMIT.into());
        }
        let sink: ITfLangBarItemSink = punk.ok()?.cast()?;
        *self.sink.borrow_mut() = Some(sink);
        Ok(SINK_COOKIE)
    }

    fn UnadviseSink(&self, cookie: u32) -> Result<()> {
        if cookie != SINK_COOKIE || self.sink.borrow_mut().take().is_none() {
            return Err(CONNECT_E_NOCONNECTION.into());
        }
        Ok(())
    }
}

// ---- The menu -----------------------------------------------------------

/// Show the menu by `at`, where the taskbar says the click was, and do what
/// is picked. Each item says what it does in the words the user
/// dictionary's window uses.
fn show_menu(secure: bool, at: POINT) {
    // A Store app could change none of it, nor show it: the window in front
    // belongs to another process.
    if host::is_app_container() {
        return;
    }
    let Some(owner) = ACTIVE.with(|active| active.borrow().as_ref().map(|active| active.owner))
    else {
        return;
    };
    let current = settings::current();
    let changeable = current.changeable && !secure;
    let flags = |checked: bool| {
        let mut flags = MF_STRING;
        if !changeable {
            flags |= MF_GRAYED;
        }
        if checked {
            flags |= MF_CHECKED;
        }
        flags
    };
    // SAFETY: a menu built, shown and destroyed on this thread, owned by
    // this thread's window.
    let chosen = unsafe {
        let Ok(menu) = CreatePopupMenu() else {
            return;
        };
        let _ = AppendMenuW(
            menu,
            flags(false),
            ITEM_USER_DICT_WINDOW as usize,
            w!("用户自造词(&U)..."),
        );
        let _ = AppendMenuW(
            menu,
            flags(current.user_dict),
            ITEM_USER_DICT as usize,
            w!("启用用户自造词(&Y)"),
        );
        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
        let _ = AppendMenuW(
            menu,
            flags(current.update_checks),
            ITEM_UPDATE_CHECKS as usize,
            w!("自动检查更新(&C)"),
        );

        // The taskbar's point is in physical pixels: so is the menu, scaled
        // for the monitor it opens on, whatever DPI awareness the host
        // declares.
        let previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let (x, y, alignment) = anchor(at);
        // A menu shows only from the thread in front, which a click on the
        // icon leaves in front: this one. Reached from the keyboard (Win+B),
        // the icon leaves the taskbar in front, and the taskbar does not let
        // this thread come forward, so the menu does not open; neither does
        // it in a Store app (above).
        let chosen = TrackPopupMenuEx(
            menu,
            (TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_WORKAREA | alignment).0,
            x,
            y,
            owner,
            None,
        );
        // The menu's owner is not the window in front, so it closes cleanly
        // only after its loop sees one more message.
        let _ = PostMessageW(Some(owner), WM_NULL, WPARAM(0), LPARAM(0));
        if !previous.0.is_null() {
            SetThreadDpiAwarenessContext(previous);
        }
        let _ = DestroyMenu(menu);
        chosen.0 as u32
    };
    match chosen {
        ITEM_USER_DICT_WINDOW => settings::open_user_dict_window(),
        ITEM_USER_DICT => settings::set_user_dict(!current.user_dict),
        ITEM_UPDATE_CHECKS => settings::set_update_checks(!current.update_checks),
        _ => {}
    }
}

/// Where the menu opens: at the click, moved out of the taskbar to the edge
/// of the work area beside it, and opening away from the taskbar — where the
/// notification area's icons open theirs.
///
/// # Safety
/// The thread is per-monitor DPI aware, like `at`.
unsafe fn anchor(at: POINT) -> (i32, i32, TRACK_POPUP_MENU_FLAGS) {
    let mut monitor = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    // SAFETY: the struct is the size it says it is.
    let found = unsafe {
        GetMonitorInfoW(MonitorFromPoint(at, MONITOR_DEFAULTTONEAREST), &mut monitor).as_bool()
    };
    if !found {
        return (at.x, at.y, TPM_LEFTALIGN | TPM_BOTTOMALIGN);
    }
    let work = monitor.rcWork;
    let (x, horizontal) = if at.x >= work.right {
        (work.right, TPM_RIGHTALIGN)
    } else if at.x < work.left {
        (work.left, TPM_LEFTALIGN)
    } else {
        (at.x, TPM_LEFTALIGN)
    };
    let (y, vertical) = if at.y >= work.bottom {
        (work.bottom, TPM_BOTTOMALIGN)
    } else if at.y < work.top {
        (work.top, TPM_TOPALIGN)
    } else {
        (at.y, TPM_BOTTOMALIGN)
    };
    (x, y, horizontal | vertical)
}

// ---- The owner window ----------------------------------------------------

/// A hidden top-level window of this thread: the menu needs an owner, and
/// theme and scale changes are broadcast to top-level windows only.
fn create_owner() -> Option<HWND> {
    use std::sync::atomic::{AtomicBool, Ordering};
    static REGISTERED: AtomicBool = AtomicBool::new(false);
    // SAFETY: class registration and window creation on this thread; the
    // DPI context is put back at once.
    unsafe {
        if !REGISTERED.swap(true, Ordering::SeqCst) {
            let class = WNDCLASSEXW {
                cbSize: size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(owner_proc),
                hInstance: dll_hmodule().into(),
                lpszClassName: OWNER_CLASS,
                ..Default::default()
            };
            RegisterClassExW(&class);
        }
        // Per-monitor, like the menu it owns.
        let previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let owner = CreateWindowExW(
            WS_EX_TOOLWINDOW,
            OWNER_CLASS,
            PCWSTR::null(),
            WS_POPUP,
            0,
            0,
            0,
            0,
            None,
            None,
            Some(dll_hmodule().into()),
            None,
        );
        if !previous.0.is_null() {
            SetThreadDpiAwarenessContext(previous);
        }
        owner.ok()
    }
}

extern "system" fn owner_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if matches!(msg, WM_SETTINGCHANGE | WM_DISPLAYCHANGE | WM_DPICHANGED) {
        // The taskbar may have changed colour or scale: have TSF ask for the
        // icon again.
        let sink = ACTIVE.with(|active| {
            active
                .borrow()
                .as_ref()
                .and_then(|active| active.item.sink.borrow().clone())
        });
        if let Some(sink) = sink {
            // SAFETY: a plain call on TSF's sink.
            let _ = unsafe { sink.OnUpdate(TF_LBI_ICON) };
        }
    }
    // SAFETY: the default handling of this window's own message.
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

// ---- The icon -------------------------------------------------------------

/// The icon's size in pixels: the guidelines' 16 at the taskbar's scale.
fn icon_size() -> i32 {
    // SAFETY: plain window and DPI queries.
    let dpi = unsafe {
        match FindWindowW(w!("Shell_TrayWnd"), PCWSTR::null()) {
            Ok(taskbar) => GetDpiForWindow(taskbar),
            Err(_) => 0,
        }
    };
    // SAFETY: a plain DPI query.
    let dpi = if dpi == 0 {
        unsafe { GetDpiForSystem() }
    } else {
        dpi
    };
    (ICON_SIZE * dpi as i32 + 48) / 96
}

/// The colour of the taskbar's own glyphs: a high-contrast theme's text
/// colour, else white on a dark taskbar and black on a light one.
fn glyph_color() -> D2D1_COLOR_F {
    if high_contrast() {
        // SAFETY: GetSysColor only reads.
        let rgb = unsafe { GetSysColor(COLOR_WINDOWTEXT) };
        let channel = |shift: u32| ((rgb >> shift) & 0xFF) as f32 / 255.0;
        return D2D1_COLOR_F {
            r: channel(0),
            g: channel(8),
            b: channel(16),
            a: 1.0,
        };
    }
    let light = read_hkcu_dword(
        w!(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"),
        w!("SystemUsesLightTheme"),
    ) == Some(1);
    let level = if light { 0.0 } else { 1.0 };
    D2D1_COLOR_F {
        r: level,
        g: level,
        b: level,
        a: 1.0,
    }
}

fn high_contrast() -> bool {
    let mut contrast = HIGHCONTRASTW {
        cbSize: size_of::<HIGHCONTRASTW>() as u32,
        ..Default::default()
    };
    // SAFETY: the struct is the size it says it is.
    unsafe {
        SystemParametersInfoW(
            SPI_GETHIGHCONTRAST,
            contrast.cbSize,
            Some(&mut contrast as *mut HIGHCONTRASTW as *mut c_void),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
        .is_ok()
            && contrast.dwFlags & HCF_HIGHCONTRASTON == HCF_HIGHCONTRASTON
    }
}

/// The glyph on a transparent square of `size` pixels, centred on its ink,
/// as an icon the caller owns.
fn draw_icon(size: i32, color: D2D1_COLOR_F) -> Result<HICON> {
    let pixels = (size * size) as usize;
    // SAFETY: a DIB section drawn into through a DC render target, read
    // back after GdiFlush, and every GDI object released before returning;
    // CreateIconIndirect copies the bitmaps.
    unsafe {
        let dc = CreateCompatibleDC(None);
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: size,
                // Top-down rows.
                biHeight: -size,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut c_void = std::ptr::null_mut();
        let color_bitmap =
            match CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
                Ok(bitmap) => bitmap,
                Err(error) => {
                    let _ = DeleteDC(dc);
                    return Err(error);
                }
            };
        let previous = SelectObject(dc, color_bitmap.into());
        let drawn = draw_glyph(dc, size, color);
        SelectObject(dc, previous);
        let _ = DeleteDC(dc);
        if let Err(error) = drawn {
            let _ = DeleteObject(color_bitmap.into());
            return Err(error);
        }
        let _ = GdiFlush();

        let bgra = std::slice::from_raw_parts_mut(bits as *mut u8, pixels * 4);
        center_ink(bgra, size as usize);
        // Direct2D leaves premultiplied colour; an icon's is straight.
        for pixel in bgra.as_chunks_mut::<4>().0 {
            let alpha = u32::from(pixel[3]);
            if alpha != 0 && alpha != 255 {
                for channel in &mut pixel[..3] {
                    *channel = ((u32::from(*channel) * 255 + alpha / 2) / alpha).min(255) as u8;
                }
            }
        }

        // A mask of zeros, its rows padded to whole 16-bit words: the alpha
        // channel decides.
        let mask_bits = vec![0u8; (size as usize).div_ceil(16) * 2 * size as usize];
        let mask: HBITMAP =
            CreateBitmap(size, size, 1, 1, Some(mask_bits.as_ptr() as *const c_void));
        let icon = CreateIconIndirect(&ICONINFO {
            fIcon: true.into(),
            xHotspot: 0,
            yHotspot: 0,
            hbmMask: mask,
            hbmColor: color_bitmap,
        });
        let _ = DeleteObject(mask.into());
        let _ = DeleteObject(color_bitmap.into());
        icon
    }
}

/// Move a drawing of `size` square BGRA pixels so its ink sits in the
/// middle: the font's measurements and the rasterizer's grid fitting can
/// disagree by a pixel or two, and in a 16-pixel icon that shows.
fn center_ink(bgra: &mut [u8], size: usize) {
    let inked = |x: usize, y: usize| bgra[(y * size + x) * 4 + 3] != 0;
    let (mut left, mut right, mut top, mut bottom) = (size, 0, size, 0);
    for y in 0..size {
        for x in 0..size {
            if inked(x, y) {
                left = left.min(x);
                right = right.max(x);
                top = top.min(y);
                bottom = bottom.max(y);
            }
        }
    }
    if left > right {
        return;
    }
    // Half the difference between the margins, toward the larger one.
    let dx = ((size - 1 - right) as isize - left as isize) / 2;
    let dy = ((size - 1 - bottom) as isize - top as isize) / 2;
    if dx == 0 && dy == 0 {
        return;
    }
    let source = bgra.to_vec();
    bgra.fill(0);
    for y in top..=bottom {
        for x in left..=right {
            let from = (y * size + x) * 4;
            let to = (((y as isize + dy) as usize) * size + (x as isize + dx) as usize) * 4;
            bgra[to..to + 4].copy_from_slice(&source[from..from + 4]);
        }
    }
}

/// Draw the glyph into the 32-bit bitmap selected into `dc`.
///
/// # Safety
/// `dc` has a `size`-square 32-bit DIB section selected.
unsafe fn draw_glyph(
    dc: windows::Win32::Graphics::Gdi::HDC,
    size: i32,
    color: D2D1_COLOR_F,
) -> Result<()> {
    unsafe {
        let factory: ID2D1Factory = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
        let target = factory.CreateDCRenderTarget(&D2D1_RENDER_TARGET_PROPERTIES {
            r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
            pixelFormat: D2D1_PIXEL_FORMAT {
                format: DXGI_FORMAT_B8G8R8A8_UNORM,
                alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            // One DIP to the pixel.
            dpiX: 96.0,
            dpiY: 96.0,
            usage: D2D1_RENDER_TARGET_USAGE_NONE,
            minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
        })?;
        target.BindDC(
            dc,
            &RECT {
                left: 0,
                top: 0,
                right: size,
                bottom: size,
            },
        )?;
        // ClearType needs an opaque background; this one is transparent.
        target.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);

        let dwrite: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
        let format = dwrite.CreateTextFormat(
            FONT_FAMILY,
            None::<&IDWriteFontCollection>,
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            size as f32 * GLYPH_SCALE,
            w!("zh-CN"),
        )?;
        let text: Vec<u16> = GLYPH.encode_utf16().collect();
        let side = size as f32;
        let layout = dwrite.CreateTextLayout(&text, &format, side, side)?;
        // How far the ink reaches past the layout box on each side; centre
        // the ink itself, on whole pixels so the strokes stay crisp.
        let overhang = layout.GetOverhangMetrics()?;
        let ink_width = side + overhang.left + overhang.right;
        let ink_height = side + overhang.top + overhang.bottom;
        let x = ((side - ink_width) / 2.0 + overhang.left).round();
        let y = ((side - ink_height) / 2.0 + overhang.top).round();

        let brush = target.CreateSolidColorBrush(&color, None)?;
        target.BeginDraw();
        target.Clear(Some(&D2D1_COLOR_F {
            r: 0.0,
            g: 0.0,
            b: 0.0,
            a: 0.0,
        }));
        // The same layout as measured, moved by the offset.
        target.DrawText(
            &text,
            &format,
            &D2D_RECT_F {
                left: x,
                top: y,
                right: x + side,
                bottom: y + side,
            },
            &brush,
            D2D1_DRAW_TEXT_OPTIONS_NONE,
            DWRITE_MEASURING_MODE_NATURAL,
        );
        target.EndDraw(None, None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::Graphics::Gdi::{GetDC, GetDIBits, ReleaseDC};
    use windows::Win32::UI::WindowsAndMessaging::{DestroyIcon, GetIconInfo};

    /// The icon's alpha channel, row by row.
    fn alpha(icon: HICON, size: i32) -> Vec<u8> {
        let mut info = ICONINFO::default();
        let mut bgra = vec![0u8; (size * size * 4) as usize];
        // SAFETY: the bitmaps GetIconInfo makes are ours to read and delete.
        unsafe {
            GetIconInfo(icon, &mut info).unwrap();
            let mut header = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: size,
                    biHeight: -size,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let screen = GetDC(None);
            let rows = GetDIBits(
                screen,
                info.hbmColor,
                0,
                size as u32,
                Some(bgra.as_mut_ptr() as *mut c_void),
                &mut header,
                DIB_RGB_COLORS,
            );
            ReleaseDC(None, screen);
            let _ = DeleteObject(info.hbmColor.into());
            let _ = DeleteObject(info.hbmMask.into());
            assert_eq!(rows, size);
        }
        bgra.as_chunks::<4>().0.iter().map(|pixel| pixel[3]).collect()
    }

    #[test]
    fn the_glyph_is_drawn_centred_at_every_scale() {
        let white = D2D1_COLOR_F {
            r: 1.0,
            g: 1.0,
            b: 1.0,
            a: 1.0,
        };
        for size in [16, 20, 24, 32, 40, 48] {
            let icon = draw_icon(size, white).unwrap();
            let alpha = alpha(icon, size);
            // SAFETY: the icon is ours.
            unsafe { DestroyIcon(icon).unwrap() };

            let inked: Vec<(i32, i32)> = (0..size * size)
                .filter(|&i| alpha[i as usize] > 64)
                .map(|i| (i % size, i / size))
                .collect();
            // Shown with --nocapture: the smallest size is the one to judge.
            if size == 16 {
                for row in alpha.chunks(size as usize) {
                    let line: String = row
                        .iter()
                        .map(|&a| match a {
                            0..=31 => ' ',
                            32..=127 => '.',
                            128..=223 => '+',
                            _ => '#',
                        })
                        .collect();
                    println!("|{line}|");
                }
            }
            assert!(!inked.is_empty(), "{size}px: no ink");
            let (left, right) = (
                inked.iter().map(|p| p.0).min().unwrap(),
                inked.iter().map(|p| p.0).max().unwrap(),
            );
            let (top, bottom) = (
                inked.iter().map(|p| p.1).min().unwrap(),
                inked.iter().map(|p| p.1).max().unwrap(),
            );
            // As much room on each side as on the other, give or take the
            // pixel an odd difference leaves.
            assert!(
                (left - (size - 1 - right)).abs() <= 1,
                "{size}px: ink {left}..{right} across"
            );
            assert!(
                (top - (size - 1 - bottom)).abs() <= 1,
                "{size}px: ink {top}..{bottom} down"
            );
            // And it fills the icon the way tray glyphs do.
            assert!(
                right - left + 1 >= size * 3 / 4,
                "{size}px: ink {left}..{right} too narrow"
            );
        }
    }
}
