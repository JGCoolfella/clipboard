import Foundation
import CryptoKit

struct Archive: Codable, Sendable { var version = 1; var clips: [Clip]; var boot: String }

/// Immutable encrypted payloads plus a small authenticated index. Metadata edits never rewrite image bytes.
final class Vault: @unchecked Sendable {
    typealias Completion = @MainActor @Sendable (String?) -> Void
    enum Collection: String, CaseIterable { case history, gifs }
    struct Record: Codable {
        var id: UUID; var created: Date; var modified: Date; var pinned: Bool
        var source: String; var sourceID: String; var blob: String
    }
    struct Index: Codable { var version = 2; var records: [Record] }
    let directory: URL
    let key: SymmetricKey
    private let fileNameKey: SymmetricKey
    let queue = DispatchQueue(label: AppIdentity.bundleIdentifier + ".vault", qos: .utility)
    private var knownBlobs = Set<String>() // Only accessed on the serial I/O queue, or by synchronous test callers.
    private let pendingLock = NSLock()
    private var pending: [Collection: (Archive, Completion)] = [:]
    private var scheduled = false
    private let maximumItem = 128 * 1024 * 1024
    private let maximumTotal = 4096 * 1024 * 1024

    init(directory: URL, key: SymmetricKey) throws {
        self.directory = directory; self.key = key
        fileNameKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data((AppIdentity.vaultNamespace + "/blob-names").utf8), outputByteCount: 32)
        try SecureFiles.prepareDirectory(directory, privateAccess: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var location = directory; try location.setResourceValues(values)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        knownBlobs = Set(files.filter { $0.pathExtension == "clipdata" }.map(\.lastPathComponent))
    }
    static func production() throws -> Vault {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AppIdentity.storagePath, isDirectory: true)
        let data: Data
        if let saved = try Keychain.read("history-key-v1") {
            guard saved.count == 32 else { throw VaultError.invalidKey }; data = saved
        } else {
            // A missing key must not result in silently replacing an existing encrypted history.
            let existing = ["history.encrypted", "gifs.encrypted", "history.index", "gifs.index"].contains { SecureFiles.exists(directory.appendingPathComponent($0)) }
            guard !existing else { throw VaultError.invalidKey }
            data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try Keychain.write(data, account: "history-key-v1")
        }
        return try Vault(directory: directory, key: SymmetricKey(data: data))
    }
    private func context(_ name: String) -> Data { Data("\(AppIdentity.vaultNamespace)/\(name)".utf8) }
    private func seal(_ data: Data, name: String) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: context(name)).combined else { throw VaultError.invalidKey }
        return combined
    }
    private func open(_ url: URL, maximum: Int, name: String) throws -> Data {
        let encrypted = try SecureFiles.read(url, maximum: maximum)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key, authenticating: context(name))
    }
    private func blobName(_ clip: Clip) -> String {
        // A plain content hash in a filename would permit offline guessing of short copied secrets.
        HMAC<SHA256>.authenticationCode(for: Data(clip.digest.utf8), using: fileNameKey).map { String(format: "%02x", $0) }.joined() + ".clipdata"
    }
    static func validBlob(_ name: String) -> Bool {
        name.count == 73 && name.hasSuffix(".clipdata") && name.prefix(64).allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
    }
    private func index(_ collection: Collection) throws -> Index? {
        let url = directory.appendingPathComponent(collection.rawValue + ".index")
        guard SecureFiles.exists(url) else { return nil }
        let result = try JSONDecoder().decode(Index.self, from: open(url, maximum: 16 * 1024 * 1024, name: collection.rawValue + "/index"))
        guard result.version == 2, result.records.count <= 5000, Set(result.records.map(\.id)).count == result.records.count,
              result.records.allSatisfy({ Self.validBlob($0.blob) && $0.source.utf8.count <= 4096 && $0.sourceID.utf8.count <= 4096 }) else { throw SafetyError.invalidContent }
        return result
    }
    func load(_ collection: Collection = .history) throws -> Archive? {
        if let index = try index(collection) {
            var clips: [Clip] = []; var total = 0
            for record in index.records {
                let data = try open(directory.appendingPathComponent(record.blob), maximum: maximumItem * 2 + 1024 * 1024, name: "blob/" + record.blob)
                let representations = try JSONDecoder().decode([[String: Data]].self, from: data)
                let clip = try Clip.validated(id: record.id, created: record.created, modified: record.modified, pinned: record.pinned, source: record.source, sourceID: record.sourceID, representations: representations, maximum: maximumItem)
                guard clip.byteCount <= maximumTotal - total, blobName(clip) == record.blob else { throw SafetyError.invalidContent }
                total += clip.byteCount; clips.append(clip)
            }
            return Archive(clips: clips, boot: "")
        }
        let legacyURL = directory.appendingPathComponent(collection.rawValue + ".encrypted")
        guard SecureFiles.exists(legacyURL) else { return nil }
        let data = try SecureFiles.read(legacyURL, maximum: maximumTotal * 2)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        let clips: [Clip]
        if collection == .history {
            let archive = try JSONDecoder().decode(Archive.self, from: clear)
            guard archive.version == 1 else { throw SafetyError.invalidContent }; clips = archive.clips
        } else { clips = try JSONDecoder().decode([Clip].self, from: clear) }
        guard clips.count <= 5000, Set(clips.map(\.id)).count == clips.count else { throw SafetyError.invalidContent }
        var total = 0
        for clip in clips {
            guard clip.byteCount <= maximumTotal - total else { throw SafetyError.tooLarge }; total += clip.byteCount
        }
        return Archive(clips: clips, boot: "")
    }
    func write(_ archive: Archive, collection: Collection = .history) throws {
        guard archive.clips.count <= 5000, Set(archive.clips.map(\.id)).count == archive.clips.count else { throw SafetyError.tooLarge }
        var total = 0
        for clip in archive.clips {
            guard clip.byteCount <= maximumItem, clip.byteCount <= maximumTotal - total,
                  clip.source.utf8.count <= 4096, clip.sourceID.utf8.count <= 4096 else { throw SafetyError.tooLarge }
            total += clip.byteCount
        }
        var records: [Record] = []
        for clip in archive.clips {
            let name = blobName(clip)
            if !knownBlobs.contains(name) || !SecureFiles.exists(directory.appendingPathComponent(name)) {
                let body = try JSONEncoder().encode(clip.representations)
                try SecureFiles.write(seal(body, name: "blob/" + name), to: directory.appendingPathComponent(name))
                knownBlobs.insert(name)
            }
            records.append(Record(id: clip.id, created: clip.created, modified: clip.modified, pinned: clip.pinned, source: clip.source, sourceID: clip.sourceID, blob: name))
        }
        let name = collection.rawValue + ".index"
        try SecureFiles.write(seal(JSONEncoder().encode(Index(records: records)), name: collection.rawValue + "/index"), to: directory.appendingPathComponent(name))
        // Only remove the legacy file after the complete new index has committed.
        let legacy = directory.appendingPathComponent(collection.rawValue + ".encrypted")
        if SecureFiles.exists(legacy) { try FileManager.default.removeItem(at: legacy) }
        try prune()
    }
    private func prune() throws {
        // A legacy collection may refer to blobs not yet migrated. Keep all blobs until both are safe to inspect.
        if Collection.allCases.contains(where: { SecureFiles.exists(directory.appendingPathComponent($0.rawValue + ".encrypted")) }) { return }
        var live = Set<String>()
        for collection in Collection.allCases { if let index = try index(collection) { live.formUnion(index.records.map(\.blob)) } }
        for name in knownBlobs.subtracting(live) where Self.validBlob(name) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name)); knownBlobs.remove(name)
        }
    }
    func save(_ archive: Archive, collection: Collection = .history, completion: @escaping Completion) {
        let launch = pendingLock.withLock { () -> Bool in
            pending[collection] = (archive, completion)
            if scheduled { return false }; scheduled = true; return true
        }
        if launch { queue.async { [self] in drain() } }
    }
    private func drain() {
        while true {
            let next = pendingLock.withLock { () -> (Collection, Archive, Completion)? in
                guard let entry = pending.first else { scheduled = false; return nil }
                pending.removeValue(forKey: entry.key); return (entry.key, entry.value.0, entry.value.1)
            }
            guard let (collection, archive, completion) = next else { return }
            let failure: String?
            do { try autoreleasepool { try write(archive, collection: collection) }; failure = nil }
            catch { failure = "Encrypted storage could not be saved. Your existing data has been preserved." }
            DispatchQueue.main.async { completion(failure) }
        }
    }
    func flush(_ archive: Archive, collection: Collection = .history) throws {
        _ = pendingLock.withLock { pending.removeValue(forKey: collection) }
        try queue.sync { try write(archive, collection: collection) }
    }
}
