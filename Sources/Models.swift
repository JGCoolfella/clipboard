import AppKit
import Combine
import CryptoKit
import Security
import Carbon
import UniformTypeIdentifiers

/// Immutable payload metadata is computed once, never decoded or hashed by a view body.
private final class ClipPayload: @unchecked Sendable {
    let representations: [[String: Data]]
    let byteCount: Int
    let digest: String
    let preview: String
    let stringData: Data?
    let imageData: Data?
    let fileURLs: [URL]
    let isGIF: Bool
    static let strings = SharedCache<NSUUID, NSString>(cost: 16 * 1024 * 1024, count: 500)
    let cacheID = NSUUID()
    init(_ representations: [[String: Data]]) {
        self.representations = representations
        byteCount = representations.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
        stringData = representations.compactMap { $0[NSPasteboard.PasteboardType.string.rawValue] }.first
        imageData = representations.lazy.compactMap { item in
            ["com.compuserve.gif", "public.png", "public.tiff", "public.jpeg", "public.heic"].lazy.compactMap { item[$0] }.first
        }.first
        isGIF = representations.contains { $0["com.compuserve.gif"] != nil }
        fileURLs = representations.compactMap { item in
            guard let data = item["public.file-url"], data.count <= 16_384,
                  let value = String(data: data, encoding: .utf8), let url = URL(string: value), url.isFileURL else { return nil }
            return url
        }
        if let data = stringData, !data.isEmpty { preview = String(String(decoding: data.prefix(16_384), as: UTF8.self).prefix(4000)) }
        else if !fileURLs.isEmpty { preview = fileURLs.map(\.lastPathComponent).joined(separator: ", ") }
        else { preview = isGIF ? "Animated GIF" : imageData != nil ? "Image" : "Rich content" }
        var hash = SHA256()
        func length(_ count: Int) { var value = UInt64(count).bigEndian; withUnsafeBytes(of: &value) { hash.update(data: Data($0)) } }
        length(representations.count)
        for item in representations {
            length(item.count)
            for key in item.keys.sorted() {
                let name = Data(key.utf8), value = item[key]!
                length(name.count); hash.update(data: name); length(value.count); hash.update(data: value)
            }
        }
        digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    var text: String {
        guard let stringData else { return "" }
        if let cached = Self.strings.object(forKey: cacheID) { return cached as String }
        let value = String(data: stringData, encoding: .utf8) ?? ""
        if stringData.count <= 256 * 1024 { Self.strings.setObject(value as NSString, forKey: cacheID, cost: max(stringData.count, value.utf16.count * 2)) }
        return value
    }
}

struct Clip: Codable, Identifiable, Equatable, Sendable {
    static let allowedTypes = Set(["public.utf8-plain-text", "public.utf16-plain-text", "public.html", "public.rtf", "com.apple.flat-rtfd", "public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif", "public.file-url", "public.url"])
    var id: UUID
    var created: Date
    var modified: Date
    var pinned: Bool
    var source: String
    var sourceID: String
    private let payload: ClipPayload
    var representations: [[String: Data]] { payload.representations }
    var text: String { payload.text }
    var hasText: Bool { !(payload.stringData?.isEmpty ?? true) }
    var textByteCount: Int { payload.stringData?.count ?? 0 }
    var imageData: Data? { payload.imageData }
    var fileURLs: [URL] { payload.fileURLs }
    var isGIF: Bool { payload.isGIF }
    var byteCount: Int { payload.byteCount }
    var summary: String { payload.preview }
    var digest: String { payload.digest }
    init(id: UUID = UUID(), created: Date = Date(), modified: Date = Date(), pinned: Bool = false, source: String = "", sourceID: String = "", representations: [[String: Data]]) {
        self.id = id; self.created = created; self.modified = modified; self.pinned = pinned
        self.source = source; self.sourceID = sourceID; payload = ClipPayload(representations)
    }
    static func validated(id: UUID = UUID(), created: Date = Date(), modified: Date = Date(), pinned: Bool = false, source: String = "", sourceID: String = "", representations: [[String: Data]], maximum: Int) throws -> Clip {
        guard maximum >= 0, !representations.isEmpty, representations.count <= 256, source.utf8.count <= 4096, sourceID.utf8.count <= 4096,
              created.timeIntervalSince1970.isFinite, modified.timeIntervalSince1970.isFinite else { throw SafetyError.invalidContent }
        var bytes = 0
        for item in representations {
            guard !item.isEmpty, item.count <= allowedTypes.count else { throw SafetyError.invalidContent }
            for (type, data) in item {
                guard allowedTypes.contains(type), data.count <= maximum - bytes else { throw SafetyError.invalidContent }
                bytes += data.count
            }
        }
        return Clip(id: id, created: created, modified: modified, pinned: pinned, source: source, sourceID: sourceID, representations: representations)
    }
    static func text(_ value: String, source: String = "Clipboard") -> Clip { Clip(source: source, representations: [[NSPasteboard.PasteboardType.string.rawValue: Data(value.utf8)]]) }
    static func == (a: Clip, b: Clip) -> Bool { a.id == b.id && a.created == b.created && a.modified == b.modified && a.pinned == b.pinned && a.source == b.source && a.sourceID == b.sourceID && a.digest == b.digest }
    private enum CodingKeys: String, CodingKey { case id, created, modified, pinned, source, sourceID, representations }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self.validated(id: values.decode(UUID.self, forKey: .id), created: values.decode(Date.self, forKey: .created), modified: values.decode(Date.self, forKey: .modified), pinned: values.decode(Bool.self, forKey: .pinned), source: values.decode(String.self, forKey: .source), sourceID: values.decode(String.self, forKey: .sourceID), representations: values.decode([[String: Data]].self, forKey: .representations), maximum: 128 * 1024 * 1024)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(created, forKey: .created); try values.encode(modified, forKey: .modified)
        try values.encode(pinned, forKey: .pinned); try values.encode(source, forKey: .source); try values.encode(sourceID, forKey: .sourceID); try values.encode(representations, forKey: .representations)
    }
    static func purgeTextCache() { ClipPayload.strings.removeAllObjects() }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32 = 9
    var modifiers: UInt32 = UInt32(cmdKey | shiftKey)
    var character = "V"
    var label: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + character.uppercased()
    }
    static func from(_ event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option),
              let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
              ![UInt16(36), 48, 51, 53, 123, 124, 125, 126].contains(event.keyCode) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, character: characters.uppercased())
    }
}

