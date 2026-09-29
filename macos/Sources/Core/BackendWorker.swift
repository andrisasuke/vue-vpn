import Foundation

enum BackendCommand: Sendable {
    case refresh(credentials: Bool)
    case importProfile(URL)
    case connect(id: String, password: String?, remember: Bool)
    case disconnect(String), disconnectAll
    case update(id: String, ProfileUpdate)
    case forget(String), delete(String)
    case helper(String)
}

struct BackendResult: Sendable {
    var snapshot: Snapshot?
    var importedID: String?
    var failure: AppError?
}

protocol BackendExecuting: Sendable {
    func execute(_ command: BackendCommand) async -> BackendResult
}

/// Blocking bridge calls use a dedicated serial Dispatch executor, not the main
/// actor or Swift's cooperative thread pool. Commands cannot interleave midway
/// through route cleanup, password persistence, or helper replacement.
actor BackendWorker: BackendExecuting {
    private nonisolated let queue = DispatchSerialQueue(label: "com.vuevpn.desktop.backend", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let makeBackend: @Sendable () throws -> VPNBackend
    private var backend: VPNBackend?

    init(makeBackend: @escaping @Sendable () throws -> VPNBackend) { self.makeBackend = makeBackend }

    func execute(_ command: BackendCommand) -> BackendResult {
        precondition(!Thread.isMainThread)
        do {
            if backend == nil { backend = try makeBackend() }
            let backend = backend!
            var importedID: String?
            switch command {
            case .refresh(let credentials):
                if credentials { backend.refreshCredentials() }
                try backend.refresh()
            case .importProfile(let url): importedID = try backend.importProfile(url)
            case .connect(let id, let password, let remember): try backend.connect(id, password: password, remember: remember)
            case .disconnect(let id): try backend.disconnect(id)
            case .disconnectAll: try backend.disconnectAll()
            case .update(let id, let update): try backend.update(id, update)
            case .forget(let id): try backend.forget(id)
            case .delete(let id): try backend.delete(id)
            case .helper(let operation): try backend.helperAction(operation)
            }
            return BackendResult(snapshot: backend.snapshot, importedID: importedID)
        } catch {
            let failure = (error as? AppError) ?? AppError("error", error.localizedDescription)
            return BackendResult(snapshot: backend?.snapshot, failure: failure)
        }
    }
}
