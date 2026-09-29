import Foundation

struct HelperRefresh {
    var helper: HelperStatus
    var sessions: [Session]?
    var updated = false
}

/// Direct port of the bounded Rust updater. All timestamps come from an injected
/// monotonic clock, so timeout/retry tests never sleep or register a real daemon.
final class HelperUpdater {
    private let bridge: any VPNBridge
    private let clock: any VPNClock
    private var identityLoaded = false, expected: String?
    private var attempted = false, replacementStarted = false, replacementRetries = 0
    private var nextReplacement: TimeInterval?, repairRequested = false
    private var registrations = 0, nextRegistration: TimeInterval?, registrationMessage: String?
    private var started: TimeInterval?, verificationStarted: TimeInterval?
    private var verificationReconnected = false, waitingForStopCompletion = false
    private var failure: String?, wasAvailable = false, unavailableSince: TimeInterval?
    private var unavailableCount = 0, recoveryAttempted = false
    private let timeout: TimeInterval = 45
    private let interval: TimeInterval = 2

    init(bridge: any VPNBridge, clock: any VPNClock) { self.bridge = bridge; self.clock = clock }

    func retry() throws {
        let status = try bridge.service("reset_update")
        guard status.status != "updating" else {
            throw AppError("helper_updating", "The helper update is still finishing. Please wait.")
        }
        resetUpdate()
        repairRequested = true
        identityLoaded = false; expected = nil
        unavailableSince = nil; unavailableCount = 0; recoveryAttempted = false
    }

    private func resetUpdate() {
        attempted = false; replacementStarted = false; replacementRetries = 0; nextReplacement = nil
        repairRequested = false; registrations = 0; nextRegistration = nil; registrationMessage = nil
        started = nil; verificationStarted = nil; verificationReconnected = false
        waitingForStopCompletion = false; failure = nil
    }

    private func result(_ status: String, _ message: String, _ sessions: [Session]? = nil) -> HelperRefresh {
        HelperRefresh(helper: HelperStatus(status, message), sessions: sessions)
    }

    private func fail(_ message: String, _ sessions: [Session]? = nil) -> HelperRefresh {
        failure = message
        return result("update_failed", message, sessions)
    }

    private func bundled() throws -> Bool {
        if !identityLoaded { expected = try bridge.bundledHelperID(); identityLoaded = true }
        return expected != nil
    }

    private func verified(_ helper: HelperStatus, _ sessions: [Session]) -> HelperRefresh {
        let updated = attempted
        resetUpdate()
        wasAvailable = true; unavailableSince = nil; unavailableCount = 0
        // Keep recoveryAttempted latched until an explicit retry to prevent storms.
        return HelperRefresh(helper: helper, sessions: sessions, updated: updated)
    }

    private func verificationTimedOut(_ now: TimeInterval) -> Bool {
        if verificationStarted == nil { verificationStarted = now }
        return now - verificationStarted! >= timeout
    }

    private func registerMissing(_ service: HelperStatus, allowUpdate: Bool, now: TimeInterval) -> HelperRefresh {
        guard allowUpdate else { return HelperRefresh(helper: service) }
        do { guard try bundled() else { return HelperRefresh(helper: service) } }
        catch { return fail(error.localizedDescription) }
        attempted = true
        if registrations == 0 { started = now }
        if started == nil { started = now }
        if now - started! >= timeout {
            return fail("\(registrationMessage ?? "macOS did not register the VPN helper.") Registration did not finish in time. Retry the helper update.")
        }
        if let nextRegistration, now < nextRegistration {
            return result("updating", "Waiting for macOS to register the VPN helper…")
        }
        guard registrations < 3 else {
            return result("updating", "Waiting for macOS to finish registering the VPN helper…")
        }
        registrations += 1; nextRegistration = now + interval
        do {
            let helper = try bridge.service("register_update")
            registrationMessage = helper.message
            switch helper.status {
            case "requires_approval":
                started = nil; verificationStarted = nil; verificationReconnected = false
                return HelperRefresh(helper: helper)
            case "enabled", "registration_pending", "not_found", "not_registered":
                return result("updating", "Registering and verifying the VPN helper…")
            default: return fail(helper.message)
            }
        } catch { return fail(error.localizedDescription) }
    }