struct Preferences: Codable, Equatable {
    var shortcut = Shortcut()
    var historyLimit = 250
    var itemLimitMB = 32
    var storageLimitMB = 256
    var persistHistory = true
    var automaticPaste = true
    var pastePlainText = false
    var captureEnabled = true
    var appearance = "system"
    var excludedApps = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.apple.keychainaccess"]
    var syncPath = ""
    var automaticSync = false
    var onboardingComplete = false
    mutating func normalize() {
        historyLimit = min(5000, max(25, historyLimit))
        itemLimitMB = min(128, max(4, itemLimitMB))
        storageLimitMB = min(4096, max(64, storageLimitMB))
        if !["system", "light", "dark"].contains(appearance) { appearance = "system" }
        excludedApps = Array(Set(excludedApps.filter { !$0.isEmpty && $0.utf8.count <= 4096 })).sorted()
        excludedApps = Array(excludedApps.prefix(256))
    }
}

enum VaultError: LocalizedError {
    case keychain(OSStatus)
    case invalidKey
    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "Keychain access failed (\(status)). History will stay in memory until this is resolved."
        case .invalidKey: return "The saved encryption key could not be read."
        }
    }
}

enum Keychain {
    static let service = AppIdentity.bundleIdentifier
    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        return result as? Data
    }
    static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw VaultError.keychain(update) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }
    static func delete(_ account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }
}

