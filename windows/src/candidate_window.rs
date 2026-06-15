//! Horizontal candidate popup in the style of Windows 11 Pinyin.
//!
//! Layout (DIPs):
//! ```
//! ┌────────────────────────────────────────────────────────────┐
//! │ ▎1 你好  2 你号  3 拟好  4 倪浩  …  N XXX        ◀  ▶        │
//! └────────────────────────────────────────────────────────────┘
//! ```
//! - Single row, left-to-right. The first candidate is "active" (commits on
//!   space) and is marked by a thin blue bar on its left.
//! - Two arrow buttons on the right paginate the engine.
//! - DWM is asked for rounded corners; on Windows 11 the OS applies them, on
//!   Windows 10 the call is a benign no-op and the popup has sharp corners.
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
    D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_COLOR_F, D2D1_PIXEL_FORMAT, D2D_RECT_F, D2D_SIZE_U,
};
use windows::Win32::Graphics::Direct2D::{
    D2D1CreateFactory, D2D1_DRAW_TEXT_OPTIONS_NONE, D2D1_FACTORY_TYPE_SINGLE_THREADED,
    D2D1_FEATURE_LEVEL_DEFAULT, D2D1_HWND_RENDER_TARGET_PROPERTIES, D2D1_PRESENT_OPTIONS_NONE,
    D2D1_RENDER_TARGET_PROPERTIES, D2D1_RENDER_TARGET_TYPE_DEFAULT,
    D2D1_RENDER_TARGET_USAGE_NONE, D2D1_ROUNDED_RECT, ID2D1Factory, ID2D1HwndRenderTarget,
    ID2D1SolidColorBrush,
};
use windows::Win32::Graphics::DirectWrite::{
    DWRITE_FACTORY_TYPE_SHARED, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL,
    DWRITE_FONT_WEIGHT_NORMAL, DWRITE_MEASURING_MODE_NATURAL, DWRITE_PARAGRAPH_ALIGNMENT_CENTER,
    DWRITE_TEXT_ALIGNMENT_CENTER, DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_TEXT_METRICS,
    DWriteCreateFactory, IDWriteFactory, IDWriteFontCollection, IDWriteTextFormat,
    IDWriteTextLayout,
};
use windows::Win32::Graphics::Dwm::{
    DWMWA_WINDOW_CORNER_PREFERENCE, DWM_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND,
    DwmSetWindowAttribute,
};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::{HBRUSH, InvalidateRect, ValidateRect};
use windows::Win32::UI::TextServices::ITfContext;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetFocus, TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CS_HREDRAW, CS_IME, CS_VREDRAW, CreateWindowExW, DefWindowProcW, DestroyWindow, GetClientRect,
    HICON, IDC_HAND, LoadCursorW, MA_NOACTIVATE, RegisterClassExW, SWP_NOACTIVATE, SWP_NOZORDER,
    SW_HIDE, SW_SHOWNOACTIVATE, SetCursor, SetWindowPos, ShowWindow, WM_LBUTTONDOWN,
    WM_MOUSEACTIVATE, WM_MOUSEMOVE, WM_PAINT, WM_SETCURSOR, WNDCLASSEXW, WS_EX_NOACTIVATE,
    WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
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
/// Smaller font for the page-nav arrow glyphs. Matches the Pinyin popup,
/// where the arrows are visibly more compact than the candidate text.
const ARROW_FONT_SIZE: f32 = 11.0;

const ROW_HEIGHT: f32 = 36.0;
const PAD_X: f32 = 12.0;
const PAD_Y: f32 = 6.0;
const ITEM_GAP: f32 = 14.0;
const SELECT_BAR_WIDTH: f32 = 3.0;
const SELECT_BAR_GAP: f32 = 6.0;
const BUTTON_WIDTH: f32 = 16.0;
const BUTTON_GAP: f32 = 2.0;
const ITEMS_BUTTONS_GAP: f32 = 10.0;
const CORNER_RADIUS: f32 = 6.0;

#[derive(Debug, Default, Clone)]
pub struct CandidateItem {
    pub value: String,
    pub hint: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PageNav {
    Prev,
    Next,
}

/// A hit-test target — used for both click dispatch and hover highlighting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HitTarget {
    PrevButton,
    NextButton,
    Candidate(usize),
}

