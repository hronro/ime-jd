//! Horizontal candidate popup in the style of the Windows 11 Pinyin IME.
//!
//! Layout (DIPs):
//! ```text
//! ┌──────────────────────────────────────────────────┐
//! │ ▎1 你好   2 你号   3 拟好   4 倪浩   …  N XXX    │
//! └──────────────────────────────────────────────────┘
//! ```
//! - Single row, left-to-right. The first candidate is "active" (commits on
//!   space); it carries a subtle rounded highlight pill with a small
//!   accent-color bar on the pill's left edge — the Windows 11 selection
//!   style. Hovered candidates get a lighter pill.
//! - No buttons. Paging stays keyboard-only (PgUp/PgDn/`-`/`=`), keeping the
//!   popup minimal.
//! - Colors follow the system app theme (light/dark) and the user's accent
//!   color, re-read from the registry on every show so theme switches apply
//!   without restarting the host.
//! - DWM is asked for rounded corners. On Windows 11 that succeeds: the OS
//!   clips the window round and our hairline border is stroked with a
//!   matching radius. On Windows 10 the call fails (the attribute doesn't
//!   exist there) and the popup falls back to a sharp-cornered rectangle
//!   with the same hairline border — which is the native look of Windows
//!   10's own IME popup.
//!
//! One window per TIP UI thread; created lazily, destroyed in `Deactivate`.
//! D2D + DirectWrite render the body. The render target's DPI is set to the
//! window's DPI so coordinates can stay in DIPs end-to-end.

use std::cell::RefCell;
use std::sync::atomic::{AtomicBool, Ordering};

use windows::Win32::Foundation::{
    D2DERR_RECREATE_TARGET, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM,
};
use windows::Win32::Graphics::Direct2D::Common::{
    D2D_RECT_F, D2D_SIZE_U, D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_COLOR_F, D2D1_PIXEL_FORMAT,
};
use windows::Win32::Graphics::Direct2D::{
    D2D1_DRAW_TEXT_OPTIONS_NONE, D2D1_FACTORY_TYPE_SINGLE_THREADED, D2D1_FEATURE_LEVEL_DEFAULT,
    D2D1_HWND_RENDER_TARGET_PROPERTIES, D2D1_PRESENT_OPTIONS_NONE, D2D1_RENDER_TARGET_PROPERTIES,
    D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1_RENDER_TARGET_USAGE_NONE, D2D1_ROUNDED_RECT,
    D2D1CreateFactory, ID2D1Factory, ID2D1HwndRenderTarget, ID2D1SolidColorBrush,
};
use windows::Win32::Graphics::DirectWrite::{
    DWRITE_FACTORY_TYPE_SHARED, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL,
    DWRITE_FONT_WEIGHT_NORMAL, DWRITE_MEASURING_MODE_NATURAL, DWRITE_PARAGRAPH_ALIGNMENT_CENTER,
    DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_TEXT_METRICS, DWriteCreateFactory, IDWriteFactory,
    IDWriteFontCollection, IDWriteTextFormat, IDWriteTextLayout,
};
use windows::Win32::Graphics::Dwm::{
    DWM_WINDOW_CORNER_PREFERENCE, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND,
    DwmSetWindowAttribute,
};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::{HBRUSH, InvalidateRect, ValidateRect};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetFocus, TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent,
};
use windows::Win32::UI::TextServices::ITfContext;
use windows::Win32::UI::WindowsAndMessaging::{
    CS_DROPSHADOW, CS_HREDRAW, CS_IME, CS_VREDRAW, CreateWindowExW, DefWindowProcW, DestroyWindow,
    GetClientRect, HICON, IDC_ARROW, LoadCursorW, MA_NOACTIVATE, RegisterClassExW, SW_HIDE,
    SW_SHOWNOACTIVATE, SWP_NOACTIVATE, SWP_NOZORDER, SetWindowPos, ShowWindow, WM_LBUTTONDOWN,
    WM_MOUSEACTIVATE, WM_MOUSEMOVE, WM_PAINT, WNDCLASSEXW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
    WS_EX_TOPMOST, WS_POPUP,
};

// `WM_MOUSELEAVE` lives in `Win32::UI::Controls` in windows-rs, which would
// require adding the whole Controls feature flag just for one constant.
// Inline the value to avoid the dependency.
const WM_MOUSELEAVE: u32 = 0x02A3;
use windows::core::{PCWSTR, Result, w};