enum HistoryRules {
    static func limited(_ clips: [Clip], count: Int, bytes: Int) -> [Clip] {
        let pinned = clips.filter(\.pinned)
        var remaining = max(0, bytes - pinned.reduce(0) { $0 + $1.byteCount })
        var available = max(0, count - pinned.count)
        let accepted = Set(clips.filter { !$0.pinned }.compactMap { clip -> UUID? in
            guard available > 0, clip.byteCount <= remaining else { return nil }
            remaining -= clip.byteCount; available -= 1
            return clip.id
        })
        return clips.filter { $0.pinned || accepted.contains($0.id) }
    }
    static func inserting(_ clip: Clip, into clips: [Clip], count: Int, bytes: Int) -> [Clip] {
        var result = clips
        var incoming = clip
        let digest = clip.digest
        if let index = result.firstIndex(where: { $0.digest == digest }) {
            let old = result.remove(at: index)
            incoming.id = old.id; incoming.pinned = old.pinned
        }
        result.insert(incoming, at: 0)
        return limited(result, count: count, bytes: bytes)
    }
    static func isSensitive(_ types: [String]) -> Bool {
        let markers = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        return types.contains { markers.contains($0) }
    }
}

@MainActor
final class ClipboardStore: ObservableObject {
    @Published var clips: [Clip] = [] { didSet { revision &+= 1 } }
    private(set) var revision: UInt64 = 0
    @Published var isLoading = false
    private(set) var suspended = false
    @Published var preferences = Preferences()
    @Published var notice = ""
    @Published var storageError = ""
    @Published var recentCharacters: [String] = []
    @Published var gifLibrary: [Clip] = []
    @Published var trusted = AXIsProcessTrusted()
    var vault: Vault?
    var monitor: Timer?
    let pasteboard: NSPasteboard
    var observedChange: Int
    var preferencesChanged: (() -> Void)?
    var sync: FolderSync?
    var testMode = false
    private var saveWork: DispatchWorkItem?
    private var dirtySince: Date?
    private var captureTask: Task<Void, Never>?
    private var lastPreferences = Preferences()
    private var canSaveGIFs = true
    private let preferencesKey = "preferences.v1"
    var totalBytes: Int { clips.reduce(0) { $0 + $1.byteCount } }

