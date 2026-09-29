import Foundation

enum VPNPolicy {
    static func route(_ address: IPv4, _ prefix: UInt8) throws -> Route {
        guard prefix <= 32 else { throw AppError("invalid_route", "IPv4 prefix must be between 0 and 32.") }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return Route(address: IPv4(bits: address.bits & mask), prefix: prefix)
    }

    static func maskPrefix(_ value: String) throws -> UInt8 {
        let digits = value.drop(while: { $0 == "/" })
        if !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }), let n = UInt8(digits), n <= 32 { return n }
        guard let mask = try? IPv4(value) else { throw AppError("invalid_route", "Invalid subnet mask.") }
        let n = (~mask.bits).leadingZeroBitCount
        guard mask.bits == (n == 0 ? 0 : UInt32.max << (32 - n)) else {
            throw AppError("invalid_route", "Subnet mask must be contiguous.")
        }
        return UInt8(n)
    }

    static func overlaps(_ a: Route, _ b: Route) -> Bool {
        let prefix = min(a.prefix, b.prefix)
        return (try? route(a.address, prefix)) == (try? route(b.address, prefix))
    }

    static func domain(_ value: String) throws -> String {
        let domain = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\.+$"#, with: "", options: .regularExpression).lowercased()
        guard !domain.isEmpty, domain.utf8.count <= 253, (try? IPv4(domain)) == nil,
              domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw AppError("invalid_dns", "Invalid internal domain: \(value)") }
        return domain
    }

    static func domainsOverlap(_ a: String, _ b: String) -> Bool {
        a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    static func validate(_ update: inout ProfileUpdate) throws {
        update.name = update.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !update.name.isEmpty, update.name.unicodeScalars.count <= 80,
              !update.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AppError("invalid_name", "Use a profile name between 1 and 80 characters.")
        }
        guard update.username.utf8.count <= 256, !update.username.contains(where: { "\n\r\0".contains($0) }) else {
            throw AppError("invalid_username", "Invalid username.")
        }
        guard update.routes.count <= 256, update.dns.servers.count <= 8, update.dns.domains.count <= 32 else {
            throw AppError("limit", "Too many routes or DNS entries.")
        }
        update.routes = try update.routes.map {
            let normalized = try route($0.address, $0.prefix)
            guard normalized.prefix != 0 else {
                throw AppError("invalid_route", "Use All IPv4 traffic for a default route.")
            }
            return normalized
        }
        update.routes = Set(update.routes).sorted {
            $0.address == $1.address ? $0.prefix < $1.prefix : $0.address < $1.address
        }
        update.dns.domains = try Set(update.dns.domains.map(domain)).sorted()
        update.dns.servers = Set(update.dns.servers).sorted()
        guard !update.dns.servers.contains(where: \.invalidDNSServer) else {
            throw AppError("invalid_dns", "DNS must be a reachable IPv4 server address.")
        }
    }

    static func conflict(_ candidate: Profile, with others: [Profile]) throws {
        for other in others where other.id != candidate.id {
            if candidate.routingMode == .all && other.routingMode == .all {
                throw AppError("full_tunnel_conflict", "\(other.name) already routes all IPv4 traffic. Disconnect it or use selected routes.")
            }
            for left in effectiveRoutes(candidate) {
                for right in effectiveRoutes(other) where overlaps(left, right) {
                    throw AppError("route_conflict", "\(left.address)/\(left.prefix) overlaps \(right.address)/\(right.prefix) in \(other.name).")
                }
            }
            for a in candidate.dns.domains {
                for b in other.dns.domains where domainsOverlap(a, b) {
                    throw AppError("dns_conflict", "DNS domain \(a) overlaps \(b) in \(other.name).")
                }
            }
        }
    }

    private static func effectiveRoutes(_ p: Profile) -> [Route] {
        (p.routingMode == .selected ? p.routes : []) + p.dns.servers.map { Route(address: $0, prefix: 32) }
    }
}

struct ByteAmount: Equatable {
    let value: String
    let unit: String
}

enum VPNFormat {
    static func bytes(_ bytes: UInt64) -> ByteAmount {
        guard bytes > 0 else { return ByteAmount(value: "0", unit: "") }
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var amount = Double(bytes), index = 0
        while amount >= 1000 && index < units.count - 1 { amount /= 1000; index += 1 }
        amount = (amount * 10).rounded() / 10
        if amount >= 1000 && index < units.count - 1 { amount /= 1000; index += 1 }
        let value = amount == amount.rounded() ? String(format: "%.0f", amount) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), amount)
        return ByteAmount(value: value, unit: units[index])
    }

    static func duration(since: UInt64?, now: UInt64) -> String {
        guard let since, since > 0 else { return "—" }
        let seconds = now >= since ? now - since : 0
        return [seconds / 3600, seconds / 60 % 60, seconds % 60].map {
            let value = String($0); return value.count < 2 ? "0" + value : value
        }.joined(separator: ":")
    }
}
