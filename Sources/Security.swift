import Foundation
import Darwin
import ImageIO
import AppKit

enum SafetyError: LocalizedError {
    case invalidFile, tooLarge, invalidContent, invalidResponse, insecureURL
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "The file is not a safe, regular file."
        case .tooLarge: return "The item exceeds the allowed size."
        case .invalidContent: return "The item has an unsupported or invalid format."
        case .invalidResponse: return "The service returned an invalid response."
        case .insecureURL: return "The service returned an untrusted URL."
        }
    }
}

/// NSCache synchronizes its accessors. Values must be immutable while cached; limits are eviction targets.
final class SharedCache<Key: AnyObject, Value: AnyObject>: @unchecked Sendable {
    private let storage = NSCache<Key, Value>()
    init(cost: Int, count: Int) { storage.totalCostLimit = cost; storage.countLimit = count }
    func object(forKey key: Key) -> Value? { storage.object(forKey: key) }
    func setObject(_ object: Value, forKey key: Key, cost: Int) { storage.setObject(object, forKey: key, cost: cost) }
    func removeAllObjects() { storage.removeAllObjects() }
}

enum SecureFiles {
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw SafetyError.invalidFile }
        guard maximum >= 0, info.st_size >= 0, info.st_size <= maximum else { throw SafetyError.tooLarge }
        var data = Data(); data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
            if count == 0 { return data }
            guard count <= maximum - data.count else { throw SafetyError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    static func prepareDirectory(_ directory: URL, privateAccess: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: privateAccess ? 0o700 : 0o755])
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw SafetyError.invalidFile }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else { throw SafetyError.invalidFile }
        if privateAccess, fchmod(fd, 0o700) != 0 { throw POSIXError(.EACCES) }
    }
    static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let directory = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw SafetyError.invalidFile }
        defer { Darwin.close(directory) }
        let temporary = ".\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, url.lastPathComponent) == 0 else { throw POSIXError(.EIO) }
    }
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

enum MediaSafety {
    static func properties(_ data: Data) -> (source: CGImageSource, width: Int, height: Int, frames: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= 40_000_000 / height else { return nil }
        var canvasWidth = width, canvasHeight = height
        if data.count >= 10, data.starts(with: Data("GIF8".utf8)) {
            canvasWidth = max(width, Int(data[data.startIndex + 6]) | Int(data[data.startIndex + 7]) << 8)
            canvasHeight = max(height, Int(data[data.startIndex + 8]) | Int(data[data.startIndex + 9]) << 8)
            guard canvasWidth <= 16_384, canvasHeight <= 16_384, canvasWidth <= 40_000_000 / canvasHeight else { return nil }
        }
        return (source, canvasWidth, canvasHeight, CGImageSourceGetCount(source))
    }
    static func isGIF(_ data: Data) -> Bool {
        guard data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) else { return false }
        return properties(data) != nil
    }
    static func thumbnail(_ data: Data) -> CGImage? {
        guard let info = properties(data) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(info.source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 560, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    static func canAnimate(_ data: Data) -> Bool {
        guard let info = properties(data), info.width <= 1024, info.height <= 1024, info.frames <= 120 else { return false }
        return info.width * info.height <= (16 * 1024 * 1024) / 4 / max(1, info.frames)
    }
}

/// Serialize image decoding so several visible compressed images cannot inflate simultaneously.
actor MediaPreparer {
    static let shared = MediaPreparer()
    func thumbnail(_ data: Data) -> CGImage? { Task.isCancelled ? nil : MediaSafety.thumbnail(data) }
    func canAnimate(_ data: Data) -> Bool { !Task.isCancelled && MediaSafety.canAnimate(data) }
}

enum PreviewCache {
    static let images = SharedCache<NSString, NSImage>(cost: 32 * 1024 * 1024, count: 250)
    static func purge() { images.removeAllObjects() }
}

enum NetworkPolicy {
    static func allows(_ url: URL, api: Bool = false) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return api ? host == "api.giphy.com" : host == "giphy.com" || host.hasSuffix(".giphy.com")
    }
}

