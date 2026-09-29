import Foundation
import Darwin

struct ImportedProfile {
    var profile: Profile
    var content: String
}

enum ProfileParser {
    static let maximumSize = 8 * 1024 * 1024
    private static let forbidden: Set<String> = [
        "up", "down", "route-up", "route-pre-down", "ipchange", "tls-verify", "tls-crypt-v2-verify",
        "auth-user-pass-verify", "client-connect", "client-disconnect", "learn-address", "plugin",
        "config", "cd", "chroot", "daemon", "writepid", "log", "log-append", "status", "management",
        "management-client", "management-query-passwords", "askpass", "pkcs11-providers",
        "cryptoapicert", "pkcs12", "engine", "iproute", "tls-export-cert", "auth-gen-token-secret",
        "http-proxy", "socks-proxy",
    ]
    private static let fileDirectives: Set<String> = ["ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2"]
    private static let blocks = fileDirectives.union(["peer-fingerprint"])

    private static func invalid(_ message: String) -> AppError { AppError("invalid_profile", message) }

    static func read(_ url: URL) throws -> ImportedProfile {
        guard url.pathExtension.lowercased() == "ovpn" else { throw invalid("Choose a .ovpn file.") }
        return try parse(readBounded(url), directory: url.deletingLastPathComponent(),
                         fallbackName: url.deletingPathExtension().lastPathComponent)
    }