    init(testMode: Bool = false, pasteboard: NSPasteboard = .general) {
        self.testMode = testMode
        self.pasteboard = pasteboard
        observedChange = pasteboard.changeCount
        guard !testMode else { return }
        if let data = UserDefaults.standard.data(forKey: preferencesKey), data.count <= 1024 * 1024,
           let saved = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = saved }
        preferences.normalize(); lastPreferences = preferences
        recentCharacters = UserDefaults.standard.stringArray(forKey: "recentCharacters") ?? []
        do {
            vault = try Vault.production()
            isLoading = true
            if let vault {
                vault.queue.async { [weak self] in
                    do {
                        let archive = try autoreleasepool { try vault.load() }
                        var library: [Clip] = []; var gifError = false
                        do { library = try autoreleasepool { try vault.load(.gifs)?.clips ?? [] } } catch { gifError = true }
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.clips = self.preferences.persistHistory ? (archive?.clips ?? []) : (archive?.clips.filter(\.pinned) ?? [])
                            self.gifLibrary = HistoryRules.limited(library, count: 100, bytes: 256 * 1024 * 1024)
                            self.canSaveGIFs = !gifError
                            if gifError { self.storageError = "The saved GIF library could not be opened. It has been preserved on disk." }
                            self.applyLimits(); self.isLoading = false
                            self.sync?.receive()
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self?.vault = nil; self?.isLoading = false
                            self?.storageError = "Saved history could not be opened. Existing files are preserved; this session will use memory only."
                        }
                    }
                }
            }
        } catch { storageError = "Saved history could not be opened: \(error.localizedDescription)" }
        sync = FolderSync(store: self)
    }
    func start() {
        monitor = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        monitor?.tolerance = 0.12
        sync?.start()
    }
    func suspend(_ value: Bool) {
        suspended = value; captureTask?.cancel(); observedChange = pasteboard.changeCount
    }
    func stop() { monitor?.invalidate(); monitor = nil; captureTask?.cancel(); sync?.stop() }
    func poll() {
        guard !isLoading, !suspended else { return }
        guard pasteboard.changeCount != observedChange else { return }
        observedChange = pasteboard.changeCount
        guard preferences.captureEnabled, !IsSecureEventInputEnabled() else { return }
        let application = NSWorkspace.shared.frontmostApplication
        let appID = application?.bundleIdentifier ?? ""
        guard appID != AppIdentity.bundleIdentifier, !preferences.excludedApps.contains(appID) else { return }
        let items = pasteboard.pasteboardItems ?? []
        guard !HistoryRules.isSensitive(items.flatMap { $0.types.map(\.rawValue) }) else { return }
        guard items.count <= 256 else { return }
        var representations: [[String: Data]] = []
        var bytes = 0
        for item in items {
            var data: [String: Data] = [:]
            for type in item.types where Clip.allowedTypes.contains(type.rawValue) {
                guard let value = item.data(forType: type) else { continue }
                bytes += value.count
                guard bytes <= preferences.itemLimitMB * 1024 * 1024 else { notice = "Skipped an item larger than \(preferences.itemLimitMB) MB."; return }
                data[type.rawValue] = value
            }
            if data[NSPasteboard.PasteboardType.string.rawValue] == nil, let value = item.string(forType: .string) {
                let normalized = Data(value.utf8)
                guard normalized.count <= preferences.itemLimitMB * 1024 * 1024 - bytes else { notice = "Skipped an item larger than your item limit."; return }
                bytes += normalized.count; data[NSPasteboard.PasteboardType.string.rawValue] = normalized
            }
            if !data.isEmpty { representations.append(data) }
        }
        guard pasteboard.changeCount == observedChange, !representations.isEmpty else { return }
        let change = observedChange, maximum = preferences.itemLimitMB * 1024 * 1024
        let source = application?.localizedName ?? "Application"
        captureTask?.cancel()
        captureTask = Task { [weak self, snapshot = representations] in
            let clip = await Task.detached(priority: .userInitiated) {
                try? Clip.validated(source: source, sourceID: appID, representations: snapshot, maximum: maximum)
            }.value
            guard !Task.isCancelled, let self, let clip, self.pasteboard.changeCount == change,
                  self.preferences.captureEnabled, !self.preferences.excludedApps.contains(appID) else { return }
            guard clip.hasText || clip.imageData != nil || !clip.fileURLs.isEmpty || clip.representations.contains(where: { $0["public.html"] != nil || $0["public.rtf"] != nil }) else { return }
            self.add(clip)
        }
    }
    func add(_ clip: Clip) {
        guard clip.byteCount <= preferences.itemLimitMB * 1024 * 1024 else { notice = "This item exceeds the current item limit."; return }
        let result = HistoryRules.inserting(clip, into: clips, count: preferences.historyLimit, bytes: preferences.storageLimitMB * 1024 * 1024)
        guard result.contains(where: { $0.digest == clip.digest }) else { notice = "History is full of pinned items. Unpin an item or increase your limits."; return }
        clips = result
        saveSoon()
        if preferences.automaticSync { sync?.upload(clip) }
    }
    func togglePin(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index].pinned.toggle(); clips[index].modified = Date()
        saveSoon()
    }
    private func purgePreviews() { Clip.purgeTextCache(); PreviewCache.purge() }
    func delete(_ clip: Clip) { clips.removeAll { $0.id == clip.id }; purgePreviews(); saveSoon() }
    func clearUnpinned() { clips.removeAll { !$0.pinned }; purgePreviews(); saveSoon() }
    func clearEverything() { captureTask?.cancel(); clips.removeAll(); purgePreviews(); pasteboard.clearContents(); observedChange = pasteboard.changeCount; saveSoon() }
    func applyLimits() { clips = HistoryRules.limited(clips, count: preferences.historyLimit, bytes: preferences.storageLimitMB * 1024 * 1024) }
    func updatePreferences() {
        preferences.normalize()
        let historyChanged = preferences.historyLimit != lastPreferences.historyLimit || preferences.storageLimitMB != lastPreferences.storageLimitMB || preferences.persistHistory != lastPreferences.persistHistory
        if !preferences.captureEnabled { captureTask?.cancel() }
        if !testMode, let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: preferencesKey) }
        if historyChanged { applyLimits(); purgePreviews(); saveSoon() }
        lastPreferences = preferences; preferencesChanged?()
    }
    func saveSoon() {
        guard !testMode, !isLoading, vault != nil else { return }
        saveWork?.cancel()
        let firstDirty = dirtySince ?? Date(); dirtySince = firstDirty
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        let delay = min(0.6, max(0, 2 - Date().timeIntervalSince(firstDirty)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func saveNow() {
        guard !testMode, !isLoading, let vault else { return }
        dirtySince = nil
        let saved = preferences.persistHistory ? clips : clips.filter(\.pinned)
        vault.save(Archive(clips: saved, boot: "")) { [weak self] error in
            if let error { self?.storageError = error } else if self?.canSaveGIFs == true { self?.storageError = "" }
        }
    }
    func flush() {
        saveWork?.cancel()
        guard !testMode, !isLoading, let vault else { return }
        let archive = Archive(clips: preferences.persistHistory ? clips : clips.filter(\.pinned), boot: "")
        do { try vault.flush(archive); if canSaveGIFs { try vault.flush(Archive(clips: gifLibrary, boot: ""), collection: .gifs) } }
        catch { storageError = "Encrypted storage could not be saved before quitting." }
    }
    @discardableResult func writeToPasteboard(_ clip: Clip, plain: Bool = false) -> Bool {
        pasteboard.clearContents()
        let success: Bool
        if plain, clip.hasText { success = pasteboard.setString(clip.text, forType: .string) }
        else {
            let items = clip.representations.map { representation in
                let item = NSPasteboardItem()
                for (type, data) in representation { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
                return item
            }
            success = pasteboard.writeObjects(items)
        }
        observedChange = pasteboard.changeCount
        if !success { notice = "The clipboard could not be written. No paste was sent." }
        return success
    }
    func rememberCharacter(_ value: String) {
        recentCharacters.removeAll { $0 == value }; recentCharacters.insert(value, at: 0)
        recentCharacters = Array(recentCharacters.prefix(48))
        if !testMode { UserDefaults.standard.set(recentCharacters, forKey: "recentCharacters") }
    }
    func importGIFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls, maximum = preferences.itemLimitMB * 1024 * 1024
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                var clips: [Clip] = []; var failed = 0; var bytes = 0
                for url in urls.prefix(100) {
                    do {
                        let data = try SecureFiles.read(url, maximum: min(maximum, 256 * 1024 * 1024 - bytes))
                        guard MediaSafety.isGIF(data) else { throw SafetyError.invalidContent }
                        bytes += data.count
                        clips.append(Clip(source: String(url.deletingPathExtension().lastPathComponent.prefix(512)), representations: [["com.compuserve.gif": data]]))
                    } catch { failed += 1 }
                }
                return (clips, failed)
            }.value
            guard let self else { return }
            var library = self.gifLibrary, known = Set(library.map(\.digest))
            for clip in loaded.0 where clip.byteCount <= self.preferences.itemLimitMB * 1024 * 1024 {
                if known.insert(clip.digest).inserted { library.insert(clip, at: 0) }
            }
            self.gifLibrary = HistoryRules.limited(library, count: 100, bytes: 256 * 1024 * 1024)
            self.saveGIFs()
            if loaded.1 > 0 { self.notice = "Skipped \(loaded.1) invalid or oversized GIF file(s)." }
        }
    }

    func saveGIFs() {
        guard !testMode, !isLoading, canSaveGIFs, let vault else { return }
        let limited = HistoryRules.limited(gifLibrary, count: 100, bytes: 256 * 1024 * 1024)
        gifLibrary = limited
        vault.save(Archive(clips: limited, boot: ""), collection: .gifs) { [weak self] error in if let error { self?.notice = error } }
    }
}
