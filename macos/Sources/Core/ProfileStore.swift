import Foundation
import Darwin

/// Constructed on the backend's serial queue. Tests always supply a temporary root.
final class ProfileStore {
    let root: URL
    private let files = FileManager.default

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        try privateDirectory(self.root)
    }

    func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, !id.contains("/"), !id.contains("\0") else {
            throw AppError("invalid_id", "Invalid profile identifier.")
        }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    func profiles() throws -> [Profile] {
        var profiles: [Profile] = []
        for entry in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let attributes = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
            let path = entry.appendingPathComponent("profile.json")
            guard files.fileExists(atPath: path.path) else { continue }
            let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: path))
            guard try directory(profile.id).standardizedFileURL == entry.standardizedFileURL else {
                throw AppError("data", "Profile directory identity mismatch.")
            }
            profiles.append(profile)
        }
        return profiles.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    func save(_ profile: Profile, content: String? = nil) throws {
        let dir = try directory(profile.id)
        try privateDirectory(dir)
        if let content { try atomicWrite(Data(content.utf8), to: dir.appendingPathComponent("config.ovpn")) }
        var clean = profile
        clean.remembered = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try atomicWrite(encoder.encode(clean), to: dir.appendingPathComponent("profile.json"))
    }

    func content(_ id: String) throws -> String {
        try ProfileParser.readBounded(directory(id).appendingPathComponent("config.ovpn"))
    }

    func delete(_ id: String) throws {
        let dir = try directory(id)
        if files.fileExists(atPath: dir.path) { try files.removeItem(at: dir) }
    }

    private func privateDirectory(_ url: URL) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw AppError("storage", "Profile storage must not be a symbolic link.")
        }
        guard chmod(url.path, 0o700) == 0 else { throw ioError() }
    }

    private func ioError() -> AppError { AppError("storage", String(cString: strerror(errno))) }

    private func atomicWrite(_ data: Data, to path: URL) throws {
        let temporary = path.deletingPathExtension().appendingPathExtension(UUID().uuidString + ".tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ioError() }
        defer { Darwin.close(fd); try? files.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ioError() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ioError() }
        guard rename(temporary.path, path.path) == 0 else { throw ioError() }
    }
}
