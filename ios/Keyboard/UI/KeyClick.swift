import AudioToolbox

/// Plays the stock keyboard's press sounds via System Sound Services
/// (AudioToolbox).
///
/// This is the audio path that works inside the extension sandbox WITHOUT
/// Full Access — short system sounds don't touch the audio-session/media
/// machinery that open access gates (it's how the major no-open-access
/// keyboards click). `UIDevice.playInputClick()` is the documented
/// alternative but silently no-ops or hangs in extensions on various iOS
/// versions, so shipping keyboards avoid it.
///
/// Clicks are muted by the ring/silent switch and play at ringer volume,
/// like the system keyboard's. The Settings ▸ Sounds ▸ Keyboard Clicks
/// toggle does NOT reach us (it only governs `playInputClick`), so opting
/// out would need an in-keyboard setting.
enum KeyClick {
    /// The system keyboard's own click set (iOS 10+): letters, delete, and
    /// modifiers each have a distinct sound.
    private static let input: SystemSoundID = 1123
    private static let delete: SystemSoundID = 1155
    private static let modifier: SystemSoundID = 1156

    /// Touch-down sound for a key.
    static func play(_ cap: KeyCap) {
        switch cap {
        case .char, .insertLiteral:                  play(input)
        case .backspace:                             play(delete)
        case .shift, .toLayer, .globe, .space, .ret: play(modifier)
        case .spacer:                                break
        }
    }

    /// Candidate taps insert text, so they use the letter-key sound.
    static func playInput() { play(input) }

    /// Bar/grid controls (expand chevron, close) sound like modifiers.
    static func playModifier() { play(modifier) }

    private static func play(_ id: SystemSoundID) {
        // Off the touch path: a play can stall for a few ms (the first one
        // especially, while the sample loads), which would read as popup lag.
        DispatchQueue.global().async { AudioServicesPlaySystemSound(id) }
    }
}
