import Foundation
import Observation

enum WorkspaceScreen: String, Sendable { case overview, activity, setup }
enum WorkspaceModal: Equatable { case credentials(String), settings(String), delete(String) }

@MainActor @Observable
final class WorkspaceModel {
    private let backend: any BackendExecuting
    private(set) var state = Snapshot(profiles: [], sessions: [],
        helper: HelperStatus("loading", "Checking VPN helper…"), logs: [])
    var selectedID = ""
    var screen = WorkspaceScreen.overview
    private(set) var modal: WorkspaceModal?
    private(set) var busy = false
    private(set) var loaded = false
    private(set) var quitting = false
    private(set) var connectingID: String?
    private(set) var disconnectingID: String?
    var error = ""
    var modalError = ""
    private(set) var toast = ""
    var clock = UInt64(Date().timeIntervalSince1970)
    var password = ""
    var rememberPassword = false
    var passwordVisible = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(backend: any BackendExecuting) { self.backend = backend }

    var selected: Profile? { state.profiles.first { $0.id == selectedID } }
    var session: Session? { state.sessions.first { $0.profileId == selectedID } }
    var connectedCount: Int { state.sessions.filter { $0.status == .connected }.count }
    var activeCount: Int { state.sessions.filter(\.active).count }
    var isConnecting: Bool { connectingID == selectedID || session?.status == .connecting }
    var isDisconnecting: Bool { disconnectingID == selectedID || session?.status == .disconnecting }
    var connectionButtonDisabled: Bool { busy || quitting || isConnecting || (isDisconnecting && session?.disconnectStalled != true) }
    var connectionButtonLabel: String {
        if isConnecting { return "Connecting…" }
        if session?.disconnectStalled == true && disconnectingID != selectedID { return "Retry disconnect" }
        if isDisconnecting { return "Disconnecting…" }
        return session?.active == true ? "Disconnect" : "Connect to VPN"
    }
    var statusLabel: String {
        if session?.disconnectStalled == true { return "Disconnect stalled" }
        return (isConnecting ? SessionStatus.connecting : isDisconnecting ? .disconnecting : session?.status ?? .disconnected).label
    }
    var trafficIn: ByteAmount { VPNFormat.bytes(session?.active == true ? session?.bytesIn ?? 0 : 0) }
    var trafficOut: ByteAmount { VPNFormat.bytes(session?.active == true ? session?.bytesOut ?? 0 : 0) }
    var trafficLabel: String {
        "Received \(trafficIn.value)\(trafficIn.unit.isEmpty ? " B" : trafficIn.unit) / Sent \(trafficOut.value)\(trafficOut.unit.isEmpty ? " B" : trafficOut.unit)"
    }
    var modalProfile: Profile? {
        guard let modal else { return nil }
        let id: String
        switch modal { case .credentials(let value), .settings(let value), .delete(let value): id = value }
        return state.profiles.first { $0.id == id }
    }

    func accept(_ snapshot: Snapshot) {
        state = snapshot
        if !state.profiles.contains(where: { $0.id == selectedID }) { selectedID = state.profiles.first?.id ?? "" }
        loaded = true
    }

    func openModal(_ modal: WorkspaceModal) {
        guard !busy else { return }
        self.modal = modal; modalError = ""; password = ""; passwordVisible = false; rememberPassword = false
    }

    func closeModal() {
        guard !busy else { return }
        modal = nil; modalError = ""; password = ""; passwordVisible = false; rememberPassword = false
    }

    func refresh(credentials: Bool = false) async {
        guard !busy && !quitting else { return }
        let result = await backend.execute(.refresh(credentials: credentials))
        if let snapshot = result.snapshot { accept(snapshot) }
        if let failure = result.failure { error = failure.message }
        loaded = true
    }

    /// Called by app lifecycle only; constructing the model never starts work.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.refresh(credentials: true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.clock = UInt64(Date().timeIntervalSince1970)
                await self.refresh()
            }
        }
    }
    func stopPolling() { pollTask?.cancel(); pollTask = nil; toastTask?.cancel(); toastTask = nil }

    private func notify(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(4500)) } catch { return }
            self?.toast = ""
        }
    }

    private func perform(_ command: BackendCommand, inModal: Bool = false) async -> BackendResult? {
        guard !busy && !quitting else { return nil }
        busy = true; error = ""; modalError = ""
        defer { busy = false }
        let result = await backend.execute(command)
        if let snapshot = result.snapshot { accept(snapshot) }
        if let failure = result.failure {
            if inModal { modalError = failure.message } else { error = failure.message }
        }
        return result
    }

    func toggle() async {
        guard let selected, !connectionButtonDisabled else { return }
        if session?.active == true { await disconnect(selected.id) }
        else { await connect(selected) }
    }

    func connect(_ profile: Profile) async {
        guard !busy && !quitting else { return }
        error = ""
        guard state.helper.status == "enabled" else { screen = .setup; return }
        if profile.authKind != .certificate && !profile.remembered { openModal(.credentials(profile.id)); return }
        connectingID = profile.id
        defer { connectingID = nil }
        let result = await perform(.connect(id: profile.id, password: nil, remember: false))
        if let failure = result?.failure, ["credentials_required", "keychain"].contains(failure.code) {
            error = ""; openModal(.credentials(profile.id))
        }
    }

    func submitCredentials() async {
        guard case .credentials(let id) = modal, !busy && !quitting, !password.isEmpty else { return }
        let secret = password, remember = rememberPassword && modalProfile?.allowPasswordSave == true
        password = ""; connectingID = id
        defer { connectingID = nil }
        if let result = await perform(.connect(id: id, password: secret, remember: remember), inModal: true), result.failure == nil {
            closeModal()
        }
    }

    func disconnect(_ id: String) async {
        guard !busy && !quitting else { return }
        disconnectingID = id; defer { disconnectingID = nil }
        _ = await perform(.disconnect(id))
    }

    func toggleFromMenu(_ id: String) async {
        guard let profile = state.profiles.first(where: { $0.id == id }), !busy && !quitting else { return }
        if state.sessions.contains(where: { $0.profileId == id && $0.active }) { await disconnect(id) }
        else { selectedID = id; screen = .overview; await connect(profile) }
    }

    func importProfile(_ url: URL) async {
        if let result = await perform(.importProfile(url)), result.failure == nil, let id = result.importedID {
            selectedID = id; screen = .overview; notify("Profile imported. Ready when you are.")
        }
    }

    func saveProfile(_ update: ProfileUpdate) async {
        guard case .settings(let id) = modal else { return }
        if let result = await perform(.update(id: id, update), inModal: true), result.failure == nil {
            closeModal(); notify("Profile settings saved.")
        }
    }

    func forget() async {
        guard let profile = modalProfile else { return }
        if let result = await perform(.forget(profile.id), inModal: true), result.failure == nil {
            notify("Saved password removed from Keychain.")
        }
    }

    func deleteProfile() async {
        guard case .delete(let id) = modal else { return }
        if let result = await perform(.delete(id), inModal: true), result.failure == nil { closeModal() }
    }

    func helperAction(_ operation: String) async { _ = await perform(.helper(operation)) }
    func disconnectAll() async { _ = await perform(.disconnectAll) }

    func prepareToQuit() async -> Bool {
        guard !quitting && !busy else { return false }
        quitting = true
        let result = await backend.execute(.disconnectAll)
        if let snapshot = result.snapshot { accept(snapshot) }
        if let failure = result.failure { error = failure.message; quitting = false; return false }
        stopPolling()
        return true
    }
}
