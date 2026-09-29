import Foundation
import XCTest

final class ProfileTests: XCTestCase {
    private let base = "client\ndev tun\nremote vpn.example.test 1194 udp\nauth-user-pass\n"

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vuevpn-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSubnetNormalizationAndBoundaries() throws {
        XCTAssertEqual(try VPNPolicy.route(IPv4("192.168.4.99"), 24).address.description, "192.168.4.0")
        XCTAssertEqual(try VPNPolicy.route(IPv4("255.255.255.255"), 0).address.bits, 0)
        XCTAssertThrowsError(try VPNPolicy.route(IPv4("1.2.3.4"), 33))
        for invalid in ["01.2.3.4", "1.2.3", "256.2.3.4", "1.2.3.4 ", "::1", "1.2.3.+4"] {
            XCTAssertThrowsError(try IPv4(invalid), invalid)
        }
    }

    func testMasksAreContiguous() throws {
        XCTAssertEqual(try VPNPolicy.maskPrefix("255.255.0.0"), 16)
        XCTAssertEqual(try VPNPolicy.maskPrefix("/32"), 32)
        XCTAssertEqual(try VPNPolicy.maskPrefix("0.0.0.0"), 0)
        for invalid in ["255.0.255.0", "33", "-1", "abc"] { XCTAssertThrowsError(try VPNPolicy.maskPrefix(invalid)) }
    }

    func testOverlappingAndAdjacentRoutes() throws {
        let a = try VPNPolicy.route(IPv4("10.1.0.0"), 16)
        XCTAssertTrue(try VPNPolicy.overlaps(a, VPNPolicy.route(IPv4("10.1.5.0"), 24)))
        XCTAssertFalse(try VPNPolicy.overlaps(a, VPNPolicy.route(IPv4("10.2.0.0"), 16)))
    }

    func testDomainLabelBoundaries() throws {
        XCTAssertEqual(try VPNPolicy.domain(" Dev.EXAMPLE.com. "), "dev.example.com")
        XCTAssertTrue(VPNPolicy.domainsOverlap("dev.example.com", "example.com"))
        XCTAssertFalse(VPNPolicy.domainsOverlap("notexample.com", "example.com"))
        for invalid in ["bad..com", "-bad.com", "bad-.com", "127.0.0.1", "é.com"] {
            XCTAssertThrowsError(try VPNPolicy.domain(invalid))
        }
    }

    func testUpdateNormalizesDeduplicatesAndPreservesHiddenDNS() throws {
        var update = ProfileUpdate(try ProfileParser.parse(base, fallbackName: "Test").profile)
        update.name = " Name "
        update.routes = [Route(address: try IPv4("10.2.3.4"), prefix: 16), Route(address: try IPv4("10.2.0.1"), prefix: 16)]
        update.dns = DNSSettings(servers: [try IPv4("10.1.0.1"), try IPv4("10.1.0.1")], domains: ["Dev.Example.", "dev.example"])
        try VPNPolicy.validate(&update)
        XCTAssertEqual(update.name, "Name")
        XCTAssertEqual(update.routes, [Route(address: try IPv4("10.2.0.0"), prefix: 16)])
        XCTAssertEqual(update.dns.domains, ["dev.example"])
        XCTAssertEqual(update.dns.servers.count, 1)
        for address in ["0.0.0.0", "127.0.0.1", "224.0.0.1", "255.255.255.255"] {
            update.dns.servers = [try IPv4(address)]
            XCTAssertThrowsError(try VPNPolicy.validate(&update))
        }
    }

    func testPolicyLimitsAndDefaultRoute() throws {
        var update = ProfileUpdate(try ProfileParser.parse(base, fallbackName: "Test").profile)
        update.name = String(repeating: "a", count: 81)
        XCTAssertThrowsError(try VPNPolicy.validate(&update))
        update.name = "Test"; update.username = "one\ntwo"
        XCTAssertThrowsError(try VPNPolicy.validate(&update))
        update.username = ""; update.routes = [Route(address: IPv4(bits: 0), prefix: 0)]
        XCTAssertThrowsError(try VPNPolicy.validate(&update))
        update.routes = Array(repeating: Route(address: IPv4(bits: 1), prefix: 32), count: 257)
        XCTAssertThrowsError(try VPNPolicy.validate(&update))
    }

