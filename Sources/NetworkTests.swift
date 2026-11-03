import Foundation

/// Synthetic URLProtocol responses only. No API key, DNS request, or external connection is used.
final class TestHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.giphy.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let headers = ["Content-Type": path == "/wrong-mime" ? "text/html" : "application/json", "Content-Length": path == "/large-header" ? "1000" : path == "/chunked" ? "-1" : "4"]
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "/error" ? 403 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/chunked" {
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 5))
            client?.urlProtocol(self, didLoad: Data(repeating: 2, count: 5))
        } else { client?.urlProtocol(self, didLoad: Data("test".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum NetworkTests {
    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func complete() { lock.withLock { value = true } }
        func read() -> Bool { lock.withLock { value } }
    }
    static func run() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Result()
        Task.detached {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TestHTTPProtocol.self]
            let client = BoundedHTTP(configuration: configuration)
            do {
                let body = try await client.data(from: URL(string: "https://api.giphy.com/ok")!, maximum: 8, mime: ["application/json"], api: true)
                guard body == Data("test".utf8) else { semaphore.signal(); return }
                for path in ["large-header", "chunked", "wrong-mime", "error"] {
                    do { _ = try await client.data(from: URL(string: "https://api.giphy.com/\(path)")!, maximum: 8, mime: ["application/json"], api: true); semaphore.signal(); return }
                    catch { /* Rejection is required. */ }
                }
                let cancelled = Task { try await client.data(from: URL(string: "https://api.giphy.com/ok")!, maximum: 8, mime: ["application/json"], api: true) }
                cancelled.cancel()
                do { _ = try await cancelled.value; semaphore.signal(); return } catch { }
                result.complete()
            } catch { }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else { return false }
        return result.read()
    }
}
