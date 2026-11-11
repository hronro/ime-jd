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
//! - The popup hangs under the composition, its left edge on the text's —
//!   over it where the screen ends below — and always within the work area
//!   of the monitor the text is on (`position`). It goes with the text when
//!   the application moves it, and waits, briefly, for an application that
//!   has not laid the text out yet (`show`, `follow`).
//! - When a newer release is known (update.rs), one small line sits under
//!   the candidates — "键道有新版本 vX.Y.Z，点击前往下载" — and clicking it
//!   opens the release page and retires the line. It is the TIP's only UI,
//!   so it is also the only place an update can be announced.
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
    D2DERR_RECREATE_TARGET, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM,
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
use windows::Win32::Graphics::Gdi::{
    ClientToScreen, GetMonitorInfoW, HBRUSH, InvalidateRect, MONITOR_DEFAULTTONEAREST, MONITORINFO,
    MapWindowPoints, MonitorFromPoint, ValidateRect,
};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::{TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent};
use windows::Win32::UI::TextServices::{
    ITfContext, ITfContextView, ITfSource, ITfTextLayoutSink, ITfTextLayoutSink_Impl,
    TF_LC_DESTROY, TfLayoutCode,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CS_DROPSHADOW, CS_HREDRAW, CS_IME, CS_VREDRAW, CreateWindowExW, DefWindowProcW, DestroyWindow,
    GUITHREADINFO, GetClientRect, GetGUIThreadInfo, HICON, IDC_ARROW, KillTimer, LoadCursorW,
    MA_NOACTIVATE, RegisterClassExW, SW_HIDE, SW_SHOWNOACTIVATE, SWP_NOACTIVATE, SWP_NOZORDER,
    SetTimer, SetWindowPos, ShowWindow, WM_LBUTTONDOWN, WM_MOUSEACTIVATE, WM_MOUSEMOVE, WM_PAINT,
    WM_TIMER, WNDCLASSEXW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
};

// `WM_MOUSELEAVE` lives in `Win32::UI::Controls` in windows-rs, which would
// require adding the whole Controls feature flag just for one constant.
// Inline the value to avoid the dependency.
const WM_MOUSELEAVE: u32 = 0x02A3;
use windows::core::{ComObjectInner, Interface, PCWSTR, Ref, Result, implement, w};

use crate::composition::{self, Location};
use crate::{dll_hmodule, jd, ui_element, update};

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
/// The update-notice row under the candidates (update.rs), when one is shown.
const NOTICE_HEIGHT: f32 = 22.0;
const NOTICE_FONT_SIZE: f32 = 12.0;

/// Pixels between the composition and the popup under, or over, it.
const ANCHOR_GAP: i32 = 4;
/// The timer that ends the wait for an application's layout (`wait`), and
/// how long the wait is, in milliseconds: time enough for an application
/// that lays its text out a frame or a few behind the edit, and short of
/// what a typist takes for the candidates being late.
const WAIT_TIMER: usize = 1;
const WAIT_MS: u32 = 100;

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
    /// Smaller text format for the update-notice row.
    notice_format: IDWriteTextFormat,
    /// Newer-release notice to draw under the candidates, if any (update.rs);
    /// re-read from the cache on every show.
    notice: Option<update::Notice>,
    /// The notice row's rect (DIPs) — its hit target — parallel to `notice`.
    notice_rect: Option<D2D_RECT_F>,
    /// Whether the mouse is over the notice; drawn in the accent color then.
    hover_notice: bool,
    /// What the popup hangs under, in screen pixels: the composition, or
    /// what stands in for it when the application will not say where that
    /// is (`show_at`). Kept so that the popup can be laid out again where it
    /// is — a retired notice, the focus back — and `follow` can tell a move.
    anchor: RECT,
    /// Whether the candidates are waiting for a place: the application had
    /// not laid the composition out when they came, and they stay off the
    /// screen until it has (`follow`) or the wait runs out (`wait`).
    waiting: bool,
    /// While candidates are up: the context they belong to, and the
    /// connection that tells of every change to its layout (`LayoutSink`).
    layout_sink: Option<(ITfContext, u32)>,
    /// Whether there are candidates up: from `show_at` until `hide`.
    open: bool,
    /// Whether another application has the focus (`set_thread_focus`): the
    /// candidates of a composition still open here stay off the screen until
    /// this one is back in front.
    away: bool,
}