    func testRoutingAndDNSConflictsAcrossProfiles() throws {
        var a = try ProfileParser.parse(base, fallbackName: "A").profile
        var b = try ProfileParser.parse(base, fallbackName: "B").profile
        XCTAssertThrowsError(try VPNPolicy.conflict(a, with: [b])) { XCTAssertEqual(($0 as? AppError)?.code, "full_tunnel_conflict") }
        a.routingMode = .selected; b.routingMode = .selected
        a.routes = [try VPNPolicy.route(IPv4("10.1.0.0"), 16)]
        b.routes = [try VPNPolicy.route(IPv4("10.2.0.0"), 16)]
        XCTAssertNoThrow(try VPNPolicy.conflict(a, with: [b]))
        b.routes = [try VPNPolicy.route(IPv4("10.1.5.0"), 24)]
        XCTAssertThrowsError(try VPNPolicy.conflict(a, with: [b])) { XCTAssertEqual(($0 as? AppError)?.code, "route_conflict") }
        b.routes = []; b.dns.servers = [try IPv4("10.1.0.1")]
        XCTAssertThrowsError(try VPNPolicy.conflict(a, with: [b]))
        b.dns.servers = []; a.dns.domains = ["example.test"]; b.dns.domains = ["dev.example.test"]
        XCTAssertThrowsError(try VPNPolicy.conflict(a, with: [b])) { XCTAssertEqual(($0 as? AppError)?.code, "dns_conflict") }
        XCTAssertNoThrow(try VPNPolicy.conflict(a, with: [a]))
    }

    func testSplitRoutesAndPINMetadata() throws {
        let text = "# {\n# \"password_mode\": \"pin\",\n# \"user\": \"demo\"\n# }\n" + base + "route-nopull\nroute 10.2.4.99 255.255.255.0\n<key>\nPRIVATE TEST DATA\n</key>\n"
        let imported = try ProfileParser.parse(text, fallbackName: "Test")
        XCTAssertEqual(imported.profile.authKind, .pin)
        XCTAssertEqual(imported.profile.username, "demo")
        XCTAssertEqual(imported.profile.routingMode, .selected)
        XCTAssertEqual(imported.profile.routes[0].address.description, "10.2.4.0")
        XCTAssertFalse(imported.content.contains("password_mode"))
        XCTAssertTrue(imported.content.contains("PRIVATE TEST DATA"))
    }

    func testDefaultsToFullTunnelWithoutExplicitSplit() throws {
        for suffix in ["", "route 10.1.0.0/16\n", "route-nopull\n", "route-nopull\nroute 10.1.0.0/16\nredirect-gateway def1\n", "route-nopull\nroute 0.0.0.0/0\n"] {
            XCTAssertEqual(try ProfileParser.parse(base + suffix, fallbackName: "Test").profile.routingMode, .all)
        }
    }

    func testRejectsExecutableAndUnsupportedDirectives() {
        for directive in ["up /tmp/script", "plugin /tmp/plugin", "dev tap", "auth-user-pass secrets.txt",
                          "script-security 2", "static-challenge OTP 0", "management 127.0.0.1 9000",
                          "--management-external-key", "remote ::1", "proto udp6", "<connection>", "http-proxy localhost 80"] {
            XCTAssertThrowsError(try ProfileParser.parse(base + directive + "\n", fallbackName: "Test"), directive)
        }
    }

    func testNeverImportsPritunlSyncSecrets() throws {
        let imported = try ProfileParser.parse("# {\"password_mode\":\"pin\",\"sync_secret\":\"test-secret\"}\n" + base, fallbackName: "Test")
        XCTAssertFalse(imported.content.contains("test-secret"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(imported.profile), as: UTF8.self).contains("test-secret"))
        for feature in ["device_auth", "dynamic_firewall", "sso_auth", "restrict_client", "push_auth"] {
            XCTAssertThrowsError(try ProfileParser.parse("# {\"\(feature)\":true}\n" + base, fallbackName: "Test"))
        }
    }

    func testInlineAndExternalValidation() throws {
        XCTAssertThrowsError(try ProfileParser.parse(base + "<key>\nunfinished", fallbackName: "Test"))
        let root = try temporary()
        try Data("TEST CERTIFICATE".utf8).write(to: root.appendingPathComponent("ca with space.crt"))
        let imported = try ProfileParser.parse(base + "ca 'ca with space.crt'\n", directory: root, fallbackName: "Test")
        XCTAssertTrue(imported.content.contains("<ca>\nTEST CERTIFICATE\n</ca>"))
        try Data("TEST TLS KEY".utf8).write(to: root.appendingPathComponent("tls.key"))
        let tls = try ProfileParser.parse(base + "tls-auth tls.key 1\n", directory: root, fallbackName: "Test")
        XCTAssertTrue(tls.content.contains("key-direction 1\n"))
        XCTAssertThrowsError(try ProfileParser.parse(base + "tls-auth tls.key 2", directory: root, fallbackName: "Test"))
        try Data("</ca>\nup /tmp/test".utf8).write(to: root.appendingPathComponent("bad.crt"))
        XCTAssertThrowsError(try ProfileParser.parse(base + "ca bad.crt", directory: root, fallbackName: "Test"))
    }