use crate::{composition, dll_hmodule, jd, ui_element};

const WINDOW_CLASS_NAME: PCWSTR = w!("JdImeCandidateWindow");
const FONT_FAMILY: PCWSTR = w!("Microsoft YaHei UI");
const FONT_LOCALE: PCWSTR = w!("zh-CN");
const FONT_SIZE: f32 = 16.0;

// Metrics (DIPs) modeled on the Windows 11 IME candidate window.
/// Height of one candidate's highlight pill.
const PILL_HEIGHT: f32 = 32.0;
const PILL_RADIUS: f32 = 4.0;
/// Horizontal padding inside a pill, each side.
const ITEM_PAD_X: f32 = 10.0;
/// Gap between the index digit and the candidate text.
const NUM_GAP: f32 = 6.0;
/// Gap between adjacent pills.
const ITEM_GAP: f32 = 2.0;
/// Margin between the window edge and the pills.
const EDGE_PAD_X: f32 = 4.0;
const EDGE_PAD_Y: f32 = 4.0;
const WINDOW_HEIGHT: f32 = PILL_HEIGHT + 2.0 * EDGE_PAD_Y;
/// Accent selection-indicator bar on the active pill's left edge.
const SEL_BAR_WIDTH: f32 = 3.0;
const SEL_BAR_HEIGHT: f32 = 16.0;
/// Radius the border stroke follows on Windows 11; DWMWCP_ROUND clips the
/// window to the same 8-DIP curve, so the hairline hugs the visible edge.
const CORNER_RADIUS: f32 = 8.0;

#[derive(Debug, Default, Clone)]
pub struct CandidateItem {
    pub value: String,
    pub hint: Option<String>,
}

/// Per-item layout produced by `relayout`: the pill rect (highlight + hit
/// target) plus the measured widths needed to place the text runs inside it.
#[derive(Debug, Default, Clone, Copy)]
struct ItemLayout {
    rect: D2D_RECT_F,
    num_w: f32,
    value_w: f32,
}

/// Theme-derived colors, WinUI flyout tokens. Detected from the registry at
/// window creation and refreshed on every `show_at`.
#[derive(Debug, Clone, Copy)]
struct Palette {
    bg: D2D1_COLOR_F,
    border: D2D1_COLOR_F,
    text: D2D1_COLOR_F,
    text_secondary: D2D1_COLOR_F,
    selected_fill: D2D1_COLOR_F,
    hover_fill: D2D1_COLOR_F,
    accent: D2D1_COLOR_F,
}

struct CandidateWindow {
    hwnd: HWND,
    d2d: ID2D1Factory,
    dwrite: IDWriteFactory,
    text_format: IDWriteTextFormat,
    render_target: Option<ID2D1HwndRenderTarget>,
    items: Vec<CandidateItem>,
    /// Pill rects in DIPs, parallel to `items`.
    item_layouts: Vec<ItemLayout>,
    palette: Palette,
    /// Whether DWM accepted the rounded-corner preference (Windows 11).
    /// Decides if the border stroke follows a rounded or square outline.
    rounded_corners: bool,
    /// Context + client-ID stashed at show time so the async click handler
    /// can request an edit session to commit on click.
    ctx: Option<ITfContext>,
    tid: u32,
    /// Candidate index the mouse is currently over, if any. Repainted
    /// whenever it changes.
    hover: Option<usize>,
    /// Once we call TrackMouseEvent for TME_LEAVE we get exactly one
    /// WM_MOUSELEAVE; flip this to know whether we need to re-arm.
    tracking_leave: bool,
}