impl CandidateWindow {
    fn new() -> Result<Self> {
        ensure_class_registered();

        let d2d: ID2D1Factory =
            unsafe { D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None) }?;
        let dwrite: IDWriteFactory = unsafe { DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED) }?;
        let text_format = make_text_format(&dwrite, FONT_SIZE)?;
        let notice_format = make_text_format(&dwrite, NOTICE_FONT_SIZE)?;

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
            notice_format,
            notice: None,
            notice_rect: None,
            hover_notice: false,
            anchor: RECT::default(),
            waiting: false,
            layout_sink: None,
            open: false,
            away: false,
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
    /// hint), place its pill left-to-right, then the notice row (if any)
    /// under them; cache both for painting and hit-testing. Returns the
    /// resulting popup size in DIPs.
    fn relayout(&mut self) -> Result<(f32, f32)> {
        let mut width = self.layout_items()?;
        let mut height = WINDOW_HEIGHT;
        self.notice_rect = None;
        if let Some(notice) = &self.notice {
            let text_w = measure_text(&self.dwrite, &self.notice_format, &notice.text())?;
            width = width.max(EDGE_PAD_X + ITEM_PAD_X + text_w + ITEM_PAD_X + EDGE_PAD_X);
            // The row shares the candidates' bottom pad as its top pad.
            let top = WINDOW_HEIGHT - EDGE_PAD_Y;
            self.notice_rect = Some(D2D_RECT_F {
                left: EDGE_PAD_X,
                top,
                right: width - EDGE_PAD_X,
                bottom: top + NOTICE_HEIGHT,
            });
            height = top + NOTICE_HEIGHT + EDGE_PAD_Y;
        }
        Ok((width, height))
    }

    /// Place the candidate pills; returns the width they need.
    fn layout_items(&mut self) -> Result<f32> {
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
        place: Location,
        items: Vec<CandidateItem>,
        ctx: ITfContext,
        tid: u32,
    ) -> Result<()> {
        let was_open = self.open;
        self.watch_layout(&ctx, tid);
        self.items = items;
        self.ctx = Some(ctx);
        self.tid = tid;
        // A key brought these: the thread has the focus, whatever was last
        // heard of it.
        self.open = true;
        self.away = false;
        // Items changed — drop any stale hover; the cursor may now be
        // over a different candidate or off the popup entirely.
        self.hover = None;
        self.hover_notice = false;
        // Cheap registry reads — keeps the popup in sync with live theme
        // and accent-color changes.
        self.palette = detect_palette();
        // A mutex read; the registry work happened on activation.
        self.notice = update::pending_notice();
        match place {
            Location::At(rect) => self.hang(rect),
            // The application has not said where the composition is: under
            // the system caret, then, in a window that has one.
            _ => match caret_rect() {
                Some(caret) => self.hang(caret),
                // Without one, candidates already up stay where they are.
                None if was_open => {}
                // New ones wait for an application that has not laid the
                // new text out yet and is to say when it has (`follow`) —
                // though not for long.
                None if place == Location::Pending => self.wait(),
                // And with no such word to wait for, the corner of the
                // focus window is all there is to go by.
                None => self.hang(focus_corner()),
            },
        }
        self.place()
    }

    /// From now on the popup hangs under `anchor`, and is to be seen.
    fn hang(&mut self, anchor: RECT) {
        self.stop_waiting();
        self.anchor = anchor;
    }

    /// Lay out, size the window under `anchor`, and show or hide it as the
    /// UIElement state dictates. Also what a retired notice re-runs.
    fn place(&mut self) -> Result<()> {
        let (width_dip, height_dip) = self.relayout()?;
        let scale = self.dpi() / 96.0;
        let size = SIZE {
            cx: (width_dip * scale).ceil() as i32,
            cy: (height_dip * scale).ceil() as i32,
        };

        self.render_target = None;

        let at = match work_area(&self.anchor) {
            Some(work) => position(&self.anchor, size, &work),
            None => POINT {
                x: self.anchor.left,
                y: self.anchor.bottom + ANCHOR_GAP,
            },
        };
        unsafe {
            SetWindowPos(
                self.hwnd,
                None,
                at.x,
                at.y,
                size.cx,
                size.cy,
                SWP_NOACTIVATE | SWP_NOZORDER,
            )
        }?;
        // When a UIElement-aware host has opted to render the candidate list
        // itself, leave the window hidden — we still keep `self.items` and
        // sizing fresh so flipping `is_shown` back on later re-renders cleanly.
        // Likewise while another application is in front, and while there
        // is no telling where the composition is.
        if ui_element::is_shown() && !self.away && !self.waiting {
            let _ = unsafe { ShowWindow(self.hwnd, SW_SHOWNOACTIVATE) };
        } else {
            let _ = unsafe { ShowWindow(self.hwnd, SW_HIDE) };
        }
        unsafe {
            let _ = InvalidateRect(Some(self.hwnd), None, true);
        }
        Ok(())
    }

    /// Keep the candidates off the screen until the application says where
    /// the composition is, or the wait runs out (`WM_TIMER`): an
    /// application that answers TS_E_NOLAYOUT is to say when its layout is
    /// ready, but the candidates do not depend on its doing so.
    fn wait(&mut self) {
        // SAFETY: a timer on our own window, which it goes with.
        self.waiting = unsafe { SetTimer(Some(self.hwnd), WAIT_TIMER, WAIT_MS, None) } != 0;
        if !self.waiting {
            self.anchor = focus_corner();
        }
    }

    fn stop_waiting(&mut self) {
        if self.waiting {
            self.waiting = false;
            // SAFETY: the timer `wait` set.
            unsafe {
                let _ = KillTimer(Some(self.hwnd), WAIT_TIMER);
            }
        }
    }

    /// The wait ran out with no word from the application: the candidates
    /// come up where a caret has appeared since, or at the corner of the
    /// focus window — and move if the word comes after all.
    fn give_up_waiting(&mut self) {
        if !self.waiting {
            return;
        }
        self.hang(caret_rect().unwrap_or_else(focus_corner));
        let _ = self.place();
    }

    /// Hear of every change to the layout of `ctx`, the context the
    /// candidates are up in, until they go (`unwatch_layout`).
    fn watch_layout(&mut self, ctx: &ITfContext, tid: u32) {
        if self
            .layout_sink
            .as_ref()
            .is_some_and(|(watched, _)| watched == ctx)
        {
            return;
        }
        self.unwatch_layout();
        let sink: ITfTextLayoutSink = LayoutSink { tid }.into_object().into_interface();
        // SAFETY: a plain COM call; TSF holds the sink until it is
        // unadvised.
        let cookie = ctx
            .cast::<ITfSource>()
            .and_then(|source| unsafe { source.AdviseSink(&ITfTextLayoutSink::IID, &sink) });
        if let Ok(cookie) = cookie {
            self.layout_sink = Some((ctx.clone(), cookie));
        }
    }

    fn unwatch_layout(&mut self) {
        if let Some((ctx, cookie)) = self.layout_sink.take()
            && let Ok(source) = ctx.cast::<ITfSource>()
        {
            // SAFETY: the connection `watch_layout` made.
            let _ = unsafe { source.UnadviseSink(cookie) };
        }
    }

    fn hide(&mut self) {
        self.open = false;
        self.stop_waiting();
        self.unwatch_layout();
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
        // One physical pixel, for the hairlines.
        let px = 1.0 / scale;

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

            // Update notice under the candidates: a hairline above it, then
            // the line in the secondary color — accent while hovered, so it
            // reads as the link it is.
            let border_brush = rt.CreateSolidColorBrush(&p.border, None)?;
            if let (Some(notice), Some(rect)) = (&self.notice, self.notice_rect) {
                let rule = D2D_RECT_F {
                    left: rect.left,
                    top: rect.top,
                    right: rect.right,
                    bottom: rect.top + px,
                };
                rt.FillRectangle(&rule, &border_brush);
                let text_rect = D2D_RECT_F {
                    left: rect.left + ITEM_PAD_X,
                    top: rect.top,
                    right: rect.right - ITEM_PAD_X,
                    bottom: rect.bottom,
                };
                let brush = if self.hover_notice {
                    &accent_brush
                } else {
                    &secondary_brush
                };
                draw_text(&rt, &notice.text(), &text_rect, &self.notice_format, brush);
            }

            // Hairline border, one physical pixel, stroked just inside the
            // window edge. Rounded to match the DWM clip on Windows 11,
            // square on Windows 10.
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

    /// Hit-test a point (client coords in DIPs) against the notice row.
    fn hits_notice(&self, dip_x: f32, dip_y: f32) -> bool {
        self.notice_rect.is_some_and(|r| hits(&r, dip_x, dip_y))
    }
}

