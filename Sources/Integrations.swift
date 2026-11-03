import AppKit
import Carbon
import CryptoKit
import CommonCrypto
import ServiceManagement

@MainActor
final class GlobalShortcut {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.action?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: Shortcut) -> Bool {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        let identifier = EventHotKeyID(signature: 0x434C4950, id: 1) // CLIP
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &reference) == noErr
    }
    func stop(removeHandler: Bool = false) {
        if let reference { UnregisterEventHotKey(reference) }; reference = nil
        if removeHandler, let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

struct CharacterItem: Identifiable {
    var value: String
    var name: String
    var category: String
    var id: String { value }
}

enum CharacterCatalog {
    static let emoji: [CharacterItem] = {
        // Read the local system's labels, without calling any private framework APIs.
        // The Character Viewer button always provides the complete native catalogue.
        let path = "/System/Library/PrivateFrameworks/CoreEmoji.framework/Resources/en.lproj/AppleName.strings"
        var names = (NSDictionary(contentsOfFile: path) as? [String: String]) ?? [:]
        if names.isEmpty {
            for value in ["😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😍", "🥰", "😎", "🤔", "😢", "😭", "😡", "👍", "👎", "👋", "🙏", "👏", "🎉", "🔥", "❤️", "✅", "🚀", "💻", "🐱", "🐶", "☕"] {
                names[value] = value.unicodeScalars.first?.properties.name?.lowercased() ?? "emoji"
            }
        }
        for (value, name) in Array(names) {
            guard let first = value.unicodeScalars.first, first.properties.isEmojiModifierBase,
                  !value.unicodeScalars.contains(where: { $0.properties.isEmojiModifier }) else { continue }
            let scalars = Array(value.unicodeScalars)
            for (index, tone) in ["🏻", "🏼", "🏽", "🏾", "🏿"].enumerated() {
                let rest = scalars.dropFirst().filter { $0.value != 0xFE0F }.map(String.init).joined()
                names[String(first) + tone + rest] = name + ", skin tone \(index + 1)"
            }
        }
        let favourite = ["😀", "😊", "😂", "🥰", "😍", "😎", "🤔", "😭", "👍", "👋", "🙏", "👏", "❤️", "🎉", "🔥", "✅", "🚀", "💻", "☕"]
        return names.map { CharacterItem(value: $0.key, name: $0.value, category: emojiCategory($0.key)) }.sorted {
            let a = favourite.firstIndex(of: $0.value) ?? 999, b = favourite.firstIndex(of: $1.value) ?? 999
            return a == b ? $0.value < $1.value : a < b
        }
    }()
    static func emojiCategory(_ value: String) -> String {
        let code = value.unicodeScalars.first?.value ?? 0
        if value.unicodeScalars.contains(where: { (0x1F1E6...0x1F1FF).contains($0.value) }) { return "Flags" }
        if (0x1F600...0x1F64F).contains(code) || (0x1F910...0x1F92F).contains(code) || (0x1FAE0...0x1FAFF).contains(code) { return "Smileys" }
        if (0x1F466...0x1F487).contains(code) || (0x1F590...0x1F596).contains(code) || value.unicodeScalars.contains(where: { $0.properties.isEmojiModifierBase }) { return "People" }
        if (0x1F330...0x1F343).contains(code) || (0x1F400...0x1F43F).contains(code) || (0x1F980...0x1F9AF).contains(code) { return "Nature" }
        if (0x1F344...0x1F37F).contains(code) || (0x1F950...0x1F96F).contains(code) { return "Food" }
        if (0x1F680...0x1F6FF).contains(code) || (0x1F3D4...0x1F3EF).contains(code) { return "Travel" }
        return "Objects"
    }
    static let symbols: [CharacterItem] = {
        let blocks: [(String, ClosedRange<UInt32>)] = [("Punctuation", 0x2010...0x205E), ("Currency", 0x20A0...0x20BF), ("Math", 0x2200...0x22FF), ("Arrows", 0x2190...0x21FF), ("Latin", 0x00A1...0x00FF), ("Shapes", 0x25A0...0x25FF), ("Greek", 0x0391...0x03C9)]
        return blocks.flatMap { category, range in
            range.compactMap { code -> CharacterItem? in
                guard let scalar = Unicode.Scalar(code), let name = scalar.properties.name,
                      !scalar.properties.isWhitespace, scalar.properties.generalCategory != .unassigned else { return nil }
                return CharacterItem(value: String(scalar), name: name.lowercased(), category: category)
            }
        }
    }()
    static let kaomoji: [CharacterItem] = {
        let groups: [(String, String)] = [
            ("Happy", "(•‿•)|(^_^)|(◕‿◕)|(＾▽＾)|(✿◠‿◠)|(｡♥‿♥｡)|(≧▽≦)|(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧|(づ｡◕‿‿◕｡)づ|(´｡• ᵕ •｡`)|٩(◕‿◕｡)۶|ヽ(・∀・)ﾉ|(´ ∀ ` *)|(⌒▽⌒)☆|(o^▽^o)|(⌒‿⌒)|＼(≧▽≦)／|ヽ(o＾▽＾o)ノ|(*≧ω≦*)|(*^‿^*)|٩(｡•́‿•̀｡)۶"),
            ("Love", "(♡˙︶˙♡)|(◍•ᴗ•◍)❤|(灬º‿º灬)♡|(｡・//ε//・｡)|♡( ◡‿◡ )|( ˘⌣˘)♡(˘⌣˘ )|(´♡‿♡`)|♡＼(￣▽￣)／♡|(❤ω❤)|(´｡• ω •｡`) ♡"),
            ("Sad", "(╥﹏╥)|(T_T)|(；ω；)|(｡•́︿•̀｡)|(っ˘̩╭╮˘̩)っ|(ಥ﹏ಥ)|(；＿；)|(｡╯︵╰｡)|(╯︵╰,)|(-_-)"),
            ("Surprised", "(⊙_⊙)|(°ロ°) !|(ﾉﾟ0ﾟ)ﾉ|Σ(°△°)︴|(・o・)|(O_O;)|(°〇°)|(⊙ω⊙)|Σ(ﾟДﾟ)|w(°ｏ°)w"),
            ("Shrug", "¯\\_(ツ)_/¯|┐(￣ヘ￣)┌|┐( ˘_˘)┌|╮(￣_￣)╭|┐(￣～￣)┌|╮(╯_╰)╭|┐(・_・)┌|(・・ ) ?|(￢_￢)|(¬_¬ )"),
            ("Angry", "(╯°□°）╯︵ ┻━┻|┻━┻ ︵ヽ(`Д´)ﾉ︵ ┻━┻|ಠ_ಠ|(ノಠ益ಠ)ノ彡┻━┻|(＃`Д´)|(ง •̀_•́)ง|ヽ( `д´*)ノ|(눈_눈)|(凸ಠ益ಠ)凸"),
            ("Animals", "ฅ^•ﻌ•^ฅ|ʕ•ᴥ•ʔ|(=^･ω･^=)|(ᵔᴥᵔ)|(=｀ω´=)|/ᐠ｡ꞈ｡ᐟ\\|(U・ᴥ・U)|ʕっ•ᴥ•ʔっ|(≚ᄌ≚)|ᘛ⁐̤ᕐᐷ"),
            ("Celebration", "♪┏(・o･)┛♪|♪ヽ(^^ヽ)♪|ヾ(⌐■_■)ノ♪|ᕕ( ᐛ )ᕗ|☜(ﾟヮﾟ☜)|☞(ﾟヮﾟ)☞|✧٩(•́⌄•́๑)و ✧|٩(ˊᗜˋ*)و|ᕙ(⇀‸↼‶)ᕗ|( •_•)>⌐■-■")
        ]
        return groups.flatMap { category, values in values.components(separatedBy: "|").filter { !$0.isEmpty }.map { CharacterItem(value: $0, name: category.lowercased(), category: category) } }
    }()
}

struct RemoteGIF: Identifiable, Decodable {
    struct Images: Decodable {
        struct Rendition: Decodable { var url: String; var size: String? }
        var fixed_width: Rendition
        var original: Rendition
    }
    var id: String
    var title: String
    var images: Images
}

@MainActor
final class GIFSearch: ObservableObject {
    @Published var results: [RemoteGIF] = []
    @Published var loading = false
    @Published var error = ""
    private var task: Task<Void, Never>?
    func search(_ query: String) {
        task?.cancel()
        task = Task {
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                guard let data = try Keychain.read("giphy-api-key"), let key = String(data: data, encoding: .utf8), !key.isEmpty else {
                    error = "Add your GIPHY API key in Settings to browse online GIFs. You can import your own GIFs below."; results = []; loading = false; return
                }
                loading = true; error = ""
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                var url = URLComponents(string: "https://api.giphy.com/v1/gifs/\(trimmed.isEmpty ? "trending" : "search")")!
                url.queryItems = [URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "limit", value: "30"), URLQueryItem(name: "rating", value: "pg-13")]
                if !trimmed.isEmpty { url.queryItems?.append(URLQueryItem(name: "q", value: String(trimmed.prefix(50)))) }
                let body = try await BoundedHTTP.shared.data(from: url.url!, maximum: 2 * 1024 * 1024, mime: ["application/json"], api: true)
                try Task.checkCancellation()
                struct Response: Decodable { var data: [RemoteGIF] }
                let decoded = try JSONDecoder().decode(Response.self, from: body).data
                results = Array(decoded.filter {
                    guard let a = URL(string: $0.images.fixed_width.url), let b = URL(string: $0.images.original.url) else { return false }
                    return NetworkPolicy.allows(a) && NetworkPolicy.allows(b)
                }.prefix(30))
                loading = false
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                self.error = "GIF search failed. Check your connection and API key."; loading = false
            }
        }
    }
    func stop() { task?.cancel(); task = nil; loading = false }
    func download(_ gif: RemoteGIF, maximum: Int) async throws -> Clip {
        guard let url = URL(string: gif.images.original.url) else { throw SafetyError.insecureURL }
        if let size = gif.images.original.size.flatMap(Int.init), size < 0 || size > maximum { throw SafetyError.tooLarge }
        let data = try await BoundedHTTP.shared.data(from: url, maximum: maximum, mime: ["image/gif", "application/octet-stream"])
        guard MediaSafety.isGIF(data) else { throw SafetyError.invalidContent }
        return await Task.detached(priority: .userInitiated) { Clip(source: String(gif.title.prefix(512)), representations: [["com.compuserve.gif": data]]) }.value
    }
}

