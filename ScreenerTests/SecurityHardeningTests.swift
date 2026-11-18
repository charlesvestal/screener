import XCTest
@testable import Screener

/// Security review L3 / M2: server text sanitizing, private log values, the
/// redacted log export, and DEBUG wire-log body redaction.
final class SecurityHardeningTests: XCTestCase {

    // MARK: L3 — server strings

    func testServerTextStripsControlAndFormattingCharactersAndCaps() {
        XCTAssertEqual(ServerText.sanitize("line1\nFAKE [auth] AUTH OK\r\n"), "line1 FAKE [auth] AUTH OK")
        // Bidi override / zero-width characters can reorder or hide text.
        XCTAssertEqual(ServerText.sanitize("abc\u{202E}fed\u{200B}x"), "abc fed x")
        XCTAssertEqual(ServerText.sanitize("  a \t\t b  "), "a b")
        let long = String(repeating: "x", count: 500)
        let capped = ServerText.sanitize(long)
        XCTAssertEqual(capped.count, ServerText.defaultMaxLength + 1)
        XCTAssertTrue(capped.hasSuffix("…"))
        XCTAssertEqual(ServerText.sanitize("Macmini9,1\u{0}\u{7}", maxLength: 64), "Macmini9,1")
    }

    func testServerTextIsLabelledInTheUI() {
        XCTAssertEqual(ServerText.labelled("Too many attempts\n"), "Message from the Mac: “Too many attempts”")
        XCTAssertNil(ServerText.labelled("\n\u{0}"))
        XCTAssertNil(ServerText.labelled(nil))
        let refused = ControlSession.describe(RFBHandshakeError.serverRefused(reason: "Go away"))
        XCTAssertTrue(refused.contains("Message from the Mac: “Go away”"), refused)
        let rejected = UserFacingError.message(for: AuthError.rejected(reason: "Locked\nout"))
        XCTAssertTrue(rejected.hasPrefix(UserFacingError.authRejectedMessage), rejected)
        XCTAssertTrue(rejected.contains("Message from the Mac: “Locked out”"), rejected)
        let ss = ControlSessionError.sessionSelectUnsupported(consoleUser: "eve\n\u{202E}x").errorDescription ?? ""
        XCTAssertTrue(ss.contains("(eve x)"), ss)
    }

    // MARK: M2 — logs

    func testPrivateLogValuesAreRedactedOrMarked() {
        let host = "studio.local", user = "alex"
        let m: LogMessage = "connecting to \(private: host) as \(private: user) port \(5900)"
        XCTAssertEqual(m.redacted, "connecting to <private> as <private> port 5900")
        XCTAssertEqual(m.marked, "connecting to ⟦studio.local⟧ as ⟦alex⟧ port 5900")
        XCTAssertEqual(m.privateValues, ["studio.local", "alex"])
        #if DEBUG
        XCTAssertEqual(m.fileText, m.marked)
        #else
        XCTAssertEqual(m.fileText, m.redacted)
        #endif
    }

    func testLogExportRedactsAddressesAndNames() {
        let log = """
        12:34:56.789 [app] connecting to ⟦Alex’s Mac⟧ as ⟦192.168.1.20⟧
        12:34:56.790 [hosts] bonjour resolved Studio.local → 10.0.0.7:5900
        12:34:56.791 [media] bound fe80::1c2b:3aff:fe4d:5e6f%en0 version 1.2
        """
        let out = LogExport.redact(log)
        XCTAssertFalse(out.contains("Alex"), out)
        XCTAssertFalse(out.contains("192.168"), out)
        XCTAssertFalse(out.contains("10.0.0.7"), out)
        XCTAssertFalse(out.contains("Studio"), out)
        XCTAssertFalse(out.contains("fe80"), out)
        XCTAssertTrue(out.contains("x.x.x.7:5900"), out)
        XCTAssertTrue(out.contains("12:34:56.789"), "timestamps survive: \(out)")
        XCTAssertTrue(out.contains("#" + LogExport.shortHash("Alex’s Mac")), out)
        XCTAssertEqual(LogExport.shortHash("a"), LogExport.shortHash("a"))
    }

    func testLogFileIsNotInDocuments() {
        XCTAssertFalse(FileMirror.url.path.contains("/Documents/"))
        XCTAssertTrue(FileMirror.url.path.contains("/Library/Caches/Logs/"))
    }

    #if DEBUG
    func testWireLogNeverLogsKeyInputOrClipboardBodies() {
        let password = Data([0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x61])
        XCTAssertEqual(ControlSession.wireLine("tx enc", password, prefix: 32),
                       "wire tx enc len=8 type=0x04 <body redacted>")
        for type: UInt8 in [0x10, 0x1f] {
            let line = ControlSession.wireLine("tx enc", Data([type, 0xde, 0xad, 0xbe, 0xef]), prefix: 32)
            XCTAssertFalse(line.contains("deadbeef"), line)
            XCTAssertTrue(line.contains("len=5"), line)
        }
        XCTAssertTrue(ControlSession.wireLine("tx enc", Data([0x03, 0xab]), prefix: 32).hasSuffix("03ab"))
    }
    #endif
}
