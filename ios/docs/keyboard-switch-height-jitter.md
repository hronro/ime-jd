# Keyboard-switch height jitter

## Symptom

When the 键道 keyboard appeared — most visibly when **switching from another keyboard** (e.g. the built-in English keyboard) — its height jittered: it showed at roughly the right height, grew ~45pt taller for ~100–200ms, then snapped back. Because the keyboard's height is what iOS reports to the host app as the keyboard frame, the jitter also shifted host layout (e.g. Safari's bottom address bar bounced). Gboard, by contrast, switches with no jitter (only a one-time hitch the very first time it's ever used).

Device used for investigation: **iPhone 16 Pro Max**, portrait, iOS in the Safari address bar / App Library search contexts.

## Root cause

When a custom keyboard slides in, **iOS inflates the input view by a fixed offset above the height we request, then snaps it down to our requested height once presented.** That snap is the jitter. The offset is a **constant**, independent of the height we ask for (requesting 260 → overshoot 305; requesting 305 → overshoot 350 — always `requested + ~45` on this device); it **varies by device and orientation** and has **no public API**; and it is applied during the slide-in and removed after `viewDidAppear`.

Earlier we mis-read the intermediate `305` as "the system default / outgoing keyboard height." It was not — it was always `requested + offset`. Proving that (by requesting 305 and seeing the overshoot move to 350) is what unlocked the correct fix.

## How we diagnosed it

`NSLog` from a keyboard extension did **not** reliably reach Console.app, so we used an **on-screen overlay** inside the keyboard that logged, deduped by geometry across the whole appearance, with millisecond offsets: `vH` = `view.bounds.height` (actual rendered height); `win` = `view.window?.bounds.height`; `sys` = the system's own `UIView-Encapsulated-Layout-Height` constraint constant; `c` = our height constraint constant; `age` = process age (warm vs cold).

Decisive readings:

| Requested `c` | Sequence of actual height (`win`/`sys`) |
|---|---|
| 260 | `956 → 305 → 260` |
| 305 | `956 → 350 → 305` |

`c` stayed constant the whole time while only the **actual window height** bounced → iOS, not our layout math, drives the resize. The intermediate = **`c + ~45`** in both cases → a constant additive offset, not the system default. `956` is the brief full-screen transient while the view is attached, and is not painted. `age` grew across switches → the extension process is **warm/reused** (not cold-starting).

## What we tried — and the result (all verified on device)

| Attempt | Result |
|---|---|
| Idempotent `updateHeight`; stop re-stamping height in `traitCollectionDidChange` | ❌ No effect |
| Bottom-pin content at a fixed height so keys don't stretch | ⚠️ Keys stopped ballooning, but a keyboard-background band still grew; doesn't fix the host. Reverted |
| Transparent input-view background (mask the band) | ❌ Rejected: hides our band but the **reported** height still bounces, so the host (Safari) still jitters |
| Height constraint `.required` instead of `.defaultHigh` | ❌ No effect — system overrides regardless; only relocates the slack (grew at bottom) |
| `UIInputView.allowsSelfSizing` + content-driven height | ❌ No effect (confirmed `siz=1`, still `956 → 305 → 260`) |
| Match the system default height (make ours ~305) | ❌ No effect — overshoot just moved to 350. **This proved the offset is `requested + const`, not the default** |
| Full Access (`RequestsOpenAccess`) | ❌ Ruled out — Gboard reproduces the no-jitter behavior **without** Full Access |
| Memory / cold-start eviction reloading the dictionary | ❌ Ruled out — process is warm (`age` grows) |
| iOS height cache being wiped by dev reinstalls | ❌ Ruled out — jittered on **every** warm switch, not just the first |
| Pixel-match each key's size/position (Gboard-style) | 🚫 Not pursued — no API for system key metrics; needs per-device × orientation × iOS-version tables with perpetual maintenance; **unnecessary** for the jitter (only the height matters) |

## What we shipped — the fix

The **"offset trick"** (see Apple Developer Forums thread 799003 for the general idea): request `target − offset` during the slide-in so iOS's inflation lands exactly on `target`, then restore `target` once presented. Made robust with **continuous auto-calibration**.

1. **Measure on every slide-in** — during the presenting window (`viewIsAppearing` → `viewDidAppear`), each layout pass yields `measured = view.bounds.height − heightConstraint.constant`, which equals the raw inflation whether or not the trick is applied (untricked bounds settle at `target + offset`; tricked at `(target − cached) + offset`). Samples outside `(0, target × 0.5)` are discarded: the full-screen attach transient measures ≈ screen height, and passes where the system height isn't applied yet measure 0. The largest surviving sample is committed to `UserDefaults` at `viewDidAppear` (when it differs from the cache by > 0.5pt) — unless the offset key changed mid-slide-in (rotation during the ~300ms presentation), which would store one orientation's measurement under the other's key.
2. **Pre-cancel** — request `target − offset` during the slide-in, restore `target` at `viewDidAppear`. A cached offset that looks implausibly large (≥ half the target) is ignored for that appearance — it then behaves like an uncalibrated one, and the sample it takes overwrites the bad cache.

This reproduces Gboard's behavior — **one calibration jitter the first time each key is seen, seamless forever after** (persisted across launches) — with **no hardcoded per-device tables**, so it adapts to any iPhone/iPad and iOS version. Because measurement never stops, a **stale offset self-heals**: a bad first measurement or an iOS point release shifting the value produces one jitter, and that appearance's sample replaces the cache.

A hardcoded **seed** (~45pt) to remove even the first-use jitter was considered and rejected: in a context where the inflation mechanism is absent, a seeded offset would make the keyboard land short and snap *up* on every appearance, and a zero offset can never be learned — a 0 measurement is indistinguishable from a not-yet-inflated layout pass, so the sampler must discard it.

### Offset key

The offset is persisted per `presentationOffset.{model}.ios{major}.{portrait|landscape}` (e.g. `presentationOffset.iPhone17,2.ios19.portrait`):

- **Device model** (`utsname.machine`): `UserDefaults` survives restoring a backup onto a different device, where the old offset may not apply — a new model recalibrates instead of inheriting it.
- **iOS major version**: an OS update may change the offset — or remove the inflation mechanism entirely, in which case the fresh key never observes a positive sample, never calibrates, and the trick gracefully never engages.
- **Orientation** comes from `view.window?.windowScene?.interfaceOrientation` *only*; when the scene isn't available the key is nil and that pass neither applies nor records an offset, rather than guessing. Two heuristic fallbacks were tried and were both wrong: `verticalSizeClass == .compact → landscape` is iPhone-only (on iPad the vertical size class is `.regular` in *both* orientations, collapsing iPad landscape into the portrait key), and the view's own bounds aspect is useless because a keyboard is wider than tall in *every* orientation.

### Critical timing detail

The offset **must be applied in `viewIsAppearing(_:)`** (and restored in `viewDidAppear`). Applying it earlier — in `viewDidLoad` or `viewWillAppear` — **reintroduces the jitter**. This was confirmed empirically on device; the precise reason iOS treats the earlier timing differently is not fully understood. `viewIsAppearing(_:)` is back-deployed to iOS 13, so it is safe at the project's iOS 13 deployment target.

Implementation: `ios/Keyboard/KeyboardViewController.swift` — `viewIsAppearing` / `viewDidAppear` / `viewDidLayoutSubviews` / `viewWillDisappear`, the `applyHeight()` / `samplePresentationOffset()` helpers, and the `presentationOffset` (UserDefaults) property. The height constraint stays `.defaultHigh`; `KeyboardView` is pinned to all four edges of the input view and its rows lay out proportionally, so it fills whatever height is applied.

### Self-healing: sample during the presenting window, never after

An earlier revision tried to validate the cache on the first `viewDidLayoutSubviews` *after* `viewDidAppear`: if `view.bounds.height` wasn't within 2pt of `target`, the cached offset was cleared. **This reintroduced jitter during fast keyboard switching.** The reason: iOS removes its presentation inflation *after* `viewDidAppear` (not at it), so the first layout pass after `viewDidAppear` can still observe inflated bounds (`target + offset`). The validator read that as a stale cache and wiped a perfectly correct offset — and fast switching made that racy layout pass more likely to hit, so the cache was repeatedly nuked and every switch became an uncalibrated one. At that instant there is no signal distinguishing "inflation not yet removed" from "offset genuinely stale."

The current continuous sampler heals without that ambiguity by only ever measuring **while presenting**, where inflated bounds are the *expected* state — a sample is a direct read of the true offset, never a misread of not-yet-removed inflation. The trade-off is that sampling is opportunistic: if a fast switch completes without a settled inflated layout pass landing inside the presenting window, nothing is recorded that time and the cache is left alone. (That the settled inflated pass normally does land in-window is proven by the original calibrate-once implementation, which only committed samples taken in that same window and calibrated reliably on device.)

## Caveats

The fix relies on **undocumented** iOS behavior (the presentation inflation); a future iOS could change it. Continuous sampling adapts to a different offset *value* (one jitter, then healed), and the iOS-major key means an OS update recalibrates from scratch — including gracefully never engaging if the update removes the mechanism entirely. The residual gap: if the mechanism disappears *within* an iOS major (or differs by context, e.g. iPad floating/split keyboards) while a calibrated key exists, the keyboard lands short and snaps **up** on those presentations, and a zero offset cannot be learned (a 0 measurement is ambiguous with a not-yet-inflated pass) — re-verify on device across iOS updates and iPad keyboard modes.

A **one-time calibration jitter** on first use per key is expected (matches the system keyboards' first-launch behavior).

During development, reinstalling the extension wipes the persisted offset, so the first switch after each install calibrates again. This is a dev-only artifact, not a shipping issue.

Only the **height** is matched, not key geometry; the keyboard intentionally keeps its own compact layout.
