# Keyboard-switch height jitter

## Status

The keyboard asks for its own height (candidate bar + rows) through one `.defaultHigh` constraint on the input view, **one point less from `viewIsAppearing` to `viewDidAppear`** (`KeyboardViewController.applyHeight`). Restoring that point in `viewDidAppear` is what keeps iOS 18 from flashing the keyboard 45 pt taller on every switch. It replaced, in November 2026, a learned "presentation offset" (see History) that worked by the same restore but also landed the keyboard visibly short.

## What iOS 18 does on a switch

Measured in November 2026 on an iPhone 16 Pro Max running iOS 18.2, in our own text view and in Safari's address bar, by logging every layout pass of the extension's view and the keyboard frames the host app is told about, and by recording the phone's screen over USB at 60 fps and finding the panel's top edge in every frame:

1. The input view first lays out at the full-screen transient (956 pt on that phone). It is never painted.
2. Around `viewIsAppearing`, iOS lays it out **taller than requested**: 325 pt for a requested 280 pt on a switch to a running extension, 288 pt on the first switch after the extension process starts. The amount does not depend on what is requested in `viewIsAppearing`.
3. Left alone, iOS brings it down to the requested height ~17 ms after `viewDidAppear`, after the tall layout has reached the screen: the whole panel shows ~45 pt taller, keys stretched, for one or two frames, then snaps back. Seen on every switch (4 of 4 in the recording).
4. A change of the height constraint in `viewDidAppear` makes iOS apply the requested height at once, before that frame is drawn: no tall frame in 7 of 7 switches with the one-point restore (and 0 of 6 with the old learned offset). Holding the constraint a point short from `viewIsAppearing` is only there to make the restore a change. iOS sometimes lays the keyboard out at the short request for a frame or two; one point short cannot be seen.

iOS 27 lays the view out at the requested height straight away; the restore changes nothing visible there.

### Not ours: the first switch in each app

The first time an app shows 键道 after it launched (and the first time after an install), iOS shows the keyboard panel at 243 pt — the host is told 318 pt including the globe/dictation strip — for 80–150 ms, then grows it to ours. It does so before the extension process has even started, so it is iOS's stand-in height for a keyboard that app has not shown yet. The App Store build with the old trick does the same.

## History

### The learned presentation offset (June–November 2026)

An investigation in June 2026 (same phone, Safari's address bar, App Library search) read the switch as `956 → 305 → 260` when requesting 260 pt and `956 → 350 → 305` when requesting 305 pt, concluded that iOS adds a constant to whatever is requested, and built a trick on that model (Apple Developer Forums thread 799003 describes the general idea): request `target − offset` in `viewIsAppearing` so the inflation would land on `target`, restore `target` in `viewDidAppear`, and learn `offset` from `bounds.height − constraint` during the slide-in, stored in the extension's standard `UserDefaults` per device model, iOS major version and orientation. It was first calibrate-once and later sampled on every slide-in (`4c451c4`).

The November measurements showed why it went wrong:

- **iOS ignored the request.** In 24 of 24 switches in our text view and 13 of 13 in Safari, the extension's view came out at 325 pt (or 288 pt) whatever had been requested (272, 227, 182, 174, 166, 158 pt). What prevented the tall frame was the restore in `viewDidAppear` alone.
- **When iOS did honour it, the keyboard landed short.** On the first switch after a process start (Safari: 288 → 174 → 280 pt) and now and then during fast switching (325 → 182 → 280 pt, the host told 257 pt), a visibly shorter keyboard showed for a few frames and the host's layout jumped.
- **The sampler fed on its own output.** With the request ignored, each sample read `325 − (280 − cached)`, i.e. the cached offset plus 45 pt, so the stored offset ratcheted 8 → 53 → 98 → 106 → 114 → 122 pt on the phone (45 → 90 → 135 pt on the simulator), making the short landings shorter. Samples were only dropped at half the target height, so the value never healed.

Removing the trick outright brought back the tall frame on every switch, which is how the restore was found to be the part that mattered. Old builds leave `presentationOffset.<model>.ios<major>.<orientation>` keys in the extension's standard `UserDefaults`; nothing reads them any more.

### Other things tried in June 2026

| Attempt | Result |
|---|---|
| Idempotent height updates; stop re-stamping height in `traitCollectionDidChange` | No effect |
| Bottom-pin content at a fixed height so keys don't stretch | Keys stopped stretching, but the panel's background still grew; reverted |
| Transparent input-view background | Hides our band, but the panel still moved |
| Height constraint `.required` instead of `.defaultHigh` | No effect: the system overrides it |
| `UIInputView.allowsSelfSizing` + content-driven height | No effect |
| Full Access | Ruled out: Gboard behaves the same without it |

## Measuring it

Logs of the input view's layout passes are not enough: the extension's view read 325 pt in the tall frame whether or not it reached the screen. Record the phone's screen (QuickTime-style capture of the USB-attached device, 60 fps) and find the keyboard panel's top edge in each frame; a tall frame stands out as a single frame 45 pt (135 px at 3×) above the others.
