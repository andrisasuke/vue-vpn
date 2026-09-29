import CryptoKit
import XCTest

final class MenuTests: XCTestCase {
    private func snapshot(_ statuses: [SessionStatus]) throws -> Snapshot {
        var profiles: [Profile] = []
        for i in statuses.indices {
            var p = try ProfileParser.parse("client\nremote vpn.example.test\n", fallbackName: "Profile \(i)").profile
            p.id = "profile-\(i)"; profiles.append(p)
        }
        return Snapshot(profiles: profiles, sessions: statuses.enumerated().map {
            Session(profileId: "profile-\($0.offset)", sessionId: "session-\($0.offset)", status: $0.element)
        }, helper: HelperStatus("enabled", "Ready"), logs: [])
    }

    func testConnectedIndicatorTakesPriorityOverOtherProfiles() throws {
        let menu = MenuPresentation(snapshot: try snapshot([.connecting, .connected, .error]))
        XCTAssertEqual(menu.indicator, .connected)
        XCTAssertEqual(menu.tooltip, "VueVPN — Connected")
        XCTAssertEqual(menu.items.map(\.title), ["Open VueVPN", "Profile 0  ·  Connecting…",
            "Profile 1  ·  Disconnect", "Profile 2  ·  Connect", "Disconnect All", "Quit VueVPN"])
    }

    func testNoActiveSessionUsesGrayIconAndDisablesDisconnectAll() throws {
        for statuses: [SessionStatus] in [[], [.disconnected], [.error, .awaitingCredentials]] {
            let menu = MenuPresentation(snapshot: try snapshot(statuses))
            XCTAssertEqual(menu.indicator, .disconnected)
            XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.action == .disconnectAll }).enabled)
        }
    }

    func testPendingRequestDisablesTheMenuActionBeforeSnapshotArrives() throws {
        let state = try snapshot([.disconnected])
        let menu = MenuPresentation(snapshot: state, busy: true, connectingID: "profile-0")
        XCTAssertEqual(menu.indicator, .connecting)
        XCTAssertEqual(menu.items[1].title, "Profile 0  ·  Connecting…")
        XCTAssertFalse(menu.items[1].enabled)
        XCTAssertFalse(menu.items.last!.enabled)
        XCTAssertTrue(menu.items[0].enabled)
    }

    func testReconnectingCanBeCancelledButDisconnectingCannotBeRepeated() throws {
        let menu = MenuPresentation(snapshot: try snapshot([.reconnecting, .disconnecting]))
        XCTAssertEqual(menu.indicator, .connecting)
        XCTAssertTrue(menu.items[1].enabled)
        XCTAssertEqual(menu.items[1].title, "Profile 0  ·  Disconnect")
        XCTAssertFalse(menu.items[2].enabled)
        XCTAssertEqual(menu.items[2].title, "Profile 1  ·  Disconnecting…")
    }

    func testTrafficAndLogUpdatesDoNotRebuildTheMenu() throws {
        var state = try snapshot([.connected])
        let initial = MenuPresentation(snapshot: state)
        state.sessions[0].bytesIn = 42_000; state.sessions[0].bytesOut = 150_000
        state.logs = [LogEntry(timestamp: 1, profileId: "profile-0", message: "Synthetic event")]
        XCTAssertEqual(initial, MenuPresentation(snapshot: state))
        state.profiles[0].name = "Renamed"
        XCTAssertNotEqual(initial, MenuPresentation(snapshot: state))
    }

    func testStalledDisconnectIsRetryableAndStillOwnsSession() throws {
        var state = try snapshot([.disconnecting, .connected])
        state.sessions[0].errorCode = "disconnect_timeout"
        let menu = MenuPresentation(snapshot: state)
        XCTAssertEqual(menu.items[1].title, "Profile 0  ·  Retry disconnect")
        XCTAssertTrue(menu.items[1].enabled); XCTAssertEqual(menu.indicator, .connected)
        XCTAssertTrue(menu.items.first { $0.action == .disconnectAll }!.enabled)
        let pending = MenuPresentation(snapshot: state, disconnectingID: "profile-0")
        XCTAssertFalse(pending.items[1].enabled)
        XCTAssertEqual(pending.items[1].title, "Profile 0  ·  Disconnecting…")
    }

    func testStatusIconBytesMatchTheOriginalRustRendererExactly() {
        // SHA-256 of straight RGBA from tray_image at c653eadfa02fef26bc6743b22b277adef8b5701b.
        // Computed by compiling that isolated function, without Tauri or any UI.
        let expected: [(MenuPresentation.Indicator, String)] = [
            (.disconnected, "04383f8fc7e4fb6e08dcf7041f9993d1d75a58bbb89c08542a4e61bd12388139"),
            (.connecting, "cc361d3b63a0a5a5b2bc264e85b001d7fcc5d5f0b9efbdf4225763f3e277df9d"),
            (.connected, "641de2c74c517903cb34802e715e83afb2fa04dc1178c158d2378ea21a3baf17"),
        ]
        for (indicator, hash) in expected {
            let bytes = StatusIcon.rgba(indicator)
            XCTAssertEqual(bytes.count, 44*36*4)
            XCTAssertEqual(SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined(), hash)
        }
    }
}
