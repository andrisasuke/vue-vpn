import Foundation
import Darwin

/// Owns a mutable, non-copy-on-write buffer so retained credentials can be erased
/// when the session ends. Strings handed to a codec/bridge remain short-lived.
final class SessionSecret {
    private let pointer: UnsafeMutablePointer<CChar>
    private let count: Int
    var remember: Bool
    init(_ value: String, remember: Bool) {
        let bytes = value.utf8CString
        count = bytes.count; pointer = .allocate(capacity: count)
        self.remember = remember
        bytes.withUnsafeBufferPointer { pointer.initialize(from: $0.baseAddress!, count: count) }
    }
    deinit { memset_s(pointer, count, 0, count); pointer.deallocate() }
    func string() -> String { String(cString: pointer) }
}

/// State is confined to one worker queue by the app coordinator. Dependencies
/// are explicit: constructing/testing this type never implicitly reaches macOS.
final class VPNBackend {
    let store: ProfileStore
    private let bridge: any VPNBridge
    private let clock: any VPNClock
    private var updater: HelperUpdater
    private var credentials: [String: SessionSecret] = [:]
    private var disconnectStarted: [String: TimeInterval] = [:]
    private(set) var profiles: [Profile]
    private(set) var sessions: [Session] = []
    private(set) var logs: [LogEntry] = []
    private(set) var helper = HelperStatus("not_registered", "Enable the VPN helper to connect.")

    init(store: ProfileStore, bridge: any VPNBridge, clock: any VPNClock) throws {
        self.store = store; self.bridge = bridge; self.clock = clock
        updater = HelperUpdater(bridge: bridge, clock: clock)
        profiles = try store.profiles()
    }

    var snapshot: Snapshot { Snapshot(profiles: profiles, sessions: sessions, helper: helper, logs: logs) }

    func get(_ id: String) throws -> Profile {
        guard let p = profiles.first(where: { $0.id == id }) else { throw AppError("not_found", "Profile not found.") }
        return p
    }

    func active(_ id: String) -> Bool { sessions.contains { $0.profileId == id && $0.active } }