impl Drop for CandidateWindow {
    fn drop(&mut self) {
        self.unwatch_layout();
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

/// Put `items` up, the candidates of the composition in `ctx`; `place` is
/// where on the screen the application says that composition is
/// (`composition::location`).
pub fn show(place: Location, items: Vec<CandidateItem>, ctx: ITfContext, tid: u32) {
    WINDOW.with(|w| {
        let mut w = w.borrow_mut();
        if w.is_none() {
            match CandidateWindow::new() {
                Ok(win) => *w = Some(win),
                Err(_) => return,
            }
        }
        let _ = w.as_mut().unwrap().show_at(place, items, ctx, tid);
    });
}

/// The composition is not where the candidates were put — the application
/// scrolled, its window moved, or it has only now laid the new text out:
/// they go to where it is, and candidates that waited for a place come up.
pub fn follow(anchor: RECT) {
    WINDOW.with(|w| {
        // From an edit session TSF runs at a time of its choosing: never
        // while the window is in the middle of something of its own.
        let Ok(mut w) = w.try_borrow_mut() else {
            return;
        };
        let Some(win) = w.as_mut() else {
            return;
        };
        if !win.open || (!win.waiting && win.anchor == anchor) {
            return;
        }
        win.hang(anchor);
        let _ = win.place();
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
                let _ = if shown && win.open && !win.away && !win.waiting {
                    ShowWindow(win.hwnd, SW_SHOWNOACTIVATE)
                } else {
                    ShowWindow(win.hwnd, SW_HIDE)
                };
            }
        }
    });
}

