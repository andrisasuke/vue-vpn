import Foundation
import XCTest

final class BackendTests: XCTestCase {
    private func setup() throws -> (VPNBackend, FakeBridge, FakeClock, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vuevpn-backend-" + UUID().uuidString)
        let store = try ProfileStore(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let imported = try ProfileParser.parse("client\ndev tun\nremote vpn.example.test\nauth-user-pass\n", fallbackName: "Development")
        var profile = imported.profile; profile.username = "demo"
        try store.save(profile, content: imported.content)
        let fake = FakeBridge(), clock = FakeClock(); fake.allowVPNOperations = true
        return (try VPNBackend(store: store, bridge: fake, clock: clock), fake, clock, profile.id)
    }

    private func second(_ backend: VPNBackend, name: String = "Second") throws -> String {
        let file = backend.store.root.appendingPathComponent("import-test.ovpn")
        try Data("# {\"user\":\"demo\",\"server\":\"\(name)\"}\nclient\nremote vpn.example.test\nauth-user-pass\n".utf8).write(to: file)
        return try backend.importProfile(file)
    }

    func testConstructionDoesNotConnectOrTouchKeychain() throws {
        let (_, fake, _, _) = try setup()
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testSaveOnlyAfterConnectedAndNeverExposeSecret() throws {
        let (b, f, _, id) = try setup()
        try b.connect(id, password: "unit-test-secret", remember: true)
        XCTAssertTrue(f.saved.isEmpty)
        f.sessions[0].status = .connected; try b.refresh(); try b.refresh()
        XCTAssertEqual(f.saved[id], "unit-test-secret"); XCTAssertEqual(f.saveCount, 1)
        XCTAssertTrue(try b.get(id).remembered)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(b.snapshot), as: UTF8.self).contains("unit-test-secret"))
        let file = try b.store.directory(id).appendingPathComponent("profile.json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("unit-test-secret"))
    }

    func testForgetCancelsPendingRememberAndAuthFailureDeletesSavedSecret() throws {
        let (b, f, _, id) = try setup()
        try b.connect(id, password: "test-pin", remember: true); try b.forget(id)
        f.sessions[0].status = .connected; try b.refresh(); XCTAssertTrue(f.saved.isEmpty)
        f.saved[id] = "rejected"; f.sessions[0].status = .error; f.sessions[0].errorCode = "AUTH_FAILED"
        try b.refresh(); XCTAssertTrue(f.saved.isEmpty); XCTAssertFalse(try b.get(id).remembered)
    }

    func testMissingSavedSecretRequiresInputAndServerCanForbidSaving() throws {
        let (b, f, _, id) = try setup()
        XCTAssertThrowsError(try b.connect(id)) { XCTAssertEqual(($0 as? AppError)?.code, "credentials_required") }
        XCTAssertTrue(f.connections.isEmpty); f.allowSave = false
        try b.connect(id, password: "test-pin", remember: true)
        f.sessions[0].status = .connected; try b.refresh()
        XCTAssertTrue(f.saved.isEmpty); XCTAssertFalse(try b.get(id).allowPasswordSave)
    }

    func testFullTunnelConflictIsRejectedBeforeSecondConnect() throws {
        let (b, f, _, id) = try setup()
        try b.connect(id, password: "one")
        let other = try second(b)
        XCTAssertThrowsError(try b.connect(other, password: "two")) { XCTAssertEqual(($0 as? AppError)?.code, "full_tunnel_conflict") }
        XCTAssertEqual(f.connections.count, 1)
    }

    func testEditingRoutingReconnectsOnlyTargetWithVolatileCredential() throws {
        let (b, f, _, id) = try setup()
        var update = ProfileUpdate(try b.get(id)); update.routingMode = .selected
        update.routes = [try VPNPolicy.route(IPv4("10.1.0.0"), 16)]; try b.update(id, update)
        try b.connect(id, password: "memory-only")
        let other = try second(b); var secondUpdate = ProfileUpdate(try b.get(other)); secondUpdate.routingMode = .selected
        secondUpdate.routes = [try VPNPolicy.route(IPv4("10.2.0.0"), 16)]; try b.update(other, secondUpdate)
        try b.connect(other, password: "second")
        f.cleanupPolls = 2; update.routes = [try VPNPolicy.route(IPv4("10.3.0.0"), 16)]; try b.update(id, update)
        XCTAssertEqual(f.disconnected, [id]); XCTAssertEqual(f.connections.last?.id, id)
        XCTAssertEqual(f.connections.last?.password, "memory-only"); XCTAssertTrue(f.saved.isEmpty)
        XCTAssertTrue(b.active(other))
    }

    func testHelperUpdateDefersUntilDisconnect() throws {
        let (b, f, _, id) = try setup()
        try b.connect(id, password: "saved-pin", remember: true)
        f.sessions[0].status = .connected; f.running = nil; try b.refresh()
        XCTAssertEqual(b.helper.status, "update_pending"); XCTAssertTrue(b.active(id)); XCTAssertEqual(f.replacements, 0)
        XCTAssertTrue(f.disconnected.isEmpty)
        XCTAssertThrowsError(try b.connect(id)) { XCTAssertEqual(($0 as? AppError)?.code, "helper_setup") }
        try b.disconnect(id); XCTAssertEqual(b.helper.status, "updating"); XCTAssertEqual(f.replacements, 1)
        XCTAssertThrowsError(try b.disconnectAll()) { XCTAssertEqual(($0 as? AppError)?.code, "helper_updating") }
        f.running = "current"; f.status = "enabled"; f.sessions = []; try b.refresh()
        XCTAssertEqual(b.helper.status, "enabled"); XCTAssertTrue(b.logs.contains { $0.message == "VPN helper updated successfully." })
        XCTAssertEqual(f.saved[id], "saved-pin"); try b.connect(id); XCTAssertEqual(f.connections.count, 2)
    }

    func testQuitCleanupNeverStartsAsyncReplacement() throws {
        let (b, f, _, id) = try setup(); try b.connect(id, password: "test-pin")
        f.running = nil; try b.refresh(); XCTAssertEqual(b.helper.status, "update_pending")
        try b.disconnectAll(); XCTAssertFalse(b.active(id)); XCTAssertEqual(f.replacements, 0)
        try b.refresh(); XCTAssertEqual(f.replacements, 1)
    }

    func testMissingRegistrationRecoversWithoutEnable() throws {
        let (b, f, _, _) = try setup(); f.status = "not_found"
        try b.refresh(); XCTAssertEqual(b.helper.status, "updating")
        try b.refresh(); XCTAssertEqual(b.helper.status, "enabled")
        XCTAssertEqual(f.registrations, 1); XCTAssertEqual(f.replacements, 0); XCTAssertTrue(f.connections.isEmpty)
    }

    func testRetryCompletesRegistrationWithoutExtraEnableClick() throws {
        let (b, f, _, _) = try setup(); f.running = nil; try b.refresh()
        XCTAssertEqual(b.helper.status, "updating"); f.status = "update_failed"; try b.refresh()
        XCTAssertEqual(b.helper.status, "update_failed"); f.status = "not_registered"
        XCTAssertEqual(try b.helperAction("retry_update").status, "updating")
        f.running = "current"; try b.refresh(); XCTAssertEqual(b.helper.status, "enabled")
        XCTAssertEqual(f.registrations, 1); XCTAssertEqual(f.replacements, 1)
    }

    func testHelperInterruptionDoesNotSavePasswordOrReportStaleConnection() throws {
        let (b, f, _, id) = try setup(); try b.connect(id, password: "ephemeral-pin", remember: true)
        f.snapshotError = true; try b.refresh()
        XCTAssertEqual(b.helper.status, "recovering"); XCTAssertEqual(b.sessions[0].status, .reconnecting)
        XCTAssertEqual(f.saveCount, 0); f.snapshotError = false; f.sessions[0].status = .connected
        try b.refresh(); XCTAssertEqual(b.sessions[0].status, .connected); XCTAssertEqual(f.saveCount, 1)
    }

    func testOrdinaryDisconnectReturnsWhileCleanupPending() throws {
        let (b, f, _, id) = try setup(); try b.connect(id, password: "test"); f.cleanupPolls = 10
        try b.disconnect(id); XCTAssertEqual(b.sessions[0].status, .disconnecting); XCTAssertTrue(f.disconnecting)
    }

    func testStalledDisconnectRemainsActiveAndRetryRestartsDeadline() throws {
        let (b, f, clock, id) = try setup()
        try b.connect(id, password: "test"); f.cleanupPolls = 1000
        try b.disconnect(id)
        clock.monotonic = 29; try b.refresh()
        XCTAssertFalse(b.sessions[0].disconnectStalled)
        clock.monotonic = 30; try b.refresh()
        XCTAssertTrue(b.sessions[0].disconnectStalled); XCTAssertTrue(b.active(id))
        XCTAssertTrue(b.sessions[0].error?.contains("30 seconds") == true)
        let count = b.logs.count
        clock.monotonic = 3600; try b.refresh()
        XCTAssertEqual(b.logs.count, count)
        XCTAssertThrowsError(try b.connect(id, password: "test"))
        XCTAssertThrowsError(try b.helperAction("unregister"))
        XCTAssertNoThrow(try b.get(id)); XCTAssertEqual(f.connections.count, 1)
        XCTAssertEqual(f.replacements, 0)
        try b.disconnect(id)
        XCTAssertFalse(b.sessions[0].disconnectStalled)
        f.cleanupPolls = 0; try b.refresh()
        XCTAssertEqual(b.sessions[0].status, .disconnected)
        XCTAssertNil(b.sessions[0].errorCode)
    }

    func testStalledDisconnectDefersHelperUpdateAndDoesNotStopOtherProfile() throws {
        let (b, f, clock, id) = try setup()
        var update = ProfileUpdate(try b.get(id)); update.routingMode = .selected
        update.routes = [try VPNPolicy.route(IPv4("10.1.0.0"), 16)]; try b.update(id, update)
        try b.connect(id, password: "one")
        let other = try second(b); update = ProfileUpdate(try b.get(other)); update.routingMode = .selected
        update.routes = [try VPNPolicy.route(IPv4("10.2.0.0"), 16)]; try b.update(other, update)
        try b.connect(other, password: "two"); f.sessions[1].status = .connected
        f.running = "old"; f.cleanupPolls = 1000; try b.disconnect(id)
        clock.monotonic = 31; try b.refresh()
        XCTAssertTrue(b.sessions[0].disconnectStalled)
        XCTAssertEqual(b.sessions[1].status, .connected)
        XCTAssertEqual(b.helper.status, "update_pending"); XCTAssertEqual(f.replacements, 0)
        XCTAssertEqual(f.disconnected, [id])
    }

    func testDisconnectAlreadyPendingOnStartupGetsDeadlineWithoutHidingHelperError() throws {
        let (b, f, clock, id) = try setup()
        f.sessions = [Session(profileId: id, sessionId: "existing", status: .disconnecting)]
        try b.refresh(); clock.monotonic = 30; try b.refresh()
        XCTAssertTrue(b.sessions[0].disconnectStalled)
        f.sessions[0].status = .error; f.sessions[0].errorCode = "cleanup_failed"
        f.sessions[0].error = "Route still present"; try b.refresh()
        XCTAssertFalse(b.sessions[0].disconnectStalled)
        XCTAssertEqual(b.sessions[0].error, "Route still present")
        f.sessions = [Session(profileId: id, sessionId: "new", status: .disconnecting)]
        try b.refresh(); XCTAssertFalse(b.sessions[0].disconnectStalled)
        f.sessions[0].errorCode = "TRANSPORT_ERROR"; f.sessions[0].error = "Network unreachable"
        clock.monotonic += 30; try b.refresh()
        XCTAssertTrue(b.sessions[0].disconnectStalled)
        XCTAssertTrue(b.sessions[0].error?.contains("Network unreachable") == true)
    }

    func testQuitAndDeleteWaitForCleanupAndSurfaceFailure() throws {
        let (b, f, _, id) = try setup(); try b.connect(id, password: "test"); f.cleanupPolls = 1
        try b.disconnectAll(); XCTAssertFalse(f.disconnecting); XCTAssertFalse(b.sessions[0].active)
        try b.connect(id, password: "test"); f.cleanupPolls = 1; f.cleanupError = true
        XCTAssertThrowsError(try b.delete(id)) { XCTAssertEqual(($0 as? AppError)?.code, "cleanup_failed") }
        XCTAssertNoThrow(try b.get(id))
    }

    func testCleanupDeadlineDoesNotHangAndKeepsProfile() throws {
        let (b, f, clock, id) = try setup(); try b.connect(id, password: "test"); f.cleanupPolls = 1000
        XCTAssertThrowsError(try b.delete(id)) { XCTAssertEqual(($0 as? AppError)?.code, "cleanup_pending") }
        XCTAssertEqual(clock.monotonic, 30); XCTAssertNoThrow(try b.get(id))
    }

    func testTrafficCountersDoNotCreateActivityEvents() throws {
        let (b, f, _, id) = try setup(); try b.connect(id, password: "test"); f.sessions[0].status = .connected
        try b.refresh(); XCTAssertEqual(b.sessions[0].bytesIn, 0); XCTAssertEqual(b.sessions[0].bytesOut, 0)
        let count = b.logs.count
        for (received, sent): (UInt64, UInt64) in [(100, 100_000), (1_500_000, 5_000_000_000)] {
            f.sessions[0].bytesIn = received; f.sessions[0].bytesOut = sent; try b.refresh()
            XCTAssertEqual(b.snapshot.sessions[0].bytesIn, received); XCTAssertEqual(b.snapshot.sessions[0].bytesOut, sent)
            XCTAssertEqual(b.logs.count, count)
        }
    }

    func testNameOnlyEditDoesNotReconnectAndSavedCredentialsAreReused() throws {
        let (b, f, _, id) = try setup(); f.saved[id] = "existing"; b.refreshCredentials()
        XCTAssertTrue(try b.get(id).remembered); try b.connect(id)
        XCTAssertEqual(f.connections.first?.password, "existing")
        var update = ProfileUpdate(try b.get(id)); update.name = "Renamed"; try b.update(id, update)
        XCTAssertEqual(f.connections.count, 1); XCTAssertTrue(f.disconnected.isEmpty)
    }

    func testWireRequestPreservesVersionAndCamelCase() throws {
        let request = HelperRequest(op: "connect", profileId: "profile", sessionId: "session", password: "synthetic")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1); XCTAssertEqual(object["profileId"] as? String, "profile")
        XCTAssertEqual(object["sessionId"] as? String, "session"); XCTAssertNil(object["profile_id"])
    }
}