    static func readBounded(_ url: URL) throws -> String {
        // O_NONBLOCK prevents a named pipe from hanging before fstat rejects it.
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw AppError("storage", String(cString: strerror(errno))) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw AppError("storage", String(cString: strerror(errno))) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw invalid("Profile references must be regular files.") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= maximumSize {
            let capacity = min(buffer.count, maximumSize + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, capacity) }
            if count < 0 {
                if errno == EINTR { continue }
                throw AppError("storage", String(cString: strerror(errno)))
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumSize else { throw invalid("Profile or certificate exceeds the 8 MiB limit.") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw invalid("Profile and certificate files must be UTF-8 text.")
        }
        return text
    }

    /// POSIX shell-word quoting only; never performs shell expansion or execution.
    static func words(_ line: String) throws -> [String] {
        let scalars = Array(line.unicodeScalars)
        var words: [String] = [], word = "", quoted: Unicode.Scalar?, begun = false, i = 0
        while i < scalars.count {
            let c = scalars[i]
            if let quote = quoted {
                if c == quote { quoted = nil }
                else if c == "\\" && quote == "\"" {
                    i += 1
                    guard i < scalars.count else { throw invalid("Invalid quoting in profile.") }
                    let next = scalars[i]
                    if next != "\n" {
                        if !["$", "`", "\"", "\\"].contains(next) { word.unicodeScalars.append("\\") }
                        word.unicodeScalars.append(next)
                    }
                } else { word.unicodeScalars.append(c) }
            } else if c == "'" || c == "\"" { quoted = c; begun = true }
            else if c == "\\" {
                i += 1
                guard i < scalars.count else { throw invalid("Invalid quoting in profile.") }
                if scalars[i] != "\n" { word.unicodeScalars.append(scalars[i]); begun = true }
            } else if c == " " || c == "\t" || c == "\n" {
                if begun { words.append(word); word = ""; begun = false }
            } else if c == "#" && !begun { break }
            else { word.unicodeScalars.append(c); begun = true }
            i += 1
        }
        guard quoted == nil else { throw invalid("Invalid quoting in profile.") }
        if begun { words.append(word) }
        return words
    }

    static func parse(_ content: String, directory: URL? = nil, fallbackName: String) throws -> ImportedProfile {
        guard content.utf8.count <= maximumSize, !content.contains("\0") else { throw invalid("Invalid or oversized profile.") }
        var output = "", metadata = "", inline: String?
        var auth = false, client = false, hasRemote = false, noPull = false, redirected = false
        var routes: [Route] = [], dns = DNSSettings(), transport = "udp", server = ""
        var save = true, legacy = false, warnings: [String] = []

        func append(_ text: String) throws {
            output += text
            guard output.utf8.count <= maximumSize else { throw invalid("Combined profile exceeds 8 MiB.") }
        }

        for rawPart in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = rawPart.hasSuffix("\r") ? String(rawPart.dropLast()) : String(rawPart)
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tag = inline {
                try append(raw + "\n")
                if line == "</\(tag)>" { inline = nil }
                continue
            }
            if line.hasPrefix("#") {
                metadata += line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                continue
            }
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("<") {
                let tag = String(line.drop(while: { $0 == "<" }).reversed().drop(while: { $0 == ">" }).reversed())
                guard blocks.contains(tag) else { throw invalid("Unsupported inline section: \(tag)") }
                inline = tag; try append(line + "\n"); continue
            }
            let args = try words(line)
            guard var key = args.first else { continue }
            while key.hasPrefix("--") { key.removeFirst(2) }
            let value = args.count > 1 ? args[1] : nil
            guard !forbidden.contains(key), !key.hasPrefix("management-") else {
                throw invalid("Unsupported or unsafe directive: \(key)")
            }
            if key == "script-security" {
                if let value, value != "0" && value != "1" { throw invalid("External profile scripts are not supported.") }
                continue
            }
            if ["dev", "dev-type"].contains(key), value?.hasPrefix("tap") == true {
                throw invalid("TAP profiles are not supported. Use a TUN profile.")
            }
            if ["remote", "proto"].contains(key), args.contains(where: { $0.hasPrefix("udp6") || $0.hasPrefix("tcp6") }) {
                throw invalid("IPv6 transport is not supported in this version.")
            }
            if key == "remote" {
                guard let remote = value else { throw invalid("Missing VPN server address.") }
                guard !remote.contains(":") else { throw invalid("Use an IPv4 VPN endpoint.") }
                hasRemote = true
                if server.isEmpty { server = remote }
                if args.count > 3 { transport = args[3] }
            }
            if key == "proto", let value { transport = value }
            if key == "client" { client = true }
            if key == "auth-user-pass" {
                guard args.count == 1 else {
                    throw invalid("Credential files are not imported. Remove the auth-user-pass filename and enter credentials in VueVPN.")
                }
                auth = true
            }
            if key == "auth-nocache" { save = false }
            if key == "static-challenge" { throw invalid("One-time challenge authentication is not supported in this version.") }
            if key == "route-nopull" { noPull = true }
            if key == "redirect-gateway" { redirected = true }
            if key == "route" {
                guard let value else { throw invalid("Route is missing a destination.") }
                let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                let address = String(parts[0])
                let subnet = parts.count == 2 ? String(parts[1]) : (args.count > 2 ? args[2] : "/32")
                let prefix = try VPNPolicy.maskPrefix(subnet)
                guard let ip = try? IPv4(address) else { throw invalid("Routes must use explicit IPv4 addresses.") }
                let route = try VPNPolicy.route(ip, prefix)
                if prefix == 0 { redirected = true } else { routes.append(route) }
            }
            if key == "dhcp-option", args.count > 2 {
                switch args[1] {
                case "DNS":
                    guard let ip = try? IPv4(args[2]) else { throw invalid("DNS must be an IPv4 address.") }
                    dns.servers.append(ip)
                case "DOMAIN", "DOMAIN-SEARCH", "DOMAIN-ROUTE": dns.domains.append(try VPNPolicy.domain(args[2]))
                default: break
                }
            }
            if key == "cipher", value?.hasSuffix("-CBC") == true { legacy = true }
            if fileDirectives.contains(key) {
                guard let value else { throw invalid("Missing file for \(key)") }
                if value == "[inline]" { continue }
                guard let directory else { throw invalid("External files cannot be resolved.") }
                let path = (value as NSString).isAbsolutePath ? URL(fileURLWithPath: value) : directory.appendingPathComponent(value)
                let text = try readBounded(path)
                guard !text.contains("</\(key)>"), !text.contains("\0") else { throw invalid("Invalid certificate content.") }
                try append("<\(key)>\n\(text)\n</\(key)>\n")
                if key == "tls-auth", args.count > 2 {
                    guard ["0", "1"].contains(args[2]) else { throw invalid("Invalid key direction.") }
                    try append("key-direction \(args[2])\n")
                }
                continue
            }
            try append(line + "\n")
        }
        guard inline == nil else { throw invalid("Unclosed certificate/key section.") }
        guard client && hasRemote else { throw invalid("Profile must have client and remote directives.") }
        var meta: [String: Any] = [:]
        if let start = metadata.firstIndex(of: "{"), let end = metadata.lastIndex(of: "}"), start <= end {
            meta = (try? JSONSerialization.jsonObject(with: Data(metadata[start...end].utf8))) as? [String: Any] ?? [:]
        }
        for feature in ["device_auth", "dynamic_firewall", "sso_auth", "restrict_client", "push_auth"] {
            if let flag = meta[feature] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue {
                throw invalid("Pritunl \(feature) requires capabilities not supported by VueVPN.")
            }
        }
        if legacy { warnings.append("Profile includes an AES-CBC fallback. Compatibility is enabled only for this profile; certificate verification stays enabled.") }
        if !noPull && !routes.isEmpty {
            warnings.append("Imported routes are preserved. All IPv4 is selected because the source profile also accepts server routing.")
        }
        var update = ProfileUpdate(name: meta["server"] as? String ?? fallbackName,
                                   username: meta["user"] as? String ?? "",
                                   routingMode: noPull && !routes.isEmpty && !redirected ? .selected : .all,
                                   routes: routes, dns: dns, allowLegacyCipher: legacy)
        try VPNPolicy.validate(&update)
        return ImportedProfile(profile: Profile(name: update.name,
            authKind: meta["password_mode"] as? String == "pin" ? .pin : (auth ? .usernamePassword : .certificate),
            username: update.username, routingMode: update.routingMode, routes: update.routes, dns: update.dns,
            protocol: transport, server: server, allowPasswordSave: save, allowLegacyCipher: legacy, warnings: warnings), content: output)
    }
}