/// The thread lost the focus — another application came to the front — or
/// has it back. A composition may stay open in this one meanwhile, as the
/// application decides; its candidates leave the screen with the focus and
/// return with it.
pub fn set_thread_focus(focused: bool) {
    WINDOW.with(|w| {
        // TSF's call, at a time of its choosing: never while the window is
        // in the middle of something of its own.
        let Ok(mut w) = w.try_borrow_mut() else {
            return;
        };
        let Some(win) = w.as_mut() else {
            return;
        };
        win.away = !focused;
        if !win.open {
            return;
        }
        if focused {
            let _ = win.place();
        } else {
            unsafe {
                let _ = ShowWindow(win.hwnd, SW_HIDE);
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

// ---- placement -------------------------------------------------------------

/// Where a popup of `size` goes: under `anchor`, the text it belongs to,
/// with its left edge on the text's; over the text when it does not fit
/// under and does over; and inside `work`, the work area of the text's
/// monitor, whatever that takes — to the left of a text near the right
/// edge, onto the screen for a text that is off it.
fn position(anchor: &RECT, size: SIZE, work: &RECT) -> POINT {
    let under = anchor.bottom + ANCHOR_GAP;
    let over = anchor.top - ANCHOR_GAP - size.cy;
    let y = if under + size.cy > work.bottom && over >= work.top {
        over
    } else {
        under
    };
    // The top-left corner wins where the popup is larger than the work
    // area: the first candidates are the ones to keep in sight.
    POINT {
        x: anchor.left.min(work.right - size.cx).max(work.left),
        y: y.min(work.bottom - size.cy).max(work.top),
    }
}

/// The work area — the screen less the taskbar — of the monitor the popup
/// hangs on: the one `anchor`'s bottom-left corner is on, or the nearest.
fn work_area(anchor: &RECT) -> Option<RECT> {
    let corner = POINT {
        x: anchor.left,
        y: anchor.bottom,
    };
    let mut info = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    // SAFETY: plain calls; `info` is the struct the second one fills.
    unsafe {
        let monitor = MonitorFromPoint(corner, MONITOR_DEFAULTTONEAREST);
        GetMonitorInfoW(monitor, &mut info)
            .as_bool()
            .then_some(info.rcWork)
    }
}

/// The system caret's rect on the screen, in a window that has one, as the
/// classic edit controls do: it stands where the composition starts.
fn caret_rect() -> Option<RECT> {
    let info = gui_thread_info()?;
    if info.hwndCaret.0.is_null() {
        return None;
    }
    let mut corners = [
        POINT {
            x: info.rcCaret.left,
            y: info.rcCaret.top,
        },
        POINT {
            x: info.rcCaret.right,
            y: info.rcCaret.bottom,
        },
    ];
    // SAFETY: a plain call; the caret's rect is in the client coordinates
    // of its window.
    unsafe { MapWindowPoints(Some(info.hwndCaret), None, &mut corners) };
    Some(RECT {
        left: corners[0].x,
        top: corners[0].y,
        right: corners[1].x,
        bottom: corners[1].y,
    })
}

/// The last resort for a place: the top-left corner of the focus window,
/// a line of text down — or of the screen, in a thread with no focus
/// window.
fn focus_corner() -> RECT {
    let mut corner = POINT::default();
    if let Some(info) = gui_thread_info()
        && !info.hwndFocus.0.is_null()
    {
        // SAFETY: a plain call.
        unsafe {
            let _ = ClientToScreen(info.hwndFocus, &mut corner);
        }
    }
    RECT {
        left: corner.x,
        top: corner.y,
        right: corner.x,
        bottom: corner.y + 20,
    }
}

/// This thread's focus window and caret.
fn gui_thread_info() -> Option<GUITHREADINFO> {
    let mut info = GUITHREADINFO {
        cbSize: std::mem::size_of::<GUITHREADINFO>() as u32,
        ..Default::default()
    };
    // SAFETY: `info` is the struct the call fills.
    unsafe { GetGUIThreadInfo(GetCurrentThreadId(), &mut info) }.ok()?;
    Some(info)
}

/// The application's word that its layout changed, in the context the
/// candidates are up in (`CandidateWindow::watch_layout`): the text
/// scrolled, the window moved, or the layout it had not got to when asked
/// for the composition's place is ready.
#[implement(ITfTextLayoutSink)]
struct LayoutSink {
    tid: u32,
}

impl ITfTextLayoutSink_Impl for LayoutSink_Impl {
    fn OnLayoutChange(
        &self,
        _pic: Ref<'_, ITfContext>,
        lcode: TfLayoutCode,
        _pview: Ref<'_, ITfContextView>,
    ) -> Result<()> {
        // A view on its way out has nowhere for the candidates to go.
        if lcode != TF_LC_DESTROY {
            composition::locate(self.tid, follow);
        }
        Ok(())
    }
}

// ---- internal helpers ----------------------------------------------------

/// What a left click landed on.
enum Click {
    Candidate(usize),
    Notice,
}

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

/// The user clicked the update notice: hand it to update.rs (opens the
/// release page, retires this version's notice everywhere) and shrink the
/// popup back to its candidates. The borrow is released before
/// ShellExecute, which may pump messages.
fn dismiss_notice() {
    let notice = WINDOW.with(|w| w.borrow_mut().as_mut().and_then(|win| win.notice.take()));
    let Some(notice) = notice else {
        return;
    };
    update::open_notice(&notice);
    WINDOW.with(|w| {
        if let Some(win) = w.borrow_mut().as_mut() {
            win.hover_notice = false;
            let _ = win.place();
        }
    });
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
                let (x, y) = (x_px / scale, y_px / scale);
                if win.hits_notice(x, y) {
                    return Some(Click::Notice);
                }
                win.hit_test(x, y).map(Click::Candidate)
            });
            match target {
                Some(Click::Candidate(idx)) => perform_commit(idx),
                Some(Click::Notice) => dismiss_notice(),
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
                    if win.hwnd != hwnd {
                        return;
                    }
                    let scale = win.dpi() / 96.0;
                    let (x, y) = (x_px / scale, y_px / scale);
                    let new_hover = win.hit_test(x, y);
                    let new_hover_notice = win.hits_notice(x, y);
                    if new_hover != win.hover || new_hover_notice != win.hover_notice {
                        win.hover = new_hover;
                        win.hover_notice = new_hover_notice;
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
        WM_TIMER if wparam.0 == WAIT_TIMER => {
            WINDOW.with(|w| {
                // Left for the next tick if the window is in the middle of
                // something.
                if let Ok(mut w) = w.try_borrow_mut()
                    && let Some(win) = w.as_mut()
                    && win.hwnd == hwnd
                {
                    win.give_up_waiting();
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
                    if win.hover.is_some() || win.hover_notice {
                        win.hover = None;
                        win.hover_notice = false;
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

pub(crate) fn read_hkcu_dword(subkey: PCWSTR, value: PCWSTR) -> Option<u32> {
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

fn make_text_format(dwrite: &IDWriteFactory, size: f32) -> Result<IDWriteTextFormat> {
    let fmt = unsafe {
        dwrite.CreateTextFormat(
            FONT_FAMILY,
            None::<&IDWriteFontCollection>,
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            size,
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

#[cfg(test)]
mod tests {
    use super::*;

    const WORK: RECT = RECT {
        left: 0,
        top: 0,
        right: 1000,
        bottom: 800,
    };
    const SIZE_300_40: SIZE = SIZE { cx: 300, cy: 40 };

    /// A line of text 24 pixels high, 20 wide, with its top-left corner at
    /// (`left`, `top`).
    fn text(left: i32, top: i32) -> RECT {
        RECT {
            left,
            top,
            right: left + 20,
            bottom: top + 24,
        }
    }

    fn at(anchor: RECT, size: SIZE, work: RECT) -> (i32, i32) {
        let point = position(&anchor, size, &work);
        (point.x, point.y)
    }

    #[test]
    fn the_popup_hangs_under_the_text_from_its_left_edge() {
        assert_eq!(at(text(100, 100), SIZE_300_40, WORK), (100, 128));
        // With room for it to the pixel, at the bottom and at the right.
        assert_eq!(at(text(700, 732), SIZE_300_40, WORK), (700, 760));
    }

    #[test]
    fn the_popup_stays_inside_the_work_area() {
        // Near the right edge: as far left as it takes.
        assert_eq!(at(text(900, 100), SIZE_300_40, WORK), (700, 128));
        // On the last line: over the text.
        assert_eq!(at(text(100, 770), SIZE_300_40, WORK), (100, 726));
        // Both at once, as in the corner of a maximized window.
        assert_eq!(at(text(990, 776), SIZE_300_40, WORK), (700, 732));
        // A text off the screen, to the left and above: onto the screen.
        assert_eq!(at(text(-500, -300), SIZE_300_40, WORK), (0, 0));
        // And off it below, as under a taskbar: over the text, and up to
        // the work area.
        assert_eq!(at(text(100, 820), SIZE_300_40, WORK), (100, 760));
    }

    #[test]
    fn a_monitor_left_of_the_primary_one_has_its_own_edges() {
        let work = RECT {
            left: -1920,
            top: 0,
            right: 0,
            bottom: 1040,
        };
        assert_eq!(at(text(-100, 100), SIZE_300_40, work), (-300, 128));
        assert_eq!(at(text(-1900, 1030), SIZE_300_40, work), (-1900, 986));
    }

    #[test]
    fn a_popup_with_no_room_keeps_its_top_left_corner_in_sight() {
        // No room under the text nor over it: under, and up as far as it
        // takes.
        let low = RECT {
            left: 0,
            top: 0,
            right: 1000,
            bottom: 60,
        };
        assert_eq!(at(text(100, 20), SIZE_300_40, low), (100, 20));
        // Wider and higher than the work area.
        let huge = SIZE { cx: 1200, cy: 900 };
        assert_eq!(at(text(500, 400), huge, WORK), (0, 0));
    }
}
