import Foundation
import Darwin

/// Production-only implementation. Never part of the hostless unit test target.
final class NativeBridge: VPNBridge {
    private struct Envelope: Decodable { var error: AppError? }
    private struct Identity: Decodable { var buildId: String? }

    private func response<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as: T.Type) throws -> T {
        guard let pointer else { throw AppError("native", "Native bridge returned an empty response.") }
        defer { vv_free(pointer) }
        // Decode directly from the bridge-owned buffer. vv_free erases it after
        // decoding; no extra Data copy retains raw Keychain response bytes.
        let data = Data(bytesNoCopy: pointer, count: strlen(pointer), deallocator: .none)
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)
        if let error = envelope.error { throw error }
        return try decoder.decode(T.self, from: data)
    }

    private func cString<T>(_ string: String, _ body: (UnsafePointer<CChar>) throws -> T) throws -> T {
        guard !string.contains("\0") else { throw AppError("invalid_input", "Input contains a null character.") }
        var bytes = string.utf8CString
        return try bytes.withUnsafeMutableBufferPointer { buffer in
            defer { memset_s(buffer.baseAddress, buffer.count, 0, buffer.count) }
            return try body(UnsafePointer(buffer.baseAddress!))
        }
    }

    func request(_ request: HelperRequest) throws -> HelperReply {
        precondition(!Thread.isMainThread, "XPC requests must run on the backend worker")
        var bytes = try JSONEncoder().encode(request)
        bytes.append(0)
        return try bytes.withUnsafeMutableBytes { raw in
            defer { memset_s(raw.baseAddress, raw.count, 0, raw.count) }
            return try response(vv_request(raw.bindMemory(to: CChar.self).baseAddress!), as: HelperReply.self)
        }
    }

    func service(_ operation: String) throws -> HelperStatus {
        precondition(!Thread.isMainThread)
        return try cString(operation) { try response(vv_service($0), as: HelperStatus.self) }
    }

    func bundledHelperID() throws -> String? {
        precondition(!Thread.isMainThread)
        return try response(vv_helper_identity(), as: Identity.self).buildId
    }

    func keychain(_ operation: String, id: String, secret: String) throws -> KeychainReply {
        precondition(!Thread.isMainThread)
        return try cString(operation) { operation in
            try cString(id) { id in
                try cString(secret) { secret in
                    try response(vv_keychain(operation, id, secret), as: KeychainReply.self)
                }
            }
        }
    }
}