    private func log(_ id: String?, _ message: String) {
        logs.append(LogEntry(timestamp: clock.unixSeconds, profileId: id, message: message))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    func refreshCredentials() {
        for i in profiles.indices {
            profiles[i].remembered = (try? bridge.keychain("exists", id: profiles[i].id, secret: "").found) == true
        }
    }

    func refresh(allowUpdate: Bool = true) throws {
        let refreshed = try updater.refresh(allowUpdate: allowUpdate)
        if helper.status != refreshed.helper.status && ["updating", "update_pending", "update_failed"].contains(refreshed.helper.status) {
            log(nil, refreshed.helper.message)
        }
        helper = refreshed.helper
        if refreshed.updated { log(nil, "VPN helper updated successfully.") }
        guard let incoming = refreshed.sessions else {
            if ["updating", "recovering"].contains(helper.status) {
                for i in sessions.indices where sessions[i].active && sessions[i].status != .disconnecting {
                    sessions[i].status = .reconnecting
                }
                return
            }
            for i in sessions.indices where sessions[i].active {
                sessions[i].status = .error; sessions[i].error = helper.message; sessions[i].errorCode = "helper_unavailable"
            }
            credentials.removeAll()
            return
        }
        let monitored = monitorDisconnects(incoming)
        for session in monitored {
            guard let profileIndex = profiles.firstIndex(where: { $0.id == session.profileId }) else { continue }
            let previous = sessions.first { $0.profileId == session.profileId && $0.sessionId == session.sessionId }
            if previous?.status != session.status || previous?.errorCode != session.errorCode {
                let message: String
                switch session.status {
                case .connected: message = "Connected. Your VPN is ready."
                case .error: message = session.error ?? "Connection failed."
                case .disconnecting where session.disconnectStalled: message = session.error!
                default: message = "Connection status: \(session.status.rawValue)"
                }
                log(session.profileId, message)
            }
            if session.status == .connected, let credential = credentials[session.profileId], credential.remember {
                credential.remember = false
                do {
                    _ = try bridge.keychain("set", id: session.profileId, secret: credential.string())
                    profiles[profileIndex].remembered = true
                } catch { log(session.profileId, error.localizedDescription) }
            }
            if [.error, .disconnected].contains(session.status) {
                credentials.removeValue(forKey: session.profileId)
                if session.errorCode == "AUTH_FAILED" {
                    _ = try? bridge.keychain("delete", id: session.profileId, secret: "")
                    profiles[profileIndex].remembered = false
                }
            }
        }
        credentials = credentials.filter { id, _ in incoming.contains { $0.profileId == id && $0.active } }
        sessions = monitored.filter { session in profiles.contains { $0.id == session.profileId } }
    }

    private func monitorDisconnects(_ incoming: [Session]) -> [Session] {
        let pending = Set(incoming.filter { $0.status == .disconnecting }.map(\.sessionId))
        disconnectStarted = disconnectStarted.filter { pending.contains($0.key) }
        return incoming.map { value in
            var session = value
            guard session.status == .disconnecting else { return session }
            let started = disconnectStarted[session.sessionId] ?? clock.monotonic
            disconnectStarted[session.sessionId] = started
            if clock.monotonic - started >= 30 && session.errorCode != "disconnect_timeout" {
                // Keep ownership active: timeout does not prove that the tunnel
                // or routes have gone away, and must not permit helper replacement.
                let previous = session.error
                session.errorCode = "disconnect_timeout"
                session.error = "Disconnect has not finished after 30 seconds. Retry disconnect. The VPN may still be active until cleanup completes."
                if let previous, !previous.isEmpty { session.error! += " Previous error: \(previous)" }
            }
            return session
        }
    }

    func importProfile(_ path: URL) throws -> String {
        guard profiles.count < 32 else { throw AppError("limit", "You can import up to 32 profiles.") }
        var imported = try ProfileParser.read(path)
        if helper.status == "enabled" { try evaluate(&imported.profile, content: imported.content) }
        try store.save(imported.profile, content: imported.content)
        profiles.append(imported.profile)
        log(imported.profile.id, "Profile imported.")
        return imported.profile.id
    }

    private func evaluate(_ profile: inout Profile, content: String) throws {
        let value = try bridge.request(HelperRequest(op: "validate", profileId: profile.id, profile: profile, content: content))
        if value.allowPasswordSave == false { profile.allowPasswordSave = false }
        if let username = value.username, !username.isEmpty { profile.username = username }
    }

    func connect(_ id: String, password: String? = nil, remember: Bool = false) throws {
        try refresh()
        guard helper.status == "enabled" else { throw AppError("helper_setup", helper.message) }
        guard !active(id) else { throw AppError("already_connected", "This profile is already active.") }
        var profile = try get(id)
        try VPNPolicy.conflict(profile, with: profiles.filter { active($0.id) })
        let content = try store.content(id)
        try evaluate(&profile, content: content)
        try store.save(profile)
        replace(profile)
        let secret: String
        if profile.authKind == .certificate { secret = "" }
        else if let password { secret = password }
        else if let saved = try bridge.keychain("get", id: id, secret: "").secret { secret = saved }
        else { throw AppError("credentials_required", "Enter your PIN or password to connect.") }
        guard profile.authKind == .certificate || !secret.isEmpty else { throw AppError("credentials_required", "Enter your PIN or password.") }
        guard secret.utf8.count <= 4096 else { throw AppError("invalid_input", "Password is too long.") }
        guard !secret.contains("\0") else { throw AppError("invalid_input", "Input contains a null character.") }
        guard profile.authKind != .usernamePassword || !profile.username.isEmpty else {
            throw AppError("username_required", "Set the username in profile settings.")
        }
        let sessionID = UUID().uuidString.lowercased()
        _ = try bridge.request(HelperRequest(op: "connect", profileId: id, sessionId: sessionID,
            profile: profile, content: content, username: profile.username, password: secret))
        credentials[id] = SessionSecret(secret, remember: remember && profile.allowPasswordSave)
        sessions.removeAll { $0.profileId == id }
        sessions.append(Session(profileId: id, sessionId: sessionID, status: .connecting))
    }

    private func checkCleanup(_ sessions: [Session]) throws {
        guard !sessions.contains(where: { $0.errorCode == "cleanup_failed" }) else {
            throw AppError("cleanup_failed", "VPN network cleanup has not finished. Retry Connect or Disconnect to resume cleanup.")
        }
    }

    func disconnect(_ id: String) throws {
        _ = try get(id)
        _ = try bridge.request(HelperRequest(op: "disconnect", profileId: id))
        if let session = sessions.first(where: { $0.profileId == id }) {
            disconnectStarted[session.sessionId] = clock.monotonic
        }
        credentials.removeValue(forKey: id)
        try refresh()
        try checkCleanup(sessions.filter { $0.profileId == id })
    }

    private func waitForDisconnect(_ id: String? = nil) throws {
        let deadline = clock.monotonic + 30
        while true {
            let snapshot = try bridge.request(HelperRequest(op: "snapshot")).snapshot()
            let relevant = snapshot.sessions.filter { id == nil || $0.profileId == id }
            try checkCleanup(relevant)
            if !relevant.contains(where: \.active) { return }
            guard clock.monotonic < deadline else {
                throw AppError("cleanup_pending", "VPN cleanup is still running. Wait for Disconnected, then retry this action.")
            }
            clock.sleep(0.25)
        }
    }

    func disconnectAll() throws {
        guard helper.status != "updating" else {
            throw AppError("helper_updating", "Wait for the VPN helper update to finish before quitting or disabling it.")
        }
        if sessions.contains(where: \.active) || ["enabled", "update_pending"].contains(helper.status) {
            _ = try bridge.request(HelperRequest(op: "disconnect_all"))
            try waitForDisconnect()
        }
        credentials.removeAll()
        try refresh(allowUpdate: false)
        try checkCleanup(sessions)
    }

    private func replace(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
    }

    func update(_ id: String, _ proposed: ProfileUpdate) throws {
        var update = proposed
        try VPNPolicy.validate(&update)
        let old = try get(id)
        var profile = old
        profile.name = update.name; profile.username = update.username; profile.routingMode = update.routingMode
        profile.routes = update.routes; profile.dns = update.dns; profile.allowLegacyCipher = update.allowLegacyCipher
        let reconnect = active(id) && (old.username != profile.username || old.routingMode != profile.routingMode ||
            old.routes != profile.routes || old.dns != profile.dns || old.allowLegacyCipher != profile.allowLegacyCipher)
        if reconnect { try VPNPolicy.conflict(profile, with: profiles.filter { $0.id != id && active($0.id) }) }
        // Retain the session-only buffer while disconnect removes it from the map.
        let credential = reconnect ? credentials[id] : nil
        if reconnect { try disconnect(id); try waitForDisconnect(id) }
        try store.save(profile)
        replace(profile)
        if reconnect { try connect(id, password: credential?.string(), remember: credential?.remember ?? false) }
    }

    func forget(_ id: String) throws {
        var profile = try get(id)
        _ = try bridge.keychain("delete", id: id, secret: "")
        credentials[id]?.remember = false
        profile.remembered = false; replace(profile)
    }

    func delete(_ id: String) throws {
        _ = try get(id)
        if active(id) { try disconnect(id); try waitForDisconnect(id) }
        try forget(id)
        try store.delete(id)
        profiles.removeAll { $0.id == id }; sessions.removeAll { $0.profileId == id }
        credentials.removeValue(forKey: id)
    }

    @discardableResult
    func helperAction(_ operation: String) throws -> HelperStatus {
        guard ["status", "register", "settings", "unregister", "retry_update"].contains(operation) else {
            throw AppError("invalid_input", "Unknown helper action.")
        }
        if operation == "retry_update" || (operation == "register" && helper.status == "unavailable") {
            try updater.retry(); try refresh(); return helper
        }
        if operation == "unregister" { try disconnectAll() }
        helper = try bridge.service(operation)
        if ["register", "unregister"].contains(operation) && helper.status != "updating" {
            updater = HelperUpdater(bridge: bridge, clock: clock)
        }
        if operation == "status" { try refresh() }
        return helper
    }
}
