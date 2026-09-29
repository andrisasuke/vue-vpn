import Foundation

/// Version 1 wire contract shared with the existing Objective-C++ helper.
struct HelperRequest: Encodable {
    let version = 1
    var op: String
    var profileId: String?
    var sessionId: String?
    var profile: Profile?
    var content: String?
    var username: String?
    var password: String?
}

struct HelperReply: Decodable {
    var buildId: String?
    var sessions: [Session]?
    var allowPasswordSave: Bool?
    var username: String?
    var ok: Bool?

    func snapshot() throws -> HelperSnapshot {
        guard let sessions else { throw AppError("data", "Helper snapshot is missing sessions.") }
        return HelperSnapshot(buildId: buildId, sessions: sessions)
    }
}

struct HelperSnapshot {
    var buildId: String?
    var sessions: [Session]
}

struct KeychainReply: Decodable {
    var found: Bool?
    var secret: String?
}

/// Synchronous calls must be confined to the backend worker, never the main queue.
/// The hostless test target has no implementation that can reach XPC or Keychain.
protocol VPNBridge: AnyObject {
    func request(_ request: HelperRequest) throws -> HelperReply
    func service(_ operation: String) throws -> HelperStatus
    func bundledHelperID() throws -> String?
    func keychain(_ operation: String, id: String, secret: String) throws -> KeychainReply
}

protocol VPNClock: AnyObject {
    var monotonic: TimeInterval { get }
    var unixSeconds: UInt64 { get }
    func sleep(_ seconds: TimeInterval)
}

final class SystemVPNClock: VPNClock {
    var monotonic: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var unixSeconds: UInt64 { UInt64(max(0, Date().timeIntervalSince1970)) }
    func sleep(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}
