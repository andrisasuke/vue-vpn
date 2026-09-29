import Foundation
import Observation

@MainActor @Observable
final class ProfileEditor {
    private(set) var profile: Profile
    var draft: ProfileUpdate
    var address = ""
    var subnet = "24"
    private(set) var validation = ""

    init(_ profile: Profile) { self.profile = profile; draft = ProfileUpdate(profile) }

    func addRoute() {
        do {
            let ip = try IPv4(address.trimmingCharacters(in: .whitespacesAndNewlines))
            let prefix = try VPNPolicy.maskPrefix(subnet.trimmingCharacters(in: .whitespacesAndNewlines))
            guard prefix > 0 else { throw AppError("invalid_route", "Use All IPv4 traffic for a default route.") }
            let route = try VPNPolicy.route(ip, prefix)
            if !draft.routes.contains(route) { draft.routes.append(route) }
            address = ""; validation = ""
        } catch { validation = error.localizedDescription }
    }

    func removeRoute(_ route: Route) { draft.routes.removeAll { $0 == route } }

    func validatedUpdate() -> ProfileUpdate? {
        validation = ""
        guard address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validation = "Add the pending route or clear its address before saving."
            return nil
        }
        var result = draft
        do {
            guard profile.authKind != .usernamePassword || !result.username.isEmpty else {
                throw AppError("invalid_username", "Enter a username for this profile.")
            }
            // Hidden DNS is copied from the original. A visible-field edit must
            // never erase existing internal DNS routing during this migration.
            result.dns = profile.dns
            try VPNPolicy.validate(&result)
            return result
        } catch { validation = error.localizedDescription; return nil }
    }
}
