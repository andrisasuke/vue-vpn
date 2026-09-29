import Foundation
import XCTest

final class FakeClock: VPNClock {
    var monotonic: TimeInterval = 0
    var unixSeconds: UInt64 { 1_800_000_000 + UInt64(monotonic) }
    func sleep(_ seconds: TimeInterval) { monotonic += seconds }
}

final class FakeBridge: VPNBridge {
    var status = "enabled", bundled: String? = "current", running: String? = "current"
    var sessions: [Session] = [], calls: [String] = []
    var snapshotError = false, replaceError = false, identityError = false, registrationError = false
    var registrationStatus = "enabled", allowSave = true
    var saved: [String: String] = [:], connections: [(id: String, password: String)] = []
    var saveCount = 0, disconnected: [String] = [], cleanupPolls = 0, cleanupError = false
    var disconnecting = false
    var allowVPNOperations = false
    var replacements: Int { calls.filter { $0 == "service:replace" }.count }
    var registrations: Int { calls.filter { $0 == "service:register_update" }.count }

    func service(_ operation: String) throws -> HelperStatus {
        calls.append("service:" + operation)
        switch operation {
        case "status", "reconnect": break
        case "replace":
            if replaceError { throw AppError("helper_setup", "Mock replace failure") }
            status = "updating"
        case "reset_update":
            if ["update_failed", "update_retry_pending"].contains(status) { status = "enabled" }
        case "register_update":
            if registrationError { throw AppError("helper_setup", "Invalid signature or authorization") }
            status = registrationStatus
        default: throw AppError("test", "Unexpected service operation: \(operation)")
        }
        return HelperStatus(status, "Mock helper")
    }

    func bundledHelperID() throws -> String? {
        calls.append("identity:identity")
        if identityError { throw AppError("helper_bundle", "Invalid bundled signature") }
        return bundled
    }

    func request(_ request: HelperRequest) throws -> HelperReply {
        calls.append("request:" + request.op)
        if request.op == "snapshot" {
            if snapshotError { throw AppError("helper_unavailable", "Unavailable") }
            if disconnecting {
                if cleanupPolls == 0 {
                    for i in sessions.indices where sessions[i].status == .disconnecting {
                        sessions[i].status = cleanupError ? .error : .disconnected
                        if cleanupError { sessions[i].errorCode = "cleanup_failed" }
                    }
                    disconnecting = false
                } else { cleanupPolls -= 1 }
            }
            return HelperReply(buildId: running, sessions: sessions)
        }
        guard allowVPNOperations else {
            XCTFail("Updater must not touch sessions or credentials: \(request.op)")
            throw AppError("test", "Forbidden fake operation")
        }
        switch request.op {
        case "validate": return HelperReply(allowPasswordSave: allowSave, username: "")
        case "connect":
            XCTAssertFalse(disconnecting, "Must finish cleanup before connecting again")
            let id = try XCTUnwrap(request.profileId), sessionID = try XCTUnwrap(request.sessionId)
            connections.append((id, request.password ?? ""))
            sessions.removeAll { $0.profileId == id }
            sessions.append(Session(profileId: id, sessionId: sessionID, status: .connecting))
        case "disconnect", "disconnect_all":
            if request.op == "disconnect" { disconnected.append(try XCTUnwrap(request.profileId)) }
            disconnecting = cleanupPolls > 0
            for i in sessions.indices where request.op == "disconnect_all" || sessions[i].profileId == request.profileId {
                sessions[i].status = disconnecting ? .disconnecting : .disconnected
            }
        default: throw AppError("test", "Unexpected request: \(request.op)")
        }
        return HelperReply(ok: true)
    }

    func keychain(_ operation: String, id: String, secret: String) throws -> KeychainReply {
        guard allowVPNOperations else {
            XCTFail("Updater must not use Keychain")
            throw AppError("test", "Forbidden fake operation")
        }
        calls.append("keychain:" + operation)
        switch operation {
        case "set": saved[id] = secret; saveCount += 1
        case "delete": saved.removeValue(forKey: id)
        case "get": return KeychainReply(found: saved[id] != nil, secret: saved[id])
        case "exists": return KeychainReply(found: saved[id] != nil)
        default: throw AppError("test", "Unexpected Keychain operation")
        }
        return KeychainReply(found: true)
    }
}
