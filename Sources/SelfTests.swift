import AppKit
import CryptoKit
import Darwin

@MainActor
enum SelfTests {
    static func run() {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            passed += 1; print("PASS: \(label)")
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardStore(testMode: true, pasteboard: board)
        board.clearContents()
        let boardAvailable = board.setString("first item", forType: .string) && board.string(forType: .string) == "first item"
        if boardAvailable {
            store.poll()
            let until = Date().addingTimeInterval(1)
            while store.clips.isEmpty && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            check(store.clips.first?.text == "first item", "Capture plain text from an isolated pasteboard")
        } else {
            print("SKIP: macOS pasteboard server is unavailable in this execution environment; live capture and paste integration require a normal app launch.")
            store.add(.text("first item"))
        }
        let first = store.clips[0]
        store.togglePin(first)
        store.add(.text("second item")); store.add(.text("first item"))
        check(store.clips.count == 2 && store.clips.first?.id == first.id && store.clips.first?.pinned == true, "Duplicate moves to front and preserves pin and ID")
        store.clearUnpinned()
        check(store.clips.count == 1 && store.clips[0].pinned, "Clear all preserves pinned history")
        for index in 0..<300 { store.add(.text("entry \(index)")) }
        check(store.clips.count == 250 && store.clips.contains { $0.id == first.id }, "250-item bound with pinned-item protection")
        let tiny = HistoryRules.limited([Clip.text(String(repeating: "a", count: 50)), Clip.text(String(repeating: "b", count: 50))], count: 250, bytes: 60)
        check(tiny.count == 1, "Storage byte budget evicts old unpinned entries")
        var pinned = Clip.text(String(repeating: "p", count: 100)); pinned.pinned = true
        let pinOverflow = HistoryRules.inserting(.text("new"), into: [pinned], count: 25, bytes: 50)
        check(pinOverflow.count == 1 && pinOverflow[0].pinned, "Full pinned budget skips new items without deleting pins")
        check(HistoryRules.isSensitive(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]), "Concealed clipboard markers are excluded")
        check(!HistoryRules.isSensitive(["public.utf8-plain-text", "com.apple.is-remote-clipboard"]), "Universal Clipboard is not mistaken for concealed content")
        let sensitive = NSPasteboardItem(); sensitive.setString("secret", forType: .string); sensitive.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.clearContents(); board.writeObjects([sensitive]); let oldCount = store.clips.count; store.poll()
        if boardAvailable { check(store.clips.count == oldCount && !store.clips.contains { $0.text == "secret" }, "Concealed content is not captured") }
        store.preferences.captureEnabled = false
        board.clearContents(); board.setString("paused content", forType: .string); store.poll()
        if boardAvailable { check(!store.clips.contains { $0.text == "paused content" }, "Pause suppresses recording") }
        store.preferences.captureEnabled = true
        let rich = Clip(source: "Test", representations: [["public.utf8-plain-text": Data("styled text".utf8), "public.html": Data("<b>styled text</b>".utf8), "public.rtf": Data("{\\rtf1 styled text}".utf8)]])
        store.writeToPasteboard(rich)
        if boardAvailable { check(board.string(forType: .html) == "<b>styled text</b>" && board.string(forType: .string) == "styled text", "Rich paste restores both HTML and plain text") }
        store.writeToPasteboard(rich, plain: true)
        if boardAvailable { check(board.string(forType: .string) == "styled text" && board.data(forType: .html) == nil, "Plain-text paste removes formatting") }
        let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = pixel.representation(using: .png, properties: [:])!
        let imageClip = Clip(representations: [["public.png": image]])
        store.writeToPasteboard(imageClip)
        check(imageClip.imageData == image, "Original PNG bytes are retained in history")
        if boardAvailable { check(board.data(forType: .png) == image, "PNG paste restores original bytes") }
        let multi = Clip(representations: [["public.file-url": Data("file:///tmp/a.txt".utf8)], ["public.file-url": Data("file:///tmp/b.txt".utf8)]])
        store.writeToPasteboard(multi)
        check(multi.fileURLs.count == 2, "Multi-file history preserves both file URLs")
        if boardAvailable { check(board.pasteboardItems?.count == 2, "Multi-file pasteboard items retain their boundaries") }
        let beforeWrite = store.clips.count; store.poll()
        if boardAvailable { check(store.clips.count == beforeWrite, "App's own pasteboard writes do not feed back into history") }
        store.preferences.itemLimitMB = 4
        let beforeLarge = store.clips.count; store.add(.text(String(repeating: "x", count: 4 * 1024 * 1024 + 1)))
        check(store.clips.count == beforeLarge, "Oversize items are rejected before storage")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let key = SymmetricKey(size: .bits256)
            let vault = try Vault(directory: folder, key: key)
            try vault.write(Archive(clips: [rich, imageClip, multi, pinned], boot: "test"))
            let loaded = try vault.load()!
            check(loaded.clips == [rich, imageClip, multi, pinned], "Encrypted history round trip preserves metadata and all formats")
            let disk = try Data(contentsOf: folder.appendingPathComponent("history.index"))
            check(disk.range(of: Data("styled text".utf8)) == nil, "History is not stored as plaintext")
            var tampered = disk; tampered[tampered.count - 1] ^= 1
            try tampered.write(to: folder.appendingPathComponent("history.index"))
            do { _ = try vault.load(); check(false, "Tamper detection") } catch { check(true, "Tampered history fails authentication") }
            try disk.write(to: folder.appendingPathComponent("history.index"))
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "clipdata" }
            var savedBlobs: [String: Data] = [:]
            for file in files { savedBlobs[file.lastPathComponent] = try Data(contentsOf: file) }
            var changed = rich; changed.pinned = true
            try vault.write(Archive(clips: [changed, imageClip, multi, pinned], boot: ""))
            let unchanged = try files.allSatisfy { try Data(contentsOf: $0) == savedBlobs[$0.lastPathComponent] }
            check(unchanged, "Pinning only rewrites the small index, not payload ciphertext")
            try vault.write(Archive(clips: [rich], boot: ""), collection: .gifs)
            try vault.write(Archive(clips: [], boot: ""))
            let retained = try vault.load(.gifs)?.clips
            check(retained == [rich], "History cleanup preserves payloads referenced by the other library")
            try vault.write(Archive(clips: [], boot: ""), collection: .gifs)
            let afterDelete = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            check(!afterDelete.contains { $0.pathExtension == "clipdata" }, "Deleted and orphaned payloads are removed from encrypted storage")
            let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("history.index").path)[.posixPermissions] as? NSNumber
            check(mode?.intValue == 0o600, "Encrypted files are created with owner-only permissions")
            let privateMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
            check(privateMode?.intValue == 0o700, "The private vault directory is owner-only")
            let legacy = folder.appendingPathComponent("legacy")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            let old = try AES.GCM.seal(JSONEncoder().encode(Archive(clips: [rich, pinned], boot: "old")), using: key).combined!
            try old.write(to: legacy.appendingPathComponent("history.encrypted"))
            let migrated = try Vault(directory: legacy, key: key)
            let oldArchive = try migrated.load()!
            check(oldArchive.clips == [rich, pinned], "The previous encrypted history format loads without losing pins or formats")
            try migrated.write(oldArchive)
            let reread = try migrated.load()?.clips
            check(!SecureFiles.exists(legacy.appendingPathComponent("history.encrypted")) && reread == [rich, pinned], "Migration commits the new index before retiring the legacy file")
            let otherIndex = try Data(contentsOf: folder.appendingPathComponent("gifs.index"))
            try otherIndex.write(to: folder.appendingPathComponent("history.index"))
            do { _ = try vault.load(); check(false, "Cross-library authentication") } catch { check(true, "Authenticated context rejects a swapped index from another library") }
            let target = folder.appendingPathComponent("target")
            try Data("unchanged".utf8).write(to: target)
            let link = folder.appendingPathComponent("symlink")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            do { _ = try SecureFiles.read(link, maximum: 100); check(false, "Symlink read") } catch { check(true, "Bounded file reads reject symbolic links") }
            try SecureFiles.write(Data("replacement".utf8), to: link)
            let targetText = try String(contentsOf: target, encoding: .utf8)
            check(targetText == "unchanged", "Atomic writes replace a symlink rather than overwriting its target")
            do { _ = try SecureFiles.read(target, maximum: 2); check(false, "File size bound") } catch { check(true, "File length is bounded before allocating the payload") }
            let fifo = folder.appendingPathComponent("fifo")
            guard mkfifo(fifo.path, 0o600) == 0 else { throw SafetyError.invalidFile }
            do { _ = try SecureFiles.read(fifo, maximum: 100); check(false, "Special file read") } catch { check(true, "Special files are rejected without blocking") }
            let a = try FolderSync.derive("test shared passphrase", salt: Data(repeating: 42, count: 32))
            let b = try FolderSync.derive("test shared passphrase", salt: Data(repeating: 42, count: 32))
            let sealed = try AES.GCM.seal(Data("shared text".utf8), using: a)
            let opened = try AES.GCM.open(sealed, using: b)
            check(opened == Data("shared text".utf8), "Shared sync passphrase derives compatible encryption keys")
            let configured = try SyncFiles.configure(folder.appendingPathComponent("new-sync"), phrase: "new shared passphrase")
            let kdf = try JSONDecoder().decode(SyncFiles.KDF.self, from: SecureFiles.read(configured.0.appendingPathComponent("kdf.json"), maximum: 1024))
            check(kdf.iterations == 600_000, "New sync folders use 600,000 PBKDF2-HMAC-SHA256 rounds")
            let oldParent = folder.appendingPathComponent("old-sync")
            let oldShared = oldParent.appendingPathComponent("Clipboard Sync")
            try SecureFiles.prepareDirectory(oldShared, privateAccess: false)
            let oldSalt = Data(repeating: 12, count: 32)
            let oldKey = try SyncFiles.derive("old shared passphrase", salt: oldSalt, iterations: 210_000)
            try SecureFiles.write(oldSalt, to: oldShared.appendingPathComponent("salt"))
            try SecureFiles.write(AES.GCM.seal(SyncFiles.marker, using: oldKey).combined!, to: oldShared.appendingPathComponent("verification"))
            let rejoined = try SyncFiles.configure(oldParent, phrase: "old shared passphrase")
            let compatibility = try AES.GCM.open(AES.GCM.seal(Data("compatibility".utf8), using: oldKey), using: rejoined.1)
            check(compatibility == Data("compatibility".utf8), "Existing 210,000-round sync folders remain compatible")
            try SecureFiles.write(Data("{\"algorithm\":\"pbkdf2-sha256\",\"iterations\":4000000000}".utf8), to: configured.0.appendingPathComponent("kdf.json"))
            do { _ = try SyncFiles.configure(configured.0, phrase: "new shared passphrase"); check(false, "KDF work factor bound") } catch { check(true, "An untrusted KDF profile cannot request unbounded CPU work") }
            let shared = folder.appendingPathComponent("shared")
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            let good = Clip.text("valid shared text")
            try SyncFiles.upload(good, folder: shared, key: a)
            try Data("invalid ciphertext".utf8).write(to: shared.appendingPathComponent(UUID().uuidString + ".clip"))
            let received = try SyncFiles.receive(folder: shared, key: b, seen: [])
            check(received.clips.count == 1 && received.clips[0].text == good.text && received.invalid == 1, "A corrupt sync record does not block a valid neighbour")
            let one = try Data(contentsOf: shared.appendingPathComponent(good.id.uuidString + ".clip"))
            do { _ = try SyncFiles.decode(one, name: UUID().uuidString + ".clip", key: a); check(false, "Sync filename binding") } catch { check(true, "A shared record cannot impersonate a different file ID") }
            var remote = Clip.text("legacy plain text"); remote.pinned = true; remote.source = "spoofed source"
            let remoteData = try AES.GCM.seal(JSONEncoder().encode(remote), using: a).combined!
            let sanitized = try SyncFiles.decode(remoteData, name: remote.id.uuidString + ".clip", key: a)
            check(!sanitized.pinned && sanitized.source == "Synced text", "Remote metadata cannot inject local pins or source attribution")
            let imageWire = try AES.GCM.seal(JSONEncoder().encode(imageClip), using: a).combined!
            do { _ = try SyncFiles.decode(imageWire, name: imageClip.id.uuidString + ".clip", key: a); check(false, "Sync text-only boundary") } catch { check(true, "Text sync rejects image and non-text payload injection") }
                } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        let shapeA = Clip(representations: [["public.utf8-plain-text": Data("a".utf8)], ["public.html": Data("b".utf8)]])
        let shapeB = Clip(representations: [["public.utf8-plain-text": Data("a".utf8), "public.html": Data("b".utf8)]])
        check(shapeA.digest != shapeB.digest, "Content fingerprints include item and representation boundaries")
        let shapeC = Clip(representations: [["public.html": Data("b".utf8), "public.utf8-plain-text": Data("a".utf8)]])
        check(shapeB.digest == shapeC.digest, "Fingerprinting is independent of dictionary insertion order")
        do {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shapeB)) as! [String: Any]
            object["contentHash"] = "untrusted cached fingerprint"
            let decoded = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: object))
            check(decoded.digest == shapeB.digest, "Serialized legacy hash caches cannot override the actual payload fingerprint")
        } catch { fputs("FAIL: fingerprint decoding\n", stderr); exit(1) }
        check(NetworkPolicy.allows(URL(string: "https://media.giphy.com/media/example/giphy.gif")!), "HTTPS GIPHY media hosts are allowed")
        check(!NetworkPolicy.allows(URL(string: "https://evilgiphy.com/a.gif")!), "Lookalike GIPHY host suffixes are rejected")
        check(!NetworkPolicy.allows(URL(string: "https://giphy.com.evil.example/a.gif")!), "A GIPHY prefix on an unrelated domain is rejected")
        check(!NetworkPolicy.allows(URL(string: "http://media.giphy.com/a.gif")!), "Plain HTTP is rejected")
        check(!NetworkPolicy.allows(URL(string: "https://user:secret@media.giphy.com/a.gif")!), "Embedded URL credentials are rejected")
        check(!NetworkPolicy.allows(URL(string: "https://media.giphy.com:444/a.gif")!), "Unexpected destination ports are rejected")
        check(!NetworkPolicy.allows(URL(string: "https://media.giphy.com/a")!, api: true), "API credentials are restricted to the exact API host")
        check(PastePolicy.canSend(expectedChange: 4, actualChange: 4, expectedPID: 100, activePID: 100, secureInput: false, modifiersReleased: true), "Paste can proceed only for the intended unchanged destination")
        check(!PastePolicy.canSend(expectedChange: 4, actualChange: 5, expectedPID: 100, activePID: 100, secureInput: false, modifiersReleased: true), "An intervening copy cancels automatic paste")
        check(!PastePolicy.canSend(expectedChange: 4, actualChange: 4, expectedPID: 100, activePID: 200, secureInput: false, modifiersReleased: true), "A different frontmost app cannot receive a delayed paste")
        check(!PastePolicy.canSend(expectedChange: 4, actualChange: 4, expectedPID: 100, activePID: 100, secureInput: true, modifiersReleased: true), "Secure keyboard input blocks automatic paste")
        check(!PastePolicy.canSend(expectedChange: 4, actualChange: 4, expectedPID: 100, activePID: 100, secureInput: false, modifiersReleased: false), "Held modifiers block synthesized paste")
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875), size = NSSize(width: 352, height: 500)
        let saved = SavedPosition(x: 200, y: 150, screen: 1)
        check(PositionRules.restored(saved, visibleAreas: [screen], preferredArea: screen, size: size) == NSPoint(x: 200, y: 150), "A visible dragged panel position is restored exactly")
        let lost = PositionRules.restored(SavedPosition(x: 4000, y: -3000, screen: 2), visibleAreas: [screen], preferredArea: screen, size: size)
        check(screen.contains(NSRect(origin: lost, size: size)), "Disconnected monitors cannot strand the remembered panel off-screen")
        let negative = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
        check(PositionRules.restored(SavedPosition(x: -1500, y: 0, screen: 2), visibleAreas: [negative, screen], preferredArea: screen, size: size).x == -1500, "Negative-coordinate monitor positions are preserved")
        let invalidPosition = PositionRules.restored(SavedPosition(x: .nan, y: .infinity, screen: 0), visibleAreas: [screen], preferredArea: screen, size: size)
        check(invalidPosition.x.isFinite && invalidPosition.y.isFinite, "Invalid persisted window coordinates recover safely")
        var invalidPreferences = Preferences(); invalidPreferences.historyLimit = .max; invalidPreferences.storageLimitMB = .min; invalidPreferences.itemLimitMB = .max; invalidPreferences.normalize()
        check(invalidPreferences.historyLimit == 5000 && invalidPreferences.storageLimitMB == 64 && invalidPreferences.itemLimitMB == 128, "Persisted limits are normalized before size arithmetic")
        do { _ = try Clip.validated(representations: [["unknown.private.type": Data([1])]], maximum: 100); check(false, "Unexpected representation type") } catch { check(true, "Unexpected serialized representation types are rejected") }
        do { _ = try Clip.validated(representations: [["public.utf8-plain-text": Data(repeating: 1, count: 101)]], maximum: 100); check(false, "Decoded item size") } catch { check(true, "Decoded payloads must fit the hard per-item boundary") }
        check(!MediaSafety.isGIF(Data("not really a gif".utf8)), "GIF file extensions cannot bypass media validation")
        check(NetworkTests.run(), "Bounded HTTP rejects large headers, chunked overflow, wrong MIME, HTTP errors and cancellation (mock transport)")
        check(CharacterCatalog.emoji.count >= 30, "Emoji catalogue loads")
        check(CharacterCatalog.symbols.count > 400, "Searchable symbol catalogue loads")
        check(Set(CharacterCatalog.kaomoji.map(\.id)).count == CharacterCatalog.kaomoji.count, "Kaomoji grid has stable unique identities")
        check(Shortcut().label == "⇧⌘V", "Default shortcut is Command-Shift-V")
        store.clearEverything()
        check(store.clips.isEmpty, "Full erase clears all history, including pins")
        if boardAvailable { check(board.pasteboardItems?.isEmpty != false, "Full erase clears its pasteboard") }
        print("\(passed) checks passed. General system clipboard was not modified.")
    }
}