    func testBoundedRegularUTF8FilesAndNUL() throws {
        let root = try temporary(), file = root.appendingPathComponent("test.ovpn")
        XCTAssertThrowsError(try ProfileParser.readBounded(root))
        try Data([0xff]).write(to: file)
        XCTAssertThrowsError(try ProfileParser.read(file))
        try Data(repeating: 65, count: ProfileParser.maximumSize + 1).write(to: file)
        XCTAssertThrowsError(try ProfileParser.read(file))
        XCTAssertThrowsError(try ProfileParser.parse(base + "\0", fallbackName: "Test"))
        XCTAssertThrowsError(try ProfileParser.read(root.appendingPathComponent("test.txt")))
    }

    func testShellQuotingDoesNotExpandValues() throws {
        XCTAssertEqual(try ProfileParser.words(#"ca "a b.crt" # ignored"#), ["ca", "a b.crt"])
        XCTAssertEqual(try ProfileParser.words(#"ca a\ b.crt"#), ["ca", "a b.crt"])
        XCTAssertEqual(try ProfileParser.words(#"key '$(whoami)'"#), ["key", "$(whoami)"])
        XCTAssertEqual(try ProfileParser.words(#"key "a\qb""#), ["key", #"a\qb"#])
        XCTAssertEqual(try ProfileParser.words("remote ''"), ["remote", ""])
        XCTAssertThrowsError(try ProfileParser.words("ca 'unfinished"))
        XCTAssertThrowsError(try ProfileParser.words("ca trailing\\"))
    }

    func testNoCacheAndLegacyCompatibility() throws {
        let profile = try ProfileParser.parse(base + "auth-nocache\ncipher AES-256-CBC\n", fallbackName: "Test").profile
        XCTAssertFalse(profile.allowPasswordSave)
        XCTAssertTrue(profile.allowLegacyCipher)
        XCTAssertEqual(profile.warnings.count, 1)
    }

    func testStoreRejectsTraversalAndMismatchedIdentity() throws {
        let store = try ProfileStore(root: temporary())
        XCTAssertThrowsError(try store.content("../../secret"))
        XCTAssertThrowsError(try store.delete("../"))
        let profile = try ProfileParser.parse(base, fallbackName: "Demo").profile
        try store.save(profile, content: "config")
        let other = store.root.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.moveItem(at: store.directory(profile.id), to: other)
        XCTAssertThrowsError(try store.profiles())
    }

    func testProfilePersistsWithoutRememberedStateAndWithPrivatePermissions() throws {
        let store = try ProfileStore(root: temporary())
        var profile = try ProfileParser.parse(base, fallbackName: "Demo").profile
        profile.remembered = true
        try store.save(profile, content: "config")
        XCTAssertEqual(try store.profiles().count, 1)
        XCTAssertFalse(try store.profiles()[0].remembered)
        XCTAssertEqual(try store.content(profile.id), "config")
        let dir = try store.directory(profile.id)
        for path in [store.root, dir] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        for name in ["config.ovpn", "profile.json"] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        try store.delete(profile.id)
        XCTAssertTrue(try store.profiles().isEmpty)
    }

    func testOldProfileAndSessionWireCompatibility() throws {
        let json = #"{"id":"00000000-0000-4000-8000-000000000001","name":"Development","authKind":"username_password","username":"demo","routingMode":"selected","routes":[{"address":"10.7.0.0","prefix":16}],"dns":{"servers":[],"domains":[]},"protocol":"udp","server":"192.0.2.10","allowPasswordSave":true,"allowLegacyCipher":false,"warnings":[]}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertFalse(profile.remembered)
        XCTAssertEqual(profile.authKind, .usernamePassword)
        let oldSession = #"{"profileId":"test","sessionId":"session","status":"connecting"}"#
        var session = try JSONDecoder().decode(Session.self, from: Data(oldSession.utf8))
        XCTAssertEqual(session.bytesIn, 0)
        XCTAssertEqual(session.bytesOut, 0)
        XCTAssertTrue(session.active)
        session.bytesIn = UInt64.max
        XCTAssertEqual(try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session)).bytesIn, .max)
    }

    func testTrafficUnitsAndDuration() {
        for (bytes, value, unit): (UInt64, String, String) in [(0, "0", ""), (100, "100", "B"), (100_000, "100", "KB"), (1_500_000, "1.5", "MB"), (999_999, "1", "MB"), (10_000_000, "10", "MB"), (.max, "18.4", "EB")] {
            XCTAssertEqual(VPNFormat.bytes(bytes), ByteAmount(value: value, unit: unit))
        }
        XCTAssertEqual(VPNFormat.duration(since: nil, now: 100), "—")
        XCTAssertEqual(VPNFormat.duration(since: 100, now: 99), "00:00:00")
        XCTAssertEqual(VPNFormat.duration(since: 100, now: 3761), "01:01:01")
    }
}
