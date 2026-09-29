import XCTest

@MainActor
final class EditorTests: XCTestCase {
    private func profile() throws -> Profile {
        try ProfileParser.parse("client\nremote vpn.example.test\nauth-user-pass\n", fallbackName: "Development").profile
    }
    func testNormalizeDuplicateRoutesAndRetainMaskChoice() throws {
        let editor = ProfileEditor(try profile())
        editor.address = " 10.7.1.99 "; editor.subnet = " 255.255.0.0 "
        editor.addRoute()
        XCTAssertEqual(editor.draft.routes, [Route(address: try IPv4("10.7.0.0"),prefix:16)])
        XCTAssertEqual(editor.address, ""); XCTAssertEqual(editor.subnet, " 255.255.0.0 ")
        editor.address = "10.7.55.2"; editor.addRoute()
        XCTAssertEqual(editor.draft.routes.count, 1)
        editor.removeRoute(editor.draft.routes[0]); XCTAssertTrue(editor.draft.routes.isEmpty)
    }
    func testInvalidRouteKeepsInputAndNeverChangesDraft() throws {
        let editor = ProfileEditor(try profile())
        for (ip, mask) in [("10.7.0.0","255.0.255.0"),("::1","24"),("0.0.0.0","0")] {
            editor.address = ip; editor.subnet = mask; editor.addRoute()
            XCTAssertFalse(editor.validation.isEmpty)
            XCTAssertEqual(editor.address,ip); XCTAssertTrue(editor.draft.routes.isEmpty)
        }
    }
    func testPendingAddressCannotSilentlyDisappearOnSave() throws {
        let editor = ProfileEditor(try profile())
        editor.draft.username = "test"; editor.address = "10.7.0.1"
        XCTAssertNil(editor.validatedUpdate())
        XCTAssertEqual(editor.validation,"Add the pending route or clear its address before saving.")
        editor.address = "  "
        XCTAssertNotNil(editor.validatedUpdate())
    }
    func testSavingVisibleFieldsPreservesInternalDNSAndDoesNotMutateOriginal() throws {
        var profile = try profile()
        profile.dns = DNSSettings(servers:[try IPv4("10.7.0.53")],domains:["dev.example.test"])
        let editor = ProfileEditor(profile)
        editor.draft.name = " New name "; editor.draft.username = "test"; editor.draft.dns = DNSSettings()
        let update = try XCTUnwrap(editor.validatedUpdate())
        XCTAssertEqual(update.name,"New name"); XCTAssertEqual(update.dns,profile.dns)
        XCTAssertEqual(editor.profile,profile)
    }
    func testUsernameIsRequiredOnlyForUsernamePasswordProfile() throws {
        for kind in [AuthKind.pin,.usernamePassword,.certificate] {
            var profile = try profile(); profile.authKind = kind
            let editor = ProfileEditor(profile)
            XCTAssertEqual(editor.validatedUpdate() == nil,kind == .usernamePassword)
        }
    }
}
