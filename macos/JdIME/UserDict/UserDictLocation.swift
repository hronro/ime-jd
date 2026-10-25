// Where the macOS client keeps the phrases file. The format itself — lenient
// parsing for display, serialization, hashing — is shared source at
// bindings/swift/UserDictFile.swift, and the engine's per-row verdict at
// bindings/swift/UserDictProblem.swift.

import Foundation

extension UserDictFile {
    /// `~/Library/Application Support/<bundle id>/用户自造词.txt`.
    static func defaultURL() -> URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.hronro.ime-jd"
        return support
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