/// File I/O and cryptography run on FolderSync's serial worker; wire records only accept plain text.
enum SyncFiles {
    struct Wire: Codable { var version = 2; var id: UUID; var created: Date; var text: String }
    struct KDF: Codable { var algorithm = "pbkdf2-sha256"; var iterations: UInt32 = 600_000 }
    struct Entry { var url: URL; var modified: Date }
    static let marker = Data("Clipboard Sync v1".utf8)
    static func entries(_ directory: URL) throws -> [Entry] {
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { throw SafetyError.invalidFile }
        var entries: [Entry] = []
        var visited = 0
        for case let url as URL in iterator {
            visited += 1; if visited > 2000 { break }
            guard url.pathExtension == "clip", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            entries.append(Entry(url: url, modified: values.contentModificationDate ?? .distantPast))
        }
        return entries.sorted { $0.modified == $1.modified ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.modified < $1.modified }
    }
    static func decode(_ data: Data, name: String, key: SymmetricKey) throws -> Clip {
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        let wire: Wire
        if let decoded = try? JSONDecoder().decode(Wire.self, from: clear) { guard decoded.version == 2 else { throw SafetyError.invalidContent }; wire = decoded }
        else {
            let legacy = try JSONDecoder().decode(Clip.self, from: clear)
            guard legacy.representations.count == 1, legacy.representations[0].count == 1, legacy.hasText else { throw SafetyError.invalidContent }
            wire = Wire(id: legacy.id, created: legacy.created, text: legacy.text)
        }
        guard name == wire.id.uuidString + ".clip", !wire.text.isEmpty, wire.text.utf8.count <= 1024 * 1024,
              wire.created.timeIntervalSince1970.isFinite else { throw SafetyError.invalidContent }
        var clip = Clip.text(wire.text, source: "Synced text")
        clip.id = wire.id; clip.created = min(wire.created, Date()); return clip
    }
    static func receive(folder: URL, key: SymmetricKey, seen: Set<String>) throws -> (clips: [Clip], names: [String], invalid: Int) {
        var clips: [Clip] = [], names: [String] = []; var invalid = 0
        for entry in try entries(folder).suffix(250) where !seen.contains(entry.url.lastPathComponent) {
            do {
                let data = try SecureFiles.read(entry.url, maximum: 2 * 1024 * 1024)
                clips.append(try decode(data, name: entry.url.lastPathComponent, key: key)); names.append(entry.url.lastPathComponent)
            } catch { invalid += 1 } // A malformed neighbour must not block other valid records.
        }
        return (clips, names, invalid)
    }
    static func upload(_ clip: Clip, folder: URL, key: SymmetricKey) throws {
        guard clip.hasText, clip.textByteCount <= 1024 * 1024 else { throw SafetyError.tooLarge }
        let wire = Wire(id: clip.id, created: clip.created, text: clip.text)
        guard let data = try AES.GCM.seal(JSONEncoder().encode(wire), using: key).combined else { throw VaultError.invalidKey }
        try SecureFiles.write(data, to: folder.appendingPathComponent(clip.id.uuidString + ".clip"))
        for entry in try entries(folder).dropLast(250) {
            // Never remove unknown or malformed files merely because they share an extension.
            if let data = try? SecureFiles.read(entry.url, maximum: 2 * 1024 * 1024), (try? decode(data, name: entry.url.lastPathComponent, key: key)) != nil {
                try FileManager.default.removeItem(at: entry.url)
            }
        }
    }
    static func configure(_ folder: URL, phrase: String) throws -> (URL, SymmetricKey) {
        guard phrase.count >= 12, phrase.utf8.count <= 4096 else { throw SafetyError.invalidContent }
        let directory = folder.lastPathComponent == AppIdentity.syncFolderName ? folder : folder.appendingPathComponent(AppIdentity.syncFolderName, isDirectory: true)
        try SecureFiles.prepareDirectory(directory, privateAccess: false)
        let saltURL = directory.appendingPathComponent("salt")
        let salt: Data
        if SecureFiles.exists(saltURL) { salt = try SecureFiles.read(saltURL, maximum: 32) }
        else { salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }; try SecureFiles.write(salt, to: saltURL) }
        guard salt.count == 32 else { throw VaultError.invalidKey }
        let checkURL = directory.appendingPathComponent("verification")
        let kdfURL = directory.appendingPathComponent("kdf.json")
        let iterations: UInt32
        if SecureFiles.exists(kdfURL) {
            let config = try JSONDecoder().decode(KDF.self, from: SecureFiles.read(kdfURL, maximum: 1024))
            guard config.algorithm == "pbkdf2-sha256", (600_000...1_200_000).contains(config.iterations) else { throw SafetyError.invalidContent }
            iterations = config.iterations
        } else if SecureFiles.exists(checkURL) { iterations = 210_000 } // Existing 1.0 folders retain their original key.
        else { iterations = 600_000; try SecureFiles.write(JSONEncoder().encode(KDF()), to: kdfURL) }
        let derived = try derive(phrase, salt: salt, iterations: iterations)
        if SecureFiles.exists(checkURL) {
            let data = try SecureFiles.read(checkURL, maximum: 256)
            guard try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: derived) == marker else { throw VaultError.invalidKey }
        } else { try SecureFiles.write(AES.GCM.seal(marker, using: derived).combined!, to: checkURL) }
        return (directory, derived)
    }
    static func derive(_ phrase: String, salt: Data, iterations: UInt32 = 600_000) throws -> SymmetricKey {
        guard salt.count == 32, phrase.utf8.count <= 4096, (210_000...1_200_000).contains(iterations) else { throw SafetyError.invalidContent }
        var result = Data(count: 32)
        let password = Array(phrase.utf8)
        let status = result.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in password.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, output.bindMemory(to: UInt8.self).baseAddress, 32)
            } }
        }
        guard status == kCCSuccess else { throw VaultError.invalidKey }; return SymmetricKey(data: result)
    }
}

