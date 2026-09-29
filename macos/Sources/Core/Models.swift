import Foundation

enum RoutingMode: String, Codable, Sendable { case all, selected }
enum AuthKind: String, Codable, Sendable {
    case pin, usernamePassword = "username_password", certificate
}

/// The on-disk and XPC representation remains a dotted IPv4 string.
struct IPv4: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let bits: UInt32

    init(bits: UInt32) { self.bits = bits }

    init(_ text: String) throws {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { throw AppError("invalid_route", "Enter a valid IPv4 address.") }
        var bits: UInt32 = 0
        for octet in octets {
            guard !octet.isEmpty, octet.utf8.allSatisfy({ (48...57).contains($0) }),
                  octet.count == 1 || octet.first != "0", let value = UInt8(octet) else {
                throw AppError("invalid_route", "Enter a valid IPv4 address.")
            }
            bits = (bits << 8) | UInt32(value)
        }
        self.bits = bits
    }

    var description: String { [24, 16, 8, 0].map { String((bits >> $0) & 255) }.joined(separator: ".") }
    var invalidDNSServer: Bool { bits == 0 || bits == .max || bits >> 24 == 127 || bits >> 28 == 14 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.bits < rhs.bits }
    init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

struct Route: Codable, Hashable, Sendable {
    var address: IPv4
    var prefix: UInt8
}

struct DNSSettings: Codable, Equatable, Sendable {
    var servers: [IPv4] = []
    var domains: [String] = []
}

struct Profile: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var authKind: AuthKind
    var username: String
    var routingMode: RoutingMode
    var routes: [Route]
    var dns: DNSSettings
    var `protocol`: String
    var server: String
    var allowPasswordSave: Bool
    var allowLegacyCipher: Bool
    var warnings: [String]
    var remembered: Bool = false

    // Older profile files predate the ephemeral remembered property.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        authKind = try c.decode(AuthKind.self, forKey: .authKind)
        username = try c.decode(String.self, forKey: .username)
        routingMode = try c.decode(RoutingMode.self, forKey: .routingMode)
        routes = try c.decode([Route].self, forKey: .routes)
        dns = try c.decode(DNSSettings.self, forKey: .dns)
        `protocol` = try c.decode(String.self, forKey: .protocol)
        server = try c.decode(String.self, forKey: .server)
        allowPasswordSave = try c.decode(Bool.self, forKey: .allowPasswordSave)
        allowLegacyCipher = try c.decode(Bool.self, forKey: .allowLegacyCipher)
        warnings = try c.decode([String].self, forKey: .warnings)
        remembered = try c.decodeIfPresent(Bool.self, forKey: .remembered) ?? false
    }

    init(id: String = UUID().uuidString.lowercased(), name: String, authKind: AuthKind,
         username: String, routingMode: RoutingMode, routes: [Route], dns: DNSSettings,
         protocol: String, server: String, allowPasswordSave: Bool, allowLegacyCipher: Bool,
         warnings: [String], remembered: Bool = false) {
        self.id = id; self.name = name; self.authKind = authKind; self.username = username
        self.routingMode = routingMode; self.routes = routes; self.dns = dns
        self.protocol = `protocol`; self.server = server; self.allowPasswordSave = allowPasswordSave
        self.allowLegacyCipher = allowLegacyCipher; self.warnings = warnings; self.remembered = remembered
    }
}

struct ProfileUpdate: Codable, Equatable, Sendable {
    var name: String
    var username: String
    var routingMode: RoutingMode
    var routes: [Route]
    var dns: DNSSettings
    var allowLegacyCipher: Bool

    init(_ profile: Profile) {
        name = profile.name; username = profile.username; routingMode = profile.routingMode
        routes = profile.routes; dns = profile.dns; allowLegacyCipher = profile.allowLegacyCipher
    }

    init(name: String, username: String, routingMode: RoutingMode, routes: [Route],
         dns: DNSSettings, allowLegacyCipher: Bool) {
        self.name = name; self.username = username; self.routingMode = routingMode
        self.routes = routes; self.dns = dns; self.allowLegacyCipher = allowLegacyCipher
    }
}

enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case disconnected, awaitingCredentials = "awaiting_credentials", connecting, connected
    case reconnecting, disconnecting, error

    var active: Bool { [.connecting, .connected, .reconnecting, .disconnecting].contains(self) }
    var label: String {
        switch self {
        case .disconnected: "Ready to connect"
        case .awaitingCredentials: "PIN required"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .disconnecting: "Disconnecting…"
        case .error: "Connection failed"
        }
    }
}

struct Session: Codable, Equatable, Sendable {
    var profileId: String
    var sessionId: String
    var status: SessionStatus
    var address: String = ""
    var interface: String = ""
    var connectedAt: UInt64?
    var attempts: UInt32 = 0
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var error: String?
    var errorCode: String?
    var effectiveRoutes: [Route] = []
    var effectiveDns = DNSSettings()
    var active: Bool { status.active }
    var disconnectStalled: Bool { status == .disconnecting && errorCode == "disconnect_timeout" }

    init(profileId: String, sessionId: String, status: SessionStatus) {
        self.profileId = profileId; self.sessionId = sessionId; self.status = status
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decode(String.self, forKey: .profileId)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        status = try c.decode(SessionStatus.self, forKey: .status)
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        interface = try c.decodeIfPresent(String.self, forKey: .interface) ?? ""
        connectedAt = try c.decodeIfPresent(UInt64.self, forKey: .connectedAt)
        attempts = try c.decodeIfPresent(UInt32.self, forKey: .attempts) ?? 0
        bytesIn = try c.decodeIfPresent(UInt64.self, forKey: .bytesIn) ?? 0
        bytesOut = try c.decodeIfPresent(UInt64.self, forKey: .bytesOut) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        effectiveRoutes = try c.decodeIfPresent([Route].self, forKey: .effectiveRoutes) ?? []
        effectiveDns = try c.decodeIfPresent(DNSSettings.self, forKey: .effectiveDns) ?? DNSSettings()
    }
}

struct HelperStatus: Codable, Equatable, Sendable {
    var status: String
    var message: String
    init(_ status: String, _ message: String) { self.status = status; self.message = message }
}
struct LogEntry: Codable, Equatable, Sendable {
    var timestamp: UInt64
    var profileId: String?
    var message: String
}
struct Snapshot: Codable, Equatable, Sendable {
    var profiles: [Profile]
    var sessions: [Session]
    var helper: HelperStatus
    var logs: [LogEntry]
}
struct AppError: Error, LocalizedError, Codable, Equatable, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}