/// One ephemeral session, a bounded body per request, and no redirects, cookies, credentials or disk cache.
final class BoundedHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BoundedHTTP()
    private final class Request: @unchecked Sendable {
        let lock = NSLock()
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Data, Error>?
        var buffer = Data()
        var failure: Error?
        var cancelled = false
        let maximum: Int
        let mime: Set<String>
        init(maximum: Int, mime: Set<String>) { self.maximum = maximum; self.mime = mime }
    }
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var requests: [Int: Request] = [:]
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }
    private lazy var session: URLSession = {
        let configuration = self.configuration
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 45
        configuration.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()
    func data(from url: URL, maximum: Int, mime: Set<String>, api: Bool = false) async throws -> Data {
        guard NetworkPolicy.allows(url, api: api), maximum > 0 else { throw SafetyError.insecureURL }
        let context = Request(maximum: maximum, mime: mime)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                context.lock.lock()
                if context.cancelled { context.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                let task: URLSessionDataTask = lock.withLock {
                    let task = session.dataTask(with: URLRequest(url: url))
                    requests[task.taskIdentifier] = context
                    return task
                }
                context.continuation = continuation; context.task = task
                context.lock.unlock(); task.resume()
            }
        } onCancel: {
            context.lock.lock(); context.cancelled = true; let task = context.task; context.lock.unlock()
            task?.cancel()
        }
    }
    private func context(_ task: URLSessionTask) -> Request? { lock.withLock { requests[task.taskIdentifier] } }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let context = context(dataTask) else { completionHandler(.cancel); return }
        let valid = (response as? HTTPURLResponse)?.statusCode == 200 && (response.expectedContentLength < 0 || response.expectedContentLength <= context.maximum) && context.mime.contains(response.mimeType?.lowercased() ?? "")
        if !valid { context.failure = response.expectedContentLength > context.maximum ? SafetyError.tooLarge : SafetyError.invalidResponse }
        completionHandler(valid ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let context = context(dataTask) else { return }
        if data.count > context.maximum - context.buffer.count { context.failure = SafetyError.tooLarge; dataTask.cancel(); return }
        context.buffer.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let context = lock.withLock({ requests.removeValue(forKey: task.taskIdentifier) }) else { return }
        context.lock.lock(); let continuation = context.continuation; context.continuation = nil; let cancelled = context.cancelled; context.lock.unlock()
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else if let failure = context.failure { continuation?.resume(throwing: failure) }
        else if let error { continuation?.resume(throwing: error) }
        else if context.buffer.isEmpty { continuation?.resume(throwing: SafetyError.invalidResponse) }
        else { continuation?.resume(returning: context.buffer) }
    }
}

enum PastePolicy {
    static func canSend(expectedChange: Int, actualChange: Int, expectedPID: pid_t, activePID: pid_t?, secureInput: Bool, modifiersReleased: Bool) -> Bool {
        expectedChange == actualChange && activePID == expectedPID && !secureInput && modifiersReleased
    }
}

struct SavedPosition: Codable { var x: Double; var y: Double; var screen: UInt32 }

enum PositionRules {
    static func clamped(_ origin: NSPoint, area: NSRect, size: NSSize) -> NSPoint {
        let x = origin.x.isFinite ? origin.x : area.midX - size.width / 2
        let y = origin.y.isFinite ? origin.y : area.midY - size.height / 2
        return NSPoint(x: min(max(area.minX + 8, x), max(area.minX, area.maxX - size.width - 8)), y: min(max(area.minY + 8, y), max(area.minY, area.maxY - size.height - 8)))
    }
    static func restored(_ saved: SavedPosition, visibleAreas: [NSRect], preferredArea: NSRect, size: NSSize) -> NSPoint {
        let origin = NSPoint(x: saved.x, y: saved.y)
        guard saved.x.isFinite, saved.y.isFinite else { return clamped(origin, area: preferredArea, size: size) }
        let frame = NSRect(origin: origin, size: size)
        let area = visibleAreas.max { a, b in
            let x = frame.intersection(a), y = frame.intersection(b)
            return max(0, x.width) * max(0, x.height) < max(0, y.width) * max(0, y.height)
        }
        let chosen = area.flatMap { frame.intersects($0) ? $0 : nil } ?? preferredArea
        return clamped(origin, area: chosen, size: size)
    }
}

extension Notification.Name { static let clipboardShortcutRecording = Notification.Name("ClipboardShortcutRecording") }
