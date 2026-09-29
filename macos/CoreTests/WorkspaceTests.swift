import Foundation
import XCTest

@MainActor
private final class WorkspaceFake: BackendExecuting {
    var commands: [BackendCommand] = []
    var reply = BackendResult()
    var paused = false
    var continuation: CheckedContinuation<BackendResult, Never>?
    var entered: (() -> Void)?
    func execute(_ command: BackendCommand) async -> BackendResult {
        commands.append(command)
        if paused {
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered?()
            }
        }
        return reply
    }
    func finish(_ reply: BackendResult) { continuation?.resume(returning: reply); continuation = nil }
}

@MainActor
final class WorkspaceTests: XCTestCase {
    private func setup() throws -> (WorkspaceModel, WorkspaceFake, Snapshot) {
        let fake = WorkspaceFake(), model = WorkspaceModel(backend: fake)
        var profile = try ProfileParser.parse("client\nremote vpn.example.test\nauth-user-pass\n", fallbackName: "Development").profile
        profile.authKind = .pin; profile.username = "demo"
        let state = Snapshot(profiles: [profile], sessions: [], helper: HelperStatus("enabled", "Ready"), logs: [])
        model.accept(state); fake.reply = BackendResult(snapshot: state)
        return (model, fake, state)
    }

    func testLaunchDoesNotConnectAndPINSubmissionClearsField() async throws {
        let (model, fake, state) = try setup()
        XCTAssertTrue(fake.commands.isEmpty)
        await model.toggle()
        XCTAssertEqual(model.modal, .credentials(state.profiles[0].id))
        XCTAssertFalse(model.rememberPassword)
        model.password = "synthetic-pin"; model.rememberPassword = true
        await model.submitCredentials()
        guard case .connect(let id, let password, let remember) = fake.commands.last else { return XCTFail("Missing connection") }
        XCTAssertEqual(id, state.profiles[0].id); XCTAssertEqual(password, "synthetic-pin"); XCTAssertTrue(remember)
        XCTAssertEqual(model.password, ""); XCTAssertNil(model.modal)
        XCTAssertEqual(model.connectedCount, 0)
        model.stopPolling()
    }

    func testRememberedAndCertificateConnectWithoutPasswordPrompt() async throws {
        for kind in [AuthKind.pin, .certificate] {
            let (model, fake, initial) = try setup(); var state = initial
            state.profiles[0].authKind = kind; state.profiles[0].remembered = kind == .pin
            model.accept(state); fake.reply.snapshot = state
            await model.toggle()
            guard case .connect(_, let password, let remember) = fake.commands.last else { return XCTFail("Missing connection") }
            XCTAssertNil(password); XCTAssertFalse(remember); XCTAssertNil(model.modal)
        }
    }

    func testConnectDisabledDuringRequestAndHandshake() async throws {
        for kind in ["remembered", "certificate", "pin"] {
            let (model, fake, initial) = try setup(); var state = initial
            state.profiles[0].remembered = kind == "remembered"
            if kind == "certificate" { state.profiles[0].authKind = .certificate }
            model.accept(state); fake.paused = true
            let entered = expectation(description: "backend received \(kind)")
            fake.entered = { entered.fulfill() }
            if kind == "pin" { await model.toggle(); model.password = "synthetic-pin" }
            let task = Task { if kind == "pin" { await model.submitCredentials() } else { await model.toggle() } }
            await fulfillment(of: [entered], timeout: 2)
            XCTAssertEqual(model.connectionButtonLabel, "Connecting…"); XCTAssertTrue(model.connectionButtonDisabled)
            XCTAssertEqual(model.statusLabel, "Connecting…")
            await model.toggle(); XCTAssertEqual(fake.commands.count, 1)
            state.sessions = [Session(profileId: state.profiles[0].id, sessionId: "s1", status: .connecting)]
            fake.finish(BackendResult(snapshot: state)); await task.value
            XCTAssertNil(model.modal); XCTAssertEqual(model.connectionButtonLabel, "Connecting…")
            XCTAssertTrue(model.connectionButtonDisabled)
            state.sessions[0].status = .connected; model.accept(state)
            XCTAssertEqual(model.connectionButtonLabel, "Disconnect"); XCTAssertFalse(model.connectionButtonDisabled)
        }
    }

    func testDisconnectStateChangesBeforeBackendCompletes() async throws {
        let (model, fake, initial) = try setup(); var state = initial
        state.sessions = [Session(profileId: state.profiles[0].id, sessionId: "s1", status: .connected)]
        model.accept(state); fake.paused = true
        let entered = expectation(description: "disconnect entered"); fake.entered = { entered.fulfill() }
        let task = Task { await model.toggle() }; await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(model.connectionButtonLabel, "Disconnecting…"); XCTAssertTrue(model.connectionButtonDisabled)
        await model.toggle(); XCTAssertEqual(fake.commands.count, 1)
        state.sessions[0].status = .disconnecting; fake.finish(BackendResult(snapshot: state)); await task.value
        XCTAssertEqual(model.connectionButtonLabel, "Disconnecting…"); XCTAssertTrue(model.connectionButtonDisabled)
        state.sessions[0].status = .disconnected; model.accept(state)
        XCTAssertEqual(model.connectionButtonLabel, "Connect to VPN"); XCTAssertFalse(model.connectionButtonDisabled)
    }

    func testFailedHandshakeReenablesConnectAndReconnectCanBeCancelled() throws {
        let (model, _, initial) = try setup(); var state = initial
        state.sessions = [Session(profileId: state.profiles[0].id, sessionId: "s1", status: .connecting)]
        model.accept(state); XCTAssertTrue(model.connectionButtonDisabled)
        state.sessions[0].status = .error; model.accept(state)
        XCTAssertFalse(model.connectionButtonDisabled); XCTAssertEqual(model.connectionButtonLabel, "Connect to VPN")
        state.sessions[0].status = .reconnecting; model.accept(state)
        XCTAssertFalse(model.connectionButtonDisabled); XCTAssertEqual(model.connectionButtonLabel, "Disconnect")
    }