@MainActor
final class FolderSync {
    weak var store: ClipboardStore?
    private var timer: Timer?
    private(set) var key: SymmetricKey?
    private var seen: [String] = []
    private var receiving = false
    private var generation = 0
    private let queue = DispatchQueue(label: AppIdentity.bundleIdentifier + ".sync", qos: .utility)
    var folder: URL? { guard let path = store?.preferences.syncPath, !path.isEmpty else { return nil }; return URL(fileURLWithPath: path, isDirectory: true) }
    init(store: ClipboardStore) { self.store = store }
    static func derive(_ phrase: String, salt: Data) throws -> SymmetricKey { try SyncFiles.derive(phrase, salt: salt) }
    func configure(folder: URL, phrase: String) async throws {
        let before = generation
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, SymmetricKey), Error>) in
            queue.async { do { continuation.resume(returning: try SyncFiles.configure(folder, phrase: phrase)) } catch { continuation.resume(throwing: error) } }
        }
        guard generation == before else { throw CancellationError() }
        try Keychain.write(result.1.withUnsafeBytes { Data($0) }, account: "sync-key")
        generation += 1; key = result.1; seen = []
        store?.preferences.syncPath = result.0.path; store?.updatePreferences(); saveSeen(); receive()
    }
    func disconnect() {
        generation += 1; key = nil; receiving = false; seen = []
        store?.preferences.syncPath = ""; store?.preferences.automaticSync = false; store?.updatePreferences()
        UserDefaults.standard.removeObject(forKey: "syncSeen")
        do { try Keychain.delete("sync-key") } catch { store?.notice = "Sync disconnected, but its saved Keychain key could not be removed." }
    }
    func start() {
        if folder != nil, let data = try? Keychain.read("sync-key"), data.count == 32 { key = SymmetricKey(data: data) }
        seen = Array((UserDefaults.standard.stringArray(forKey: "syncSeen") ?? []).suffix(3000))
        timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.receive() } }
        timer?.tolerance = 3; receive()
    }
    func stop() { timer?.invalidate(); timer = nil; generation += 1 }
    func upload(_ clip: Clip) {
        guard let folder, let key, clip.hasText, clip.textByteCount <= 1024 * 1024 else { return }
        let generation = generation
        queue.async { [weak self] in
            do {
                try SyncFiles.upload(clip, folder: folder, key: key)
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    self.remember([clip.id.uuidString + ".clip"]); self.store?.notice = "Text shared to your sync folder."
                }
            } catch { DispatchQueue.main.async { if self?.generation == generation { self?.store?.notice = "Sync folder couldn't be written. Check that it's available." } } }
        }
    }
    func receive() {
        guard let folder, let key, let store, !store.isLoading, !store.suspended, !receiving else { return }
        receiving = true
        let generation = generation, seen = Set(seen)
        queue.async { [weak self] in
            do {
                let result = try autoreleasepool { try SyncFiles.receive(folder: folder, key: key, seen: seen) }
                DispatchQueue.main.async {
                    guard let self, self.generation == generation, let store = self.store else { return }
                    self.receiving = false
                    if !result.clips.isEmpty {
                        var history = store.clips
                        for clip in result.clips { history = HistoryRules.inserting(clip, into: history, count: store.preferences.historyLimit, bytes: store.preferences.storageLimitMB * 1024 * 1024) }
                        store.clips = history; store.saveSoon(); self.remember(result.names)
                    }
                    if result.invalid > 0 { store.notice = "Skipped \(result.invalid) invalid shared clipboard item(s)." }
                }
            } catch { DispatchQueue.main.async { if self?.generation == generation { self?.receiving = false; self?.store?.notice = "Sync is waiting for its folder or the correct sync key." } } }
        }
    }
    private func remember(_ names: [String]) { for name in names { seen.removeAll { $0 == name }; seen.append(name) }; seen = Array(seen.suffix(3000)); saveSeen() }
    private func saveSeen() { UserDefaults.standard.set(seen, forKey: "syncSeen") }
}