    func refresh(allowUpdate: Bool = true) throws -> HelperRefresh {
        let now = clock.monotonic
        let service = try bridge.service("status")
        if waitingForStopCompletion && service.status == "registration_pending" && allowUpdate {
            waitingForStopCompletion = false; failure = nil; started = now; registrations = 0; nextRegistration = nil
        }
        if let failure {
            if ["enabled", "update_failed", "update_retry_pending"].contains(service.status),
               let snapshot = try? bridge.request(HelperRequest(op: "snapshot")).snapshot() {
                let matching = (try? bundled()) == true && expected == snapshot.buildId
                let clean = !snapshot.sessions.contains { $0.errorCode == "cleanup_failed" }
                if matching && clean {
                    let status = service.status == "enabled" ? service : try bridge.service("reset_update")
                    if status.status == "enabled" { return verified(status, snapshot.sessions) }
                }
                return result("update_failed", failure, snapshot.sessions)
            }
            return result("update_failed", failure)
        }
        if service.status == "update_failed" { return fail(service.message) }
        if service.status == "update_retry_pending" {
            guard replacementStarted && replacementRetries < 2 else { return fail(service.message) }
            guard allowUpdate else { return result("updating", "Waiting to retry the VPN helper update…") }
            if nextReplacement == nil { nextReplacement = now + interval }
            if now < nextReplacement! {
                return result("updating", "macOS is busy. Retrying the VPN helper update automatically…")
            }
            let reset = try bridge.service("reset_update")
            if reset.status == "updating" { return HelperRefresh(helper: reset) }
            if ["requires_approval", "not_registered"].contains(reset.status) {
                attempted = false; replacementStarted = false
                return HelperRefresh(helper: reset)
            }
            replacementRetries += 1; nextReplacement = nil; started = now
            verificationStarted = nil; verificationReconnected = false
            do { return HelperRefresh(helper: try bridge.service("replace")) }
            catch { return fail(error.localizedDescription) }
        }
        if service.status == "updating" {
            if let started, now - started >= timeout {
                waitingForStopCompletion = replacementStarted
                return fail("The helper update took too long. Retry after macOS finishes stopping the previous helper.")
            }
            return HelperRefresh(helper: service)
        }
        if ["registration_pending", "not_found"].contains(service.status) ||
            (service.status == "not_registered" && (attempted || repairRequested)) {
            return registerMissing(service, allowUpdate: allowUpdate, now: now)
        }
        guard service.status == "enabled" else {
            if service.status == "requires_approval" {
                started = nil; verificationStarted = nil; verificationReconnected = false
            }
            return HelperRefresh(helper: service)
        }
        let response: HelperReply
        do { response = try bridge.request(HelperRequest(op: "snapshot")) }
        catch {
            if attempted {
                if !verificationTimedOut(now) { return result("updating", "Waiting for the updated VPN helper…") }
                return fail("The updated VPN helper did not respond. Retry the helper update.")
            }
            guard let appError = error as? AppError, ["helper_unavailable", "helper_timeout"].contains(appError.code) else {
                return result("unavailable", error.localizedDescription)
            }
            if !wasAvailable {
                do { guard try bundled() else { return result("unavailable", appError.message) } }
                catch { return fail(error.localizedDescription) }
            }
            if unavailableSince == nil { unavailableSince = now }
            unavailableCount = min(255, unavailableCount + 1)
            if repairRequested || (unavailableCount >= 3 && now - unavailableSince! >= 6) {
                guard allowUpdate else { return result("unavailable", appError.message) }
                guard !recoveryAttempted else {
                    return fail("The VPN helper is still unavailable after recovery. Use Repair helper to retry.")
                }
                do { guard try bundled() else { return result("unavailable", appError.message) } }
                catch { return fail(error.localizedDescription) }
                recoveryAttempted = true; attempted = true; replacementStarted = true; started = now
                verificationStarted = nil; verificationReconnected = false
                do { return HelperRefresh(helper: try bridge.service("replace")) }
                catch { return fail(error.localizedDescription) }
            }
            return wasAvailable ? result("recovering", "Reconnecting to the VPN helper…") :
                result("updating", "Checking the VPN helper after app startup…")
        }
        let snapshot = try response.snapshot()
        wasAvailable = true; unavailableSince = nil; unavailableCount = 0
        do { _ = try bundled() } catch { return fail(error.localizedDescription, snapshot.sessions) }
        if expected == nil || expected == snapshot.buildId { return verified(service, snapshot.sessions) }
        if replacementStarted {
            if verificationTimedOut(now) {
                return fail("The running helper still differs from this app after updating. Retry the helper update.", snapshot.sessions)
            }
            if !verificationReconnected && !snapshot.sessions.contains(where: \.active) {
                _ = try bridge.service("reconnect"); verificationReconnected = true
            }
            return result("updating", "Waiting for the new VPN helper to start and verify…", snapshot.sessions)
        }
        if snapshot.sessions.contains(where: \.active) || !allowUpdate {
            return result("update_pending", "A VPN helper update is ready. It will install automatically after all VPN connections are disconnected.", snapshot.sessions)
        }
        if snapshot.sessions.contains(where: { $0.errorCode == "cleanup_failed" }) {
            return fail("VPN network cleanup must finish before the helper can update. Restart macOS, then retry.", snapshot.sessions)
        }
        attempted = true; replacementStarted = true; registrations = 0; nextRegistration = nil
        started = now; verificationStarted = nil; verificationReconnected = false
        do { return HelperRefresh(helper: try bridge.service("replace"), sessions: snapshot.sessions) }
        catch { return fail(error.localizedDescription, snapshot.sessions) }
    }
}