    func testStalledDisconnectOffersRetryWithoutConnectingAgain() async throws {
        let (model, fake, initial) = try setup(); var state = initial
        var session = Session(profileId: state.profiles[0].id, sessionId: "s1", status: .disconnecting)
        session.errorCode = "disconnect_timeout"; session.error = "Cleanup has not finished"
        state.sessions = [session]; model.accept(state); fake.reply.snapshot = state
        XCTAssertEqual(model.connectionButtonLabel, "Retry disconnect")
        XCTAssertEqual(model.statusLabel, "Disconnect stalled")
        XCTAssertFalse(model.connectionButtonDisabled); XCTAssertEqual(model.activeCount, 1)
        await model.toggle()
        guard case .disconnect(let id) = fake.commands.last else { return XCTFail("Must retry disconnect") }
        XCTAssertEqual(id, session.profileId); XCTAssertEqual(fake.commands.count, 1)
        XCTAssertNil(model.modal)
    }

    func testRejectedRequestClearsPendingState() async throws {
        let (model, fake, initial) = try setup(); var state = initial; state.profiles[0].remembered = true
        model.accept(state); fake.reply = BackendResult(snapshot: state, failure: AppError("helper_unavailable", "Helper unavailable"))
        await model.toggle()
        XCTAssertEqual(model.error, "Helper unavailable"); XCTAssertNil(model.connectingID)
        XCTAssertFalse(model.connectionButtonDisabled); XCTAssertEqual(model.connectionButtonLabel, "Connect to VPN")
    }

    func testLockedKeychainAsksForCredentialsAgain() async throws {
        let (model, fake, initial) = try setup(); var state = initial; state.profiles[0].remembered = true
        model.accept(state); fake.reply = BackendResult(snapshot: state, failure: AppError("keychain", "Locked"))
        await model.toggle()
        XCTAssertEqual(model.modal, .credentials(state.profiles[0].id)); XCTAssertEqual(model.error, "")
    }

    func testHelperUnavailableRoutesToSettings() async throws {
        let (model, fake, initial) = try setup(); var state = initial; state.helper.status = "not_registered"
        model.accept(state); await model.toggle()
        XCTAssertEqual(model.screen, .setup); XCTAssertTrue(fake.commands.isEmpty)
    }

    func testTrafficIsPerProfileAndResetOnlyWhenInactive() throws {
        let (model, _, initial) = try setup(); var state = initial
        var other = state.profiles[0]; other.id = UUID().uuidString; state.profiles.append(other)
        var a = Session(profileId: state.profiles[0].id, sessionId: "a", status: .connected)
        a.bytesIn = 1_500_000; a.bytesOut = 10_000_000
        var b = Session(profileId: other.id, sessionId: "b", status: .connected); b.bytesIn = 5_000_000_000; b.bytesOut = 2000
        state.sessions = [a, b]; model.accept(state)
        XCTAssertEqual(model.trafficLabel, "Received 1.5MB / Sent 10MB")
        model.selectedID = other.id; XCTAssertEqual(model.trafficLabel, "Received 5GB / Sent 2KB")
        model.selectedID = a.profileId; state.sessions[0].status = .reconnecting; model.accept(state)
        XCTAssertEqual(model.trafficLabel, "Received 1.5MB / Sent 10MB")
        state.sessions[0].status = .disconnected; model.accept(state)
        XCTAssertEqual(model.trafficLabel, "Received 0 B / Sent 0 B")
    }

    func testProfileEditPreservesHiddenDNS() async throws {
        let (model, fake, initial) = try setup(); var state = initial
        state.profiles[0].dns = DNSSettings(servers: [try IPv4("10.0.0.53")], domains: ["dev.example.test"])
        model.accept(state); model.openModal(.settings(state.profiles[0].id))
        var update = ProfileUpdate(try XCTUnwrap(model.modalProfile)); update.name = "Renamed"
        await model.saveProfile(update)
        guard case .update(_, let sent) = fake.commands.last else { return XCTFail("Missing update") }
        XCTAssertEqual(sent.dns, state.profiles[0].dns); model.stopPolling()
    }

    func testForbiddenRememberPreferenceIsNeverSent() async throws {
        let (model, fake, initial) = try setup(); var state = initial; state.profiles[0].allowPasswordSave = false
        model.accept(state); await model.toggle(); model.password = "synthetic"; model.rememberPassword = true
        await model.submitCredentials()
        guard case .connect(_, _, let remember) = fake.commands.last else { return XCTFail("Missing connect") }
        XCTAssertFalse(remember)
    }

    func testQuitKeepsApplicationAliveWhenCleanupFails() async throws {
        let (model, fake, _) = try setup()
        fake.reply.failure = AppError("cleanup_failed", "Cleanup pending")
        let failed = await model.prepareToQuit()
        XCTAssertFalse(failed); XCTAssertFalse(model.quitting); XCTAssertEqual(model.error, "Cleanup pending")
        fake.reply.failure = nil
        let ready = await model.prepareToQuit()
        XCTAssertTrue(ready); XCTAssertTrue(model.quitting)
    }

    func testWorkerUsesDedicatedExecutorWithoutMainThreadBlocking() async throws {
        let worker = BackendWorker(makeBackend: {
            XCTAssertFalse(Thread.isMainThread)
            throw AppError("synthetic", "Expected test failure")
        })
        let result = await worker.execute(.refresh(credentials: false))
        XCTAssertEqual(result.failure?.code, "synthetic")
    }
}