impl CandidateWindow {
    fn new() -> Result<Self> {
        ensure_class_registered();

        let d2d: ID2D1Factory =
            unsafe { D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None) }?;
        let dwrite: IDWriteFactory = unsafe { DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED) }?;
        let text_format = make_text_format(&dwrite)?;

        let hinstance = dll_hmodule();
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST,
                WINDOW_CLASS_NAME,
                PCWSTR::null(),
                WS_POPUP,
                0,
                0,
                100,
                WINDOW_HEIGHT as i32,
                None,
                None,
                Some(hinstance.into()),
                None,
            )
        }?;

        // Rounded corners on Windows 11. On Windows 10 the attribute doesn't
        // exist and the call fails with E_INVALIDARG — we use that as the
        // version probe: square window there, and paint() strokes a square
        // border to match.
        let pref: DWM_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND;
        let rounded_corners = unsafe {
            DwmSetWindowAttribute(
                hwnd,
                DWMWA_WINDOW_CORNER_PREFERENCE,
                &pref as *const _ as *const _,
                std::mem::size_of::<DWM_WINDOW_CORNER_PREFERENCE>() as u32,
            )
        }
        .is_ok();

        Ok(Self {
            hwnd,
            d2d,
            dwrite,
            text_format,
            render_target: None,
            items: Vec::new(),
            item_layouts: Vec::new(),
            palette: detect_palette(),
            rounded_corners,
            ctx: None,
            tid: 0,
            hover: None,
            tracking_leave: false,
        })
    }

    fn dpi(&self) -> f32 {
        let d = unsafe { GetDpiForWindow(self.hwnd) };
        if d == 0 { 96.0 } else { d as f32 }
    }

    fn ensure_render_target(&mut self, width: u32, height: u32) -> Result<()> {
        if self.render_target.is_some() {
            return Ok(());
        }
        let dpi = self.dpi();
        let rt_props = D2D1_RENDER_TARGET_PROPERTIES {
            r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
            pixelFormat: D2D1_PIXEL_FORMAT {
                format: DXGI_FORMAT_B8G8R8A8_UNORM,
                alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            dpiX: dpi,
            dpiY: dpi,
            usage: D2D1_RENDER_TARGET_USAGE_NONE,
            minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
        };
        let hwnd_props = D2D1_HWND_RENDER_TARGET_PROPERTIES {
            hwnd: self.hwnd,
            pixelSize: D2D_SIZE_U { width, height },
            presentOptions: D2D1_PRESENT_OPTIONS_NONE,
        };
        let rt = unsafe { self.d2d.CreateHwndRenderTarget(&rt_props, &hwnd_props) }?;
        self.render_target = Some(rt);
        Ok(())
    }

    /// Re-layout: measure each item's runs (index digit, value, optional
    /// hint), place its pill left-to-right, cache the layout for painting
    /// and hit-testing. Returns the resulting total popup width in DIPs.
    fn relayout(&mut self) -> Result<f32> {
        self.item_layouts.clear();
        if self.items.is_empty() {
            return Ok(80.0);
        }
        let mut x = EDGE_PAD_X;
        for (i, item) in self.items.iter().enumerate() {
            if i > 0 {
                x += ITEM_GAP;
            }
            let num_w = measure_text(&self.dwrite, &self.text_format, &(i + 1).to_string())?;
            let value_w = measure_text(&self.dwrite, &self.text_format, &item.value)?;
            let hint_w = match &item.hint {
                Some(h) => measure_text(&self.dwrite, &self.text_format, &format_hint(h))?,
                None => 0.0,
            };
            let pill_w = ITEM_PAD_X + num_w + NUM_GAP + value_w + hint_w + ITEM_PAD_X;
            self.item_layouts.push(ItemLayout {
                rect: D2D_RECT_F {
                    left: x,
                    top: EDGE_PAD_Y,
                    right: x + pill_w,
                    bottom: EDGE_PAD_Y + PILL_HEIGHT,
                },
                num_w,
                value_w,
            });
            x += pill_w;
        }
        Ok(x + EDGE_PAD_X)
    }

    fn show_at(
        &mut self,
        screen_pos: POINT,
        items: Vec<CandidateItem>,
        ctx: ITfContext,
        tid: u32,
    ) -> Result<()> {
        self.items = items;
        self.ctx = Some(ctx);
        self.tid = tid;
        // Items changed — drop any stale hover; the cursor may now be
        // over a different candidate or off the popup entirely.
        self.hover = None;
        // Cheap registry reads — keeps the popup in sync with live theme
        // and accent-color changes.
        self.palette = detect_palette();

        let width_dip = self.relayout()?;
        let scale = self.dpi() / 96.0;
        let width_px = (width_dip * scale).ceil() as i32;
        let height_px = (WINDOW_HEIGHT * scale).ceil() as i32;

        self.render_target = None;

        unsafe {
            SetWindowPos(
                self.hwnd,
                None,
                screen_pos.x,
                screen_pos.y,
                width_px,
                height_px,
                SWP_NOACTIVATE | SWP_NOZORDER,
            )
        }?;
        // When a UIElement-aware host has opted to render the candidate list
        // itself, leave the window hidden — we still keep `self.items` and
        // sizing fresh so flipping `is_shown` back on later re-renders cleanly.
        if ui_element::is_shown() {
            let _ = unsafe { ShowWindow(self.hwnd, SW_SHOWNOACTIVATE) };
        } else {
            let _ = unsafe { ShowWindow(self.hwnd, SW_HIDE) };
        }
        unsafe {
            let _ = InvalidateRect(Some(self.hwnd), None, true);
        }
        Ok(())
    }

    fn hide(&mut self) {
        self.hover = None;
        self.tracking_leave = false;
        unsafe {
            let _ = ShowWindow(self.hwnd, SW_HIDE);
        }
    }

    fn paint(&mut self) -> Result<()> {
        let rect = unsafe {
            let mut r = RECT::default();
            GetClientRect(self.hwnd, &mut r)?;
            r
        };
        let width_px = (rect.right - rect.left).max(1) as u32;
        let height_px = (rect.bottom - rect.top).max(1) as u32;
        self.ensure_render_target(width_px, height_px)?;
        let rt = self.render_target.as_ref().unwrap().clone();

        let scale = self.dpi() / 96.0;
        let width = width_px as f32 / scale;
        let height = height_px as f32 / scale;
        let p = self.palette;

        unsafe {
            rt.BeginDraw();
            // Full-bleed background. On Windows 11 DWM clips the corners to
            // the rounded preference; on Windows 10 the window is square and
            // the fill covers it exactly (no transparent corners — a
            // non-layered window would render those as black).
            rt.Clear(Some(&p.bg));

            let text_brush = rt.CreateSolidColorBrush(&p.text, None)?;
            let secondary_brush = rt.CreateSolidColorBrush(&p.text_secondary, None)?;
            let accent_brush = rt.CreateSolidColorBrush(&p.accent, None)?;

            // Active (first) candidate: highlight pill + accent bar on its
            // left edge, vertically centered — the Windows 11 selection look.
            if let Some(first) = self.item_layouts.first() {
                let selected_brush = rt.CreateSolidColorBrush(&p.selected_fill, None)?;
                rt.FillRoundedRectangle(&rounded(first.rect, PILL_RADIUS), &selected_brush);
                let bar = D2D_RECT_F {
                    left: first.rect.left,
                    top: first.rect.top + (PILL_HEIGHT - SEL_BAR_HEIGHT) / 2.0,
                    right: first.rect.left + SEL_BAR_WIDTH,
                    bottom: first.rect.top + (PILL_HEIGHT + SEL_BAR_HEIGHT) / 2.0,
                };
                rt.FillRoundedRectangle(&rounded(bar, SEL_BAR_WIDTH / 2.0), &accent_brush);
            }

            // Hover pill on any other candidate (the active one already has
            // the stronger selected fill).
            if let Some(i) = self.hover
                && i != 0
                && let Some(layout) = self.item_layouts.get(i)
            {
                let hover_brush = rt.CreateSolidColorBrush(&p.hover_fill, None)?;
                rt.FillRoundedRectangle(&rounded(layout.rect, PILL_RADIUS), &hover_brush);
            }

            // Text runs — index digit in the secondary color, the candidate
            // value in the primary color, the optional hint dim again
            // (matches the CLI's display). All runs share one text format,
            // so their baselines line up.
            for (i, item) in self.items.iter().enumerate() {
                let Some(layout) = self.item_layouts.get(i) else {
                    continue;
                };
                let run = |left: f32, w: f32| D2D_RECT_F {
                    left,
                    top: layout.rect.top,
                    right: left + w,
                    bottom: layout.rect.bottom,
                };
                let mut x = layout.rect.left + ITEM_PAD_X;
                draw_text(
                    &rt,
                    &(i + 1).to_string(),
                    &run(x, layout.num_w),
                    &self.text_format,
                    &secondary_brush,
                );
                x += layout.num_w + NUM_GAP;
                draw_text(
                    &rt,
                    &item.value,
                    &run(x, layout.value_w),
                    &self.text_format,
                    &text_brush,
                );
                x += layout.value_w;
                if let Some(hint) = &item.hint {
                    let hint_rect = run(x, (layout.rect.right - ITEM_PAD_X - x).max(0.0));
                    draw_text(
                        &rt,
                        &format_hint(hint),
                        &hint_rect,
                        &self.text_format,
                        &secondary_brush,
                    );
                }
            }

            // Hairline border, one physical pixel, stroked just inside the
            // window edge. Rounded to match the DWM clip on Windows 11,
            // square on Windows 10.
            let border_brush = rt.CreateSolidColorBrush(&p.border, None)?;
            let px = 1.0 / scale;
            let inset = px / 2.0;
            let border_rect = D2D_RECT_F {
                left: inset,
                top: inset,
                right: width - inset,
                bottom: height - inset,
            };
            if self.rounded_corners {
                rt.DrawRoundedRectangle(
                    &rounded(border_rect, CORNER_RADIUS - inset),
                    &border_brush,
                    px,
                    None,
                );
            } else {
                rt.DrawRectangle(&border_rect, &border_brush, px, None);
            }

            match rt.EndDraw(None, None) {
                Ok(()) => {}
                Err(e) if e.code() == D2DERR_RECREATE_TARGET => {
                    self.render_target = None;
                }
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }

    /// Hit-test a point (client coords in DIPs) against the candidate pills.
    fn hit_test(&self, dip_x: f32, dip_y: f32) -> Option<usize> {
        self.item_layouts
            .iter()
            .position(|l| hits(&l.rect, dip_x, dip_y))
    }
}

impl Drop for CandidateWindow {
    fn drop(&mut self) {
        if !self.hwnd.0.is_null() {
            unsafe {
                let _ = DestroyWindow(self.hwnd);
            }
        }
    }
}

// ---- thread-local instance + public API ----------------------------------

thread_local! {
    static WINDOW: RefCell<Option<CandidateWindow>> = const { RefCell::new(None) };
}

pub fn show(screen_pos: POINT, items: Vec<CandidateItem>, ctx: ITfContext, tid: u32) {
    WINDOW.with(|w| {
        let mut w = w.borrow_mut();
        if w.is_none() {
            match CandidateWindow::new() {
                Ok(win) => *w = Some(win),
                Err(_) => return,
            }
        }
        let _ = w.as_mut().unwrap().show_at(screen_pos, items, ctx, tid);
    });
}

pub fn hide() {
    WINDOW.with(|w| {
        if let Some(win) = w.borrow_mut().as_mut() {
            win.hide();
        }
    });
}

pub fn destroy() {
    WINDOW.with(|w| {
        *w.borrow_mut() = None;
    });
}

/// Called by `ui_element` when the host toggles `ITfUIElement::Show`.
/// Reflects the new state into the popup without re-laying-out content.
pub fn sync_visibility() {
    let shown = ui_element::is_shown();
    WINDOW.with(|w| {
        if let Some(win) = w.borrow_mut().as_mut() {
            unsafe {
                let _ = if shown {
                    ShowWindow(win.hwnd, SW_SHOWNOACTIVATE)
                } else {
                    ShowWindow(win.hwnd, SW_HIDE)
                };
            }
        }
    });
}

/// Read the currently-displayed candidates. Used by tip.rs for number-key
/// selection ("press '2' to commit candidate #2").
pub fn current_items() -> Vec<CandidateItem> {
    WINDOW.with(|w| {
        w.borrow()
            .as_ref()
            .map(|win| win.items.clone())
            .unwrap_or_default()
    })
}

pub fn caret_screen_pos() -> POINT {
    use windows::Win32::Graphics::Gdi::ClientToScreen;
    use windows::Win32::UI::WindowsAndMessaging::GetCaretPos;

    let mut pt = POINT::default();
    unsafe {
        let focus = GetFocus();
        if !focus.0.is_null() && GetCaretPos(&mut pt).is_ok() {
            let _ = ClientToScreen(focus, &mut pt);
        }
    }
    POINT {
        x: pt.x,
        y: pt.y + 24,
    }
}

// ---- internal helpers ----------------------------------------------------

fn hits(rect: &D2D_RECT_F, x: f32, y: f32) -> bool {
    x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom
}

fn rounded(rect: D2D_RECT_F, radius: f32) -> D2D1_ROUNDED_RECT {
    D2D1_ROUNDED_RECT {
        rect,
        radiusX: radius,
        radiusY: radius,
    }
}

fn perform_commit(idx: usize) {
    // Snapshot the bits we need from the borrow, then drop it before calling
    // composition::commit_text (which requests an edit session that may
    // re-enter us indirectly).
    let snapshot = WINDOW.with(|w| {
        let w = w.borrow();
        let win = w.as_ref()?;
        let item = win.items.get(idx).cloned()?;
        let ctx = win.ctx.clone()?;
        Some((ctx, win.tid, item))
    });
    let Some((ctx, tid, item)) = snapshot else {
        return;
    };
    let _ = composition::commit_text(&ctx, tid, &item.value);
    jd::reset();
    hide();
}

fn ensure_class_registered() {
    static REGISTERED: AtomicBool = AtomicBool::new(false);
    if REGISTERED.swap(true, Ordering::SeqCst) {
        return;
    }
    let cursor = unsafe { LoadCursorW(None, IDC_ARROW).unwrap_or_default() };
    let wc = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        // CS_DROPSHADOW gives the popup the standard menu shadow on both
        // Windows 10 and 11, like the native IME window.
        style: CS_HREDRAW | CS_VREDRAW | CS_IME | CS_DROPSHADOW,
        lpfnWndProc: Some(wnd_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: dll_hmodule().into(),
        hIcon: HICON::default(),
        hCursor: cursor,
        hbrBackground: HBRUSH::default(),
        lpszMenuName: PCWSTR::null(),
        lpszClassName: WINDOW_CLASS_NAME,
        hIconSm: HICON::default(),
    };
    unsafe { RegisterClassExW(&wc) };
}

extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_MOUSEACTIVATE => {
            // Critical: tell Windows NOT to activate us on click. Without this
            // the popup steals focus from the host on every click, the host
            // sees focus loss, TSF fires OnCompositionTerminated, the
            // composition is committed as raw letters, and the popup is
            // dismissed — even though the user just wanted to click a
            // candidate on the popup itself.
            LRESULT(MA_NOACTIVATE as isize)
        }
        WM_PAINT => {
            WINDOW.with(|w| {
                if let Some(win) = w.borrow_mut().as_mut() {
                    if win.hwnd == hwnd {
                        let _ = win.paint();
                    }
                }
            });
            unsafe {
                let _ = ValidateRect(Some(hwnd), None);
            }
            LRESULT(0)
        }
        WM_LBUTTONDOWN => {
            // lparam: low word = x, high word = y (in client physical pixels)
            let xy = lparam.0 as u32;
            let x_px = (xy & 0xFFFF) as i16 as f32;
            let y_px = (xy >> 16) as i16 as f32;
            let target = WINDOW.with(|w| {
                let w = w.borrow();
                let win = w.as_ref()?;
                let scale = win.dpi() / 96.0;
                win.hit_test(x_px / scale, y_px / scale)
            });
            if let Some(idx) = target {
                perform_commit(idx);
            }
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            let xy = lparam.0 as u32;
            let x_px = (xy & 0xFFFF) as i16 as f32;
            let y_px = (xy >> 16) as i16 as f32;
            WINDOW.with(|w| {
                if let Some(win) = w.borrow_mut().as_mut() {
                    if win.hwnd != hwnd {
                        return;
                    }
                    let scale = win.dpi() / 96.0;
                    let new_hover = win.hit_test(x_px / scale, y_px / scale);
                    if new_hover != win.hover {
                        win.hover = new_hover;
                        unsafe {
                            let _ = InvalidateRect(Some(hwnd), None, false);
                        }
                    }
                    // Arm WM_MOUSELEAVE so we know when the cursor exits.
                    if !win.tracking_leave {
                        let mut tme = TRACKMOUSEEVENT {
                            cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
                            dwFlags: TME_LEAVE,
                            hwndTrack: hwnd,
                            dwHoverTime: 0,
                        };
                        unsafe {
                            let _ = TrackMouseEvent(&mut tme);
                        }
                        win.tracking_leave = true;
                    }
                }
            });
            LRESULT(0)
        }
        WM_MOUSELEAVE => {
            WINDOW.with(|w| {
                if let Some(win) = w.borrow_mut().as_mut() {
                    if win.hwnd != hwnd {
                        return;
                    }
                    win.tracking_leave = false;
                    if win.hover.is_some() {
                        win.hover = None;
                        unsafe {
                            let _ = InvalidateRect(Some(hwnd), None, false);
                        }
                    }
                }
            });
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

// ---- theme detection ------------------------------------------------------

/// WinUI flyout-surface colors for the current system theme + accent.
fn detect_palette() -> Palette {
    let accent = system_accent_color();
    if system_apps_dark_theme() {
        Palette {
            bg: color(0.172, 0.172, 0.172, 1.0), // #2C2C2C flyout surface
            border: color(1.0, 1.0, 1.0, 0.094),
            text: color(1.0, 1.0, 1.0, 1.0),
            text_secondary: color(1.0, 1.0, 1.0, 0.63),
            selected_fill: color(1.0, 1.0, 1.0, 0.075),
            hover_fill: color(1.0, 1.0, 1.0, 0.05),
            accent,
        }
    } else {
        Palette {
            bg: color(0.976, 0.976, 0.976, 1.0), // #F9F9F9 flyout surface
            border: color(0.0, 0.0, 0.0, 0.08),
            text: color(0.0, 0.0, 0.0, 0.896),
            text_secondary: color(0.0, 0.0, 0.0, 0.61),
            selected_fill: color(0.0, 0.0, 0.0, 0.055),
            hover_fill: color(0.0, 0.0, 0.0, 0.035),
            accent,
        }
    }
}

/// `AppsUseLightTheme == 0` means apps render dark. A missing value (or any
/// read failure) means the Windows default: light.
fn system_apps_dark_theme() -> bool {
    read_hkcu_dword(
        w!(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"),
        w!("AppsUseLightTheme"),
    ) == Some(0)
}

/// The user's accent color as DWM stores it (0xAABBGGRR). Falls back to the
/// Windows default blue #0078D4.
fn system_accent_color() -> D2D1_COLOR_F {
    match read_hkcu_dword(w!(r"Software\Microsoft\Windows\DWM"), w!("AccentColor")) {
        Some(abgr) => color(
            (abgr & 0xFF) as f32 / 255.0,
            ((abgr >> 8) & 0xFF) as f32 / 255.0,
            ((abgr >> 16) & 0xFF) as f32 / 255.0,
            1.0,
        ),
        None => color(0.0, 0.47, 0.83, 1.0),
    }
}

fn read_hkcu_dword(subkey: PCWSTR, value: PCWSTR) -> Option<u32> {
    let mut data = 0u32;
    let mut size = std::mem::size_of::<u32>() as u32;
    unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            subkey,
            value,
            RRF_RT_REG_DWORD,
            None,
            Some(&mut data as *mut u32 as *mut _),
            Some(&mut size),
        )
    }
    .is_ok()
    .then_some(data)
}

// ---- text helpers ---------------------------------------------------------

fn make_text_format(dwrite: &IDWriteFactory) -> Result<IDWriteTextFormat> {
    let fmt = unsafe {
        dwrite.CreateTextFormat(
            FONT_FAMILY,
            None::<&IDWriteFontCollection>,
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            FONT_SIZE,
            FONT_LOCALE,
        )
    }?;
    unsafe {
        fmt.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)?;
        fmt.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING)?;
    }
    Ok(fmt)
}