struct CandidateWindow {
    hwnd: HWND,
    d2d: ID2D1Factory,
    dwrite: IDWriteFactory,
    text_format: IDWriteTextFormat,
    arrow_format: IDWriteTextFormat,
    render_target: Option<ID2D1HwndRenderTarget>,
    items: Vec<CandidateItem>,
    page: u32,
    total_pages: u32,
    /// Hit-test rects in DIPs.
    prev_btn_rect: D2D_RECT_F,
    next_btn_rect: D2D_RECT_F,
    item_rects: Vec<D2D_RECT_F>,
    /// Context + client-ID stashed at show time so the async click handler
    /// can request an edit session to commit on click.
    ctx: Option<ITfContext>,
    tid: u32,
    /// What the mouse is currently over, if anything. Repainted whenever
    /// it changes.
    hover: Option<HitTarget>,
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
        let text_format = make_text_format(&dwrite, DWRITE_TEXT_ALIGNMENT_LEADING, FONT_SIZE)?;
        let arrow_format =
            make_text_format(&dwrite, DWRITE_TEXT_ALIGNMENT_CENTER, ARROW_FONT_SIZE)?;

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
                ROW_HEIGHT as i32,
                None,
                None,
                Some(hinstance.into()),
                None,
            )
        }?;

        // Best-effort rounded corners on Windows 11. Returns S_OK as a no-op
        // on Windows 10; we don't propagate the result either way.
        let pref: DWM_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND;
        unsafe {
            let _ = DwmSetWindowAttribute(
                hwnd,
                DWMWA_WINDOW_CORNER_PREFERENCE,
                &pref as *const _ as *const _,
                std::mem::size_of::<DWM_WINDOW_CORNER_PREFERENCE>() as u32,
            );
        }

        Ok(Self {
            hwnd,
            d2d,
            dwrite,
            text_format,
            arrow_format,
            render_target: None,
            items: Vec::new(),
            page: 0,
            total_pages: 0,
            prev_btn_rect: D2D_RECT_F::default(),
            next_btn_rect: D2D_RECT_F::default(),
            item_rects: Vec::new(),
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

    /// Re-layout: measure each item (value + optional hint), place it
    /// left-to-right, cache the rect for hit-testing. Returns the resulting
    /// total popup width in DIPs.
    fn relayout(&mut self) -> Result<f32> {
        self.item_rects.clear();
        if self.items.is_empty() {
            return Ok(80.0);
        }
        let mut x = PAD_X + SELECT_BAR_WIDTH + SELECT_BAR_GAP;
        for (i, item) in self.items.iter().enumerate() {
            if i > 0 {
                x += ITEM_GAP;
            }
            let value_w = measure_text(&self.dwrite, &self.text_format, &format_value(i, item))?;
            let hint_w = match &item.hint {
                Some(h) => measure_text(&self.dwrite, &self.text_format, &format_hint(h))?,
                None => 0.0,
            };
            let total_w = value_w + hint_w;
            self.item_rects.push(D2D_RECT_F {
                left: x,
                top: PAD_Y,
                right: x + total_w,
                bottom: PAD_Y + ROW_HEIGHT,
            });
            x += total_w;
        }
        x += ITEMS_BUTTONS_GAP + BUTTON_WIDTH + BUTTON_GAP + BUTTON_WIDTH + PAD_X;
        Ok(x)
    }

    fn show_at(
        &mut self,
        screen_pos: POINT,
        items: Vec<CandidateItem>,
        page: u32,
        total_pages: u32,
        ctx: ITfContext,
        tid: u32,
    ) -> Result<()> {
        self.items = items;
        self.page = page;
        self.total_pages = total_pages;
        self.ctx = Some(ctx);
        self.tid = tid;
        // Items changed — drop any stale hover; the cursor may now be
        // over a different candidate or off the popup entirely.
        self.hover = None;

        let width_dip = self.relayout()?;
        let height_dip = ROW_HEIGHT + 2.0 * PAD_Y;
        let scale = self.dpi() / 96.0;
        let width_px = (width_dip * scale).ceil() as i32;
        let height_px = (height_dip * scale).ceil() as i32;

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

    /// Update contents without moving the window. Used after page nav clicks.
    fn update_items(
        &mut self,
        items: Vec<CandidateItem>,
        page: u32,
        total_pages: u32,
    ) -> Result<()> {
        self.items = items;
        self.page = page;
        self.total_pages = total_pages;
        self.hover = None;

        let width_dip = self.relayout()?;
        let height_dip = ROW_HEIGHT + 2.0 * PAD_Y;
        let scale = self.dpi() / 96.0;
        let width_px = (width_dip * scale).ceil() as i32;
        let height_px = (height_dip * scale).ceil() as i32;

        // Keep current position but resize.
        let mut rect = RECT::default();
        unsafe {
            windows::Win32::UI::WindowsAndMessaging::GetWindowRect(self.hwnd, &mut rect)?;
        }
        self.render_target = None;
        unsafe {
            SetWindowPos(
                self.hwnd,
                None,
                rect.left,
                rect.top,
                width_px,
                height_px,
                SWP_NOACTIVATE | SWP_NOZORDER,
            )?;
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

        let bg = color(0.18, 0.18, 0.20, 1.0);
        let text = color(0.88, 0.88, 0.88, 1.0);
        let accent = color(0.0, 0.47, 0.83, 1.0); // Windows accent blue
        let dim = color(0.55, 0.55, 0.55, 1.0);

        // Cache button rects (recomputed each paint; cheap).
        let button_y_top = PAD_Y;
        let button_y_bot = height - PAD_Y;
        let next_btn_left = width - PAD_X - BUTTON_WIDTH;
        let prev_btn_left = next_btn_left - BUTTON_GAP - BUTTON_WIDTH;
        self.prev_btn_rect = D2D_RECT_F {
            left: prev_btn_left,
            top: button_y_top,
            right: prev_btn_left + BUTTON_WIDTH,
            bottom: button_y_bot,
        };
        self.next_btn_rect = D2D_RECT_F {
            left: next_btn_left,
            top: button_y_top,
            right: next_btn_left + BUTTON_WIDTH,
            bottom: button_y_bot,
        };

        unsafe {
            rt.BeginDraw();
            // Background. Fill with the rounded body. On Win 11 the DWM
            // corner preference rounds the actual window edges; this fill
            // matches so the body is fully opaque under the rounding mask.
            rt.Clear(Some(&color(0.0, 0.0, 0.0, 0.0)));

            let bg_brush = rt.CreateSolidColorBrush(&bg, None)?;
            let text_brush = rt.CreateSolidColorBrush(&text, None)?;
            let accent_brush = rt.CreateSolidColorBrush(&accent, None)?;
            let dim_brush = rt.CreateSolidColorBrush(&dim, None)?;

            let body = D2D1_ROUNDED_RECT {
                rect: D2D_RECT_F { left: 0.0, top: 0.0, right: width, bottom: height },
                radiusX: CORNER_RADIUS,
                radiusY: CORNER_RADIUS,
            };
            rt.FillRoundedRectangle(&body, &bg_brush);

            // Hover highlight, drawn under text + arrows so it acts as a
            // background pill.
            if let Some(target) = self.hover {
                let hover_brush = rt
                    .CreateSolidColorBrush(&color(0.30, 0.30, 0.32, 1.0), None)?;
                let pill = |r: &D2D_RECT_F, pad_x: f32, pad_y: f32| D2D1_ROUNDED_RECT {
                    rect: D2D_RECT_F {
                        left: r.left - pad_x,
                        top: r.top + pad_y,
                        right: r.right + pad_x,
                        bottom: r.bottom - pad_y,
                    },
                    radiusX: 4.0,
                    radiusY: 4.0,
                };
                match target {
                    HitTarget::Candidate(i) => {
                        if let Some(rect) = self.item_rects.get(i) {
                            rt.FillRoundedRectangle(&pill(rect, 4.0, 2.0), &hover_brush);
                        }
                    }
                    HitTarget::PrevButton => {
                        rt.FillRoundedRectangle(&pill(&self.prev_btn_rect, 0.0, 2.0), &hover_brush);
                    }
                    HitTarget::NextButton => {
                        rt.FillRoundedRectangle(&pill(&self.next_btn_rect, 0.0, 2.0), &hover_brush);
                    }
                }
            }

            // Items — use the rects cached by relayout() so paint and
            // hit-test agree exactly on positions. The value renders in the
            // normal text color; the optional hint is drawn immediately to
            // its right in the dim color (matches the CLI's display).
            for (i, item) in self.items.iter().enumerate() {
                if let Some(rect) = self.item_rects.get(i) {
                    let value = format_value(i, item);
                    let value_w =
                        measure_text(&self.dwrite, &self.text_format, &value).unwrap_or(0.0);
                    let value_rect = D2D_RECT_F {
                        left: rect.left,
                        top: rect.top,
                        right: rect.left + value_w,
                        bottom: rect.bottom,
                    };
                    draw_text(&rt, &value, &value_rect, &self.text_format, &text_brush);

                    if let Some(hint) = &item.hint {
                        let hint_text = format_hint(hint);
                        let hint_rect = D2D_RECT_F {
                            left: rect.left + value_w,
                            top: rect.top,
                            right: rect.right,
                            bottom: rect.bottom,
                        };
                        draw_text(&rt, &hint_text, &hint_rect, &self.text_format, &dim_brush);
                    }
                }
            }

            // Selected-indicator bar on the first item.
            if !self.items.is_empty() {
                let bar = D2D1_ROUNDED_RECT {
                    rect: D2D_RECT_F {
                        left: PAD_X,
                        top: PAD_Y + 4.0,
                        right: PAD_X + SELECT_BAR_WIDTH,
                        bottom: PAD_Y + ROW_HEIGHT - 4.0,
                    },
                    radiusX: 1.5,
                    radiusY: 1.5,
                };
                rt.FillRoundedRectangle(&bar, &accent_brush);
            }

            // Page navigation buttons (left/right arrows).
            let can_prev = self.total_pages > 1 && self.page > 1;
            let can_next = self.total_pages > 1 && self.page < self.total_pages;
            let prev_brush = if can_prev { &text_brush } else { &dim_brush };
            let next_brush = if can_next { &text_brush } else { &dim_brush };
            draw_text(&rt, "◀", &self.prev_btn_rect, &self.arrow_format, prev_brush);
            draw_text(&rt, "▶", &self.next_btn_rect, &self.arrow_format, next_brush);

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

    /// Hit-test a point (client coords in DIPs) against the popup's
    /// interactive regions.
    fn hit_test(&self, dip_x: f32, dip_y: f32) -> Option<HitTarget> {
        if hits(&self.prev_btn_rect, dip_x, dip_y) {
            return Some(HitTarget::PrevButton);
        }
        if hits(&self.next_btn_rect, dip_x, dip_y) {
            return Some(HitTarget::NextButton);
        }
        for (i, rect) in self.item_rects.iter().enumerate() {
            if hits(rect, dip_x, dip_y) {
                return Some(HitTarget::Candidate(i));
            }
        }
        None
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

pub fn show(
    screen_pos: POINT,
    items: Vec<CandidateItem>,
    page: u32,
    total_pages: u32,
    ctx: ITfContext,
    tid: u32,
) {
    WINDOW.with(|w| {
        let mut w = w.borrow_mut();
        if w.is_none() {
            match CandidateWindow::new() {
                Ok(win) => *w = Some(win),
                Err(_) => return,
            }
        }
        let _ = w
            .as_mut()
            .unwrap()
            .show_at(screen_pos, items, page, total_pages, ctx, tid);
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
        w.borrow().as_ref().map(|win| win.items.clone()).unwrap_or_default()
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
    POINT { x: pt.x, y: pt.y + 24 }
}

// ---- internal helpers ----------------------------------------------------

fn hits(rect: &D2D_RECT_F, x: f32, y: f32) -> bool {
    x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom
}

fn perform_page_nav(nav: PageNav) {
    let result = match nav {
        PageNav::Prev => jd::ENGINE.prev_page(),
        PageNav::Next => jd::ENGINE.next_page(),
    };
    if result.options.is_empty() {
        hide();
        return;
    }
    let items: Vec<CandidateItem> = result
        .options
        .iter()
        .map(|o| CandidateItem { value: o.value.clone(), hint: o.hint.clone() })
        .collect();
    WINDOW.with(|w| {
        if let Some(win) = w.borrow_mut().as_mut() {
            let _ = win.update_items(items, result.current_page, result.total_pages);
        }
    });
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
    let Some((ctx, tid, item)) = snapshot else { return };
    let _ = composition::commit_text(&ctx, tid, &item.value);
    jd::ENGINE.reset();
    hide();
}

fn ensure_class_registered() {
    static REGISTERED: AtomicBool = AtomicBool::new(false);
    if REGISTERED.swap(true, Ordering::SeqCst) {
        return;
    }
    let cursor = unsafe { LoadCursorW(None, IDC_HAND).unwrap_or_default() };
    let wc = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW | CS_IME,
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
            // dismissed — even though the user just wanted to click a button
            // on the popup itself.
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
            match target {
                Some(HitTarget::PrevButton) => perform_page_nav(PageNav::Prev),
                Some(HitTarget::NextButton) => perform_page_nav(PageNav::Next),
                Some(HitTarget::Candidate(i)) => perform_commit(i),
                None => {}
            }
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            let xy = lparam.0 as u32;
            let x_px = (xy & 0xFFFF) as i16 as f32;
            let y_px = (xy >> 16) as i16 as f32;
            WINDOW.with(|w| {
                if let Some(win) = w.borrow_mut().as_mut() {
                    if win.hwnd != hwnd { return; }
                    let scale = win.dpi() / 96.0;
                    let new_hover = win.hit_test(x_px / scale, y_px / scale);
                    if new_hover != win.hover {
                        win.hover = new_hover;
                        unsafe { let _ = InvalidateRect(Some(hwnd), None, false); }
                    }
                    // Arm WM_MOUSELEAVE so we know when the cursor exits.
                    if !win.tracking_leave {
                        let mut tme = TRACKMOUSEEVENT {
                            cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
                            dwFlags: TME_LEAVE,
                            hwndTrack: hwnd,
                            dwHoverTime: 0,
                        };
                        unsafe { let _ = TrackMouseEvent(&mut tme); }
                        win.tracking_leave = true;
                    }
                }
            });
            LRESULT(0)
        }
        WM_MOUSELEAVE => {
            WINDOW.with(|w| {
                if let Some(win) = w.borrow_mut().as_mut() {
                    if win.hwnd != hwnd { return; }
                    win.tracking_leave = false;
                    if win.hover.is_some() {
                        win.hover = None;
                        unsafe { let _ = InvalidateRect(Some(hwnd), None, false); }
                    }
                }
            });
            LRESULT(0)
        }
        WM_SETCURSOR => unsafe {
            // Make the buttons feel clickable.
            let _ = SetCursor(Some(LoadCursorW(None, IDC_HAND).unwrap_or_default()));
            LRESULT(1)
        },
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

fn make_text_format(
    dwrite: &IDWriteFactory,
    alignment: windows::Win32::Graphics::DirectWrite::DWRITE_TEXT_ALIGNMENT,
    font_size: f32,
) -> Result<IDWriteTextFormat> {
    let fmt = unsafe {
        dwrite.CreateTextFormat(
            FONT_FAMILY,
            None::<&IDWriteFontCollection>,
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            font_size,
            FONT_LOCALE,
        )
    }?;
    unsafe {
        fmt.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)?;
        fmt.SetTextAlignment(alignment)?;
    }
    Ok(fmt)
}

fn format_value(idx: usize, item: &CandidateItem) -> String {
    format!("{} {}", idx + 1, item.value)
}

fn format_hint(hint: &str) -> String {
    // Leading space separates the hint from the value; matches the bracket
    // style used in the CLI renderer.
    format!(" 〔{hint}〕")
}

fn measure_text(
    dwrite: &IDWriteFactory,
    format: &IDWriteTextFormat,
    text: &str,
) -> Result<f32> {
    let wide: Vec<u16> = text.encode_utf16().collect();
    let layout: IDWriteTextLayout =
        unsafe { dwrite.CreateTextLayout(&wide, format, 4096.0, ROW_HEIGHT) }?;
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
