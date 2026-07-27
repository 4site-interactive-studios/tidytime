import Foundation
import TidyCore

/// Receives the OAuth redirect on `http://127.0.0.1:<port>`.
///
/// Deliberately the smallest possible HTTP server: accept one connection, read the request line,
/// reply with a short page, hand back the query string, close.
///
/// **Implemented on BSD sockets, not Network framework.** `NWListener` fails with `EINVAL` here —
/// verified both with and without `requiredInterfaceType = .loopback` — while a plain socket bound to
/// `127.0.0.1` works. Sockets also make the security property *explicit* rather than declarative: we
/// bind `INADDR_LOOPBACK`, so the port is unreachable from off-box by construction.
public final class LoopbackReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    // CONCURRENT on purpose: the blocking `accept()` below occupies one slot, and the timeout block
    // must still be able to run and close the fd to unblock it. On a serial queue the timeout would
    // be enqueued *behind* accept() and could never fire — a deadlock (observed as a hung test).
    private let queue = DispatchQueue(label: "com.4site.TidyTime.oauth-loopback", attributes: .concurrent)

    public init() {}

    /// The ephemeral port actually bound (Google's loopback flow permits any port).
    public private(set) var port: UInt16 = 0

    /// Bind + listen. Returns the `redirect_uri` to hand to Google.
    public func start() throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TidyError.ingest("socket() failed: \(Self.errnoText())") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                        // kernel picks an ephemeral port
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian     // 127.0.0.1 — loopback ONLY
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw TidyError.ingest("could not bind a loopback port for the OAuth redirect: \(Self.errnoText())")
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw TidyError.ingest("listen() failed: \(Self.errnoText())")
        }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        lock.lock(); listenFD = fd; lock.unlock()
        port = UInt16(bigEndian: actual.sin_port)
        return "http://127.0.0.1:\(port)"
    }

    /// Wait for the browser redirect and return its query string. Times out so a user who abandons
    /// the browser can't hang the app forever.
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> String {
        let fd = lock.withLock { listenFD }   // NSLock.lock() is unavailable in async contexts
        guard fd >= 0 else { throw TidyError.ingest("loopback receiver not started") }

        let once = OnceResume { [weak self] in self?.stop() }
        return try await withCheckedThrowingContinuation { continuation in
            once.attach(continuation)

            // Closing the listening fd makes the blocking accept() below return — that's how the
            // timeout unblocks it.
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                once.finish(.failure(TidyError.ingest("OAuth sign-in timed out after \(Int(timeout))s")))
                self?.stop()
            }

            queue.async {
                // Accept in a LOOP: browsers open speculative "preconnect" sockets that carry no
                // data, and treating the first such connection as the callback failed the whole
                // sign-in (round-3 R1-C5). Skip anything that isn't a GET; the timeout still
                // bounds the whole wait because stop() closes the listening fd.
                var client: Int32 = -1
                var text = ""
                while true {
                    client = accept(fd, nil, nil)
                    guard client >= 0 else {
                        once.finish(.failure(TidyError.ingest("accept() failed: \(Self.errnoText())")))
                        return
                    }
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let n = read(client, &buffer, buffer.count)
                    if n > 0, let request = String(bytes: buffer[0..<n], encoding: .utf8),
                       request.hasPrefix("GET ") {
                        text = request
                        break
                    }
                    close(client)   // preconnect or junk — wait for the real redirect
                }
                defer { close(client) }

                // Request line: "GET /?code=…&state=… HTTP/1.1"
                let target = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let query = target.contains("?")
                    ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""

                let body = """
                    <!doctype html><meta charset="utf-8"><title>TidyTime</title>
                    <body style="font:15px -apple-system,system-ui;padding:3rem;max-width:32rem">
                    <h2>Signed in.</h2><p>You can close this tab and return to TidyTime.</p>
                    """
                // Built by joining lines rather than `+`-concatenating interpolated strings: the
                // latter is a known Swift type-checker blowup (it turned a 0.1s build into minutes).
                let length: Int = body.utf8.count
                var lines: [String] = []
                lines.append("HTTP/1.1 200 OK")
                lines.append("Content-Type: text/html; charset=utf-8")
                lines.append("Content-Length: \(length)")
                lines.append("Connection: close")
                lines.append("")
                lines.append(body)
                let response: String = lines.joined(separator: "\r\n")
                _ = response.withCString { write(client, $0, strlen($0)) }

                once.finish(.success(query))
            }
        }
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            // shutdown() BEFORE close(): on macOS, close() alone does not reliably wake a thread
            // blocked in accept() on this fd — the thread (and the whole test process) can hang
            // forever. A 13-hour hung xctest holding the SwiftPM lock traced back to exactly this.
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    fileprivate static func errnoText() -> String {
        "errno \(errno) (\(String(cString: strerror(errno))))"
    }
}

/// Resumes a continuation exactly once — the callback, a read error, and the timeout all race, and a
/// racer can even win before the continuation is attached.
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var continuation: CheckedContinuation<String, Error>?
    private var pending: Result<String, Error>?
    private let onFinish: @Sendable () -> Void

    init(onFinish: @escaping @Sendable () -> Void) { self.onFinish = onFinish }

    func attach(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        if let pending, !done {
            done = true
            lock.unlock()
            continuation.resume(with: pending)
            onFinish()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        guard let continuation else {
            pending = result          // arrived before attach — stash it
            lock.unlock()
            return
        }
        done = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        onFinish()
    }
}