pub(crate) fn format_hint(hint: &str) -> String {
    // Leading space separates the hint from the value; matches the bracket
    // style used in the CLI renderer.
    format!(" 〔{hint}〕")
}

fn measure_text(dwrite: &IDWriteFactory, format: &IDWriteTextFormat, text: &str) -> Result<f32> {
    let wide: Vec<u16> = text.encode_utf16().collect();
    let layout: IDWriteTextLayout =
        unsafe { dwrite.CreateTextLayout(&wide, format, 4096.0, PILL_HEIGHT) }?;
    let mut metrics = DWRITE_TEXT_METRICS::default();
    unsafe { layout.GetMetrics(&mut metrics) }?;
    Ok(metrics.widthIncludingTrailingWhitespace)
}

fn draw_text(
    rt: &ID2D1HwndRenderTarget,
    text: &str,
    rect: &D2D_RECT_F,
    format: &IDWriteTextFormat,
    brush: &ID2D1SolidColorBrush,
) {
    let wide: Vec<u16> = text.encode_utf16().collect();
    unsafe {
        rt.DrawText(
            &wide,
            format,
            rect,
            brush,
            D2D1_DRAW_TEXT_OPTIONS_NONE,
            DWRITE_MEASURING_MODE_NATURAL,
        );
    }
}

fn color(r: f32, g: f32, b: f32, a: f32) -> D2D1_COLOR_F {
    D2D1_COLOR_F { r, g, b, a }
}
