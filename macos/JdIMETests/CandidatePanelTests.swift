import InputMethodKit
import XCTest
@testable import JdIME

/// IMKServer keeps the newest IMKCandidates created against it in an
/// unretained ivar and messages it on every activation, deactivation and key.
/// A panel owned by an input controller dies with it and leaves the server
/// pointing at freed memory: the IME then crashes on the next activation,
/// and macOS stops using it in every running app after a few crashes in a
/// row. This pins the invariant that prevents it: controllers come and go,
/// the server's panel stays the process-wide one.
final class CandidatePanelTests: XCTestCase {
    func testControllersLeaveTheServerOnTheSharedPanel() throws {
        let server = try XCTUnwrap(
            (NSApp.delegate as? AppDelegate)?.server,
            "the test host should have created its IMKServer"
        )
        let shared = try XCTUnwrap(Candidates.shared, "AppDelegate installs the panel")

        // The server's own pointer, read without retaining it (retaining a
        // dangling one is exactly the crash this guards against).
        let getter = NSSelectorFromString("_IMKCandidates")
        guard server.responds(to: getter) else {
            throw XCTSkip("this macOS's IMKServer has no _IMKCandidates")
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?
        let serverPanel = { unsafeBitCast(server.method(for: getter), to: Getter.self)(server, getter) }
        let sharedPanel = UnsafeRawPointer(Unmanaged.passUnretained(shared.panel).toOpaque())

        XCTAssertEqual(serverPanel(), sharedPanel)

        autoreleasepool {
            var controllers: [InputController] = (0..<3).map { _ in
                InputController(server: server, delegate: nil, client: nil)
            }
            XCTAssertEqual(serverPanel(), sharedPanel, "creating a controller must not register a panel")
            controllers.removeAll()
        }

        XCTAssertEqual(serverPanel(), sharedPanel, "releasing controllers must not leave the server dangling")
        XCTAssertFalse(shared.panel.isVisible())
    }
}
