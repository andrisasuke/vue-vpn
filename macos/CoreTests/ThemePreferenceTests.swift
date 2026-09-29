import XCTest

@MainActor final class ThemePreferenceTests:XCTestCase {
    private final class Store:ThemePreferenceStore {
        var value:String?
        var writes:[String] = []
        init(_ value:String? = nil) { self.value = value }
        func read() -> String? { value }
        func write(_ value:String) { self.value = value;writes.append(value) }
    }

    func testMissingAndUnknownValuesDefaultToSystemWithoutWriting() {
        for raw in [nil,"","obsolete","DARK"] as [String?] {
            let store = Store(raw)
            let settings = ThemeSettings(store:store)
            XCTAssertEqual(settings.preference,.system)
            XCTAssertTrue(store.writes.isEmpty)
        }
    }

    func testChoicePersistsAndRestoresAcrossInstances() {
        let store = Store(),settings = ThemeSettings(store:store)
        for choice in [ThemePreference.dark,.light,.system] {
            settings.select(choice)
            XCTAssertEqual(ThemeSettings(store:store).preference,choice)
        }
        XCTAssertEqual(store.writes,["dark","light","system"])
    }

    func testReselectingCurrentChoiceDoesNotWrite() {
        let store = Store("dark"),settings = ThemeSettings(store:store)
        settings.select(.dark)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testOnlySystemFollowsOperatingSystemChanges() {
        for system in [ResolvedTheme.light,.dark,.light] {
            XCTAssertEqual(ThemePreference.light.resolved(system:system),.light)
            XCTAssertEqual(ThemePreference.dark.resolved(system:system),.dark)
            XCTAssertEqual(ThemePreference.system.resolved(system:system),system)
        }
    }
}
