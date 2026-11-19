//
//  WebUIServer.swift
//  Art-Net Monitor
//
//  The other half of what artnet-monitor.js did: an HTTP + Server-Sent Events
//  endpoint on port 6455 that the Art-Net drawer in index.html connects to.
//  The message shapes here must match the sidecar exactly, because the drawer's
//  JavaScript is unchanged:
//
//      hello  { type, artnetPort, fps, host, interfaces[] }
//      dmx    { type, from, universe, net, subnet, uni, seq, len, channels[512] }
//      stats  { type, pkts, dmxPkts, pps, universes, clients }
//      other  { type, op, from }
//      gone   { type, from, universe }
//
//  Like the sidecar, universes are pushed at a fixed frame rate rather than per
//  packet, and only when something actually changed.
//

import Foundation

nonisolated final class WebUIServer: @unchecked Sendable {

    static let defaultPort: UInt16 = 6455
    /// Push rate for dmx frames, matching the sidecar's --fps default.
    static let framesPerSecond = 20

    private let engine: CaptureEngine
    private let port: UInt16
    private let stateBox = StateBox()
    private let stopFlag = FlagBox()

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clients: [Int32] = []
    /// Last values we pushed, so we only send universes that changed.
    private var lastSent: [String: (values: [UInt8], sequence: Int)] = [:]
    private var lastTotalPackets = 0
    private var lastStatsTime = monotonicNow()
    /// The index.html to serve at "/", already read into memory. We never touch
    /// the disk on a request thread: the file usually lives in iCloud/Dropbox,
    /// where a cold read can block on a privacy prompt and wedge the response.
    private var indexData: Data?
    private var indexName: String?

    var state: CaptureState { stateBox.state }

    var clientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return clients.count
    }

    init(engine: CaptureEngine, port: UInt16 = WebUIServer.defaultPort) {
        self.engine = engine
        self.port = port
    }

    /// Hands the server the page bytes (read by the store, which owns the
    /// security-scoped access), or nil to serve the built-in placeholder.
    func setIndexHTML(_ data: Data?, name: String?) {
        lock.lock()
        indexData = data
        indexName = name
        lock.unlock()
    }

    // MARK: - Lifecycle

    func start() {
        guard !state.isActive else { return }
        stopFlag.clear()
        stateBox.set(.starting)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fail("Could not create the web server socket: \(errnoText())")
            return
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let message = errnoText()
            close(fd)
            fail("Could not bind tcp \(port): \(message)")
            return
        }
        guard listen(fd, 16) == 0 else {
            let message = errnoText()
            close(fd)
            fail("Could not listen on tcp \(port): \(message)")
            return
        }

        lock.lock(); listenFD = fd; lock.unlock()
        stateBox.set(.running)
        engine.log("web UI: serving on http://0.0.0.0:\(port) "
                   + "(point the drawer at http://<this mac>:\(port))")

        let accepter = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        accepter.name = "artnet.web.accept"
        accepter.stackSize = 512 * 1024
        accepter.start()

        let pusher = Thread { [weak self] in self?.pushLoop() }
        pusher.name = "artnet.web.push"
        pusher.stackSize = 1024 * 1024
        pusher.start()
    }

    func stop() {
        stopFlag.set()
        lock.lock()
        let fd = listenFD
        let open = clients
        listenFD = -1
        clients = []
        lastSent = [:]
        lock.unlock()

        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        for client in open { shutdown(client, SHUT_RDWR); close(client) }
        if state.isActive { stateBox.set(.idle) }
    }

    private func fail(_ message: String) {
        stateBox.set(.failed(message))
        engine.log("web UI: \(message)")
    }

    private func errnoText() -> String { String(cString: strerror(errno)) }

    // MARK: - Accepting

    private func acceptLoop(fd: Int32) {
        while !stopFlag.isSet {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 500)
            if ready < 0 { if errno == EINTR { continue }; break }
            guard ready > 0 else { continue }

            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            var one: Int32 = 1
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            // Don't let a stalled browser wedge the push loop.
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))

            let worker = Thread { [weak self] in self?.handle(client: client) }
            worker.name = "artnet.web.client"
            worker.stackSize = 512 * 1024
            worker.start()
        }
    }

    private func handle(client: Int32) {
        guard let request = readRequestLine(client) else { close(client); return }
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let route = path.split(separator: "?").first.map(String.init) ?? "/"

        if request.hasPrefix("OPTIONS") {
            send(client, "HTTP/1.1 204 No Content\r\n" + corsHeaders + "\r\n")
            close(client)
            return
        }

        switch route {
        case "/events":
            startEventStream(client)
        case "/health":
            serveHealth(client)
        case "/", "/index.html":
            serveIndex(client)
        default:
            send(client, "HTTP/1.1 404 Not Found\r\n" + corsHeaders
                 + "Content-Length: 9\r\n\r\nnot found")
            close(client)
        }
    }

    private let corsHeaders =
        "Access-Control-Allow-Origin: *\r\n"
        + "Access-Control-Allow-Headers: *\r\n"
        + "Access-Control-Allow-Methods: GET, OPTIONS\r\n"

    private func readRequestLine(_ client: Int32) -> String? {
        let capacity = 4096
        var buffer = [UInt8](repeating: 0, count: capacity)
        var total = 0
        while total < capacity {
            let offset = total
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                read(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if n <= 0 { break }
            total += n
            if let range = buffer[0..<total].firstRange(of: Array("\r\n\r\n".utf8)) {
                return String(decoding: buffer[0..<range.lowerBound], as: UTF8.self)
            }
        }
        guard total > 0 else { return nil }
        return String(decoding: buffer[0..<total], as: UTF8.self)
    }

    @discardableResult
    private func send(_ client: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let start = offset
            let written = bytes.withUnsafeBytes { raw -> Int in
                write(client, raw.baseAddress!.advanced(by: start), raw.count - start)
            }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    // MARK: - Routes

    private func serveHealth(_ client: Int32) {
        let snapshot = engine.snapshot()
        var universes = "["
        for (index, u) in snapshot.universes.enumerated() {
            if index > 0 { universes += "," }
            universes += "{\"from\":\"\(u.sourceIP)\",\"universe\":\(u.universe),\"seq\":\(u.sequence)}"
        }
        universes += "]"
        let body = "{\"ok\":true,\"artnetPort\":\(artNetPort),"
                 + "\"pkts\":\(snapshot.totalPackets),\"dmxPkts\":\(snapshot.dmxPackets),"
                 + "\"universes\":\(universes),\"clients\":\(clientCount)}"
        send(client, "HTTP/1.1 200 OK\r\n" + corsHeaders
             + "Content-Type: application/json\r\n"
             + "Content-Length: \(body.utf8.count)\r\n\r\n" + body)
        close(client)
    }

    private func serveIndex(_ client: Int32) {
        lock.lock(); let data = indexData; lock.unlock()
        if let data {
            let header = "HTTP/1.1 200 OK\r\n" + corsHeaders
                       + "Content-Type: text/html; charset=utf-8\r\n"
                       + "Content-Length: \(data.count)\r\n\r\n"
            if send(client, header) {
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let written = write(client, raw.baseAddress!.advanced(by: offset),
                                            raw.count - offset)
                        if written <= 0 { break }
                        offset += written
                    }
                }
            }
            close(client)
            return
        }
        let body = """
        <!doctype html><meta charset="utf-8">
        <title>Art-Net Monitor</title>
        <body style="background:#000;color:#f5f5f7;font-family:-apple-system,sans-serif;padding:40px;line-height:1.5">
        <h2 style="font-weight:600">Art-Net Monitor is serving on port \(port)</h2>
        <p style="color:#8e8e93">The event stream is live at
        <code style="color:#5ac8fa">/events</code>. Point the viewer's Art-Net drawer at
        <code style="color:#5ac8fa">http://&lt;this mac&gt;:\(port)</code>.</p>
        <p style="color:#8e8e93">To serve your own <code>index.html</code> from here,
        choose it under the gear menu in the app.</p>
        </body>
        """
        send(client, "HTTP/1.1 200 OK\r\n" + corsHeaders
             + "Content-Type: text/html; charset=utf-8\r\n"
             + "Content-Length: \(body.utf8.count)\r\n\r\n" + body)
        close(client)
    }

    private func startEventStream(_ client: Int32) {
        let header = "HTTP/1.1 200 OK\r\n" + corsHeaders
                   + "Content-Type: text/event-stream\r\n"
                   + "Cache-Control: no-cache, no-transform\r\n"
                   + "Connection: keep-alive\r\n\r\n"
        guard send(client, header), send(client, "retry: 2000\n\n") else {
            close(client); return
        }
        guard send(client, "data: " + helloJSON() + "\n\n") else { close(client); return }

        // Snapshot straight away so the drawer fills instantly, exactly like the
        // sidecar does on connect.
        for u in engine.snapshot().universes {
            if !send(client, "data: " + dmxJSON(u) + "\n\n") { close(client); return }
        }

        lock.lock(); clients.append(client); lock.unlock()
        engine.log("web UI: viewer connected (\(clientCount) open)")
    }

    // MARK: - Pushing

    private func pushLoop() {
        var lastPing = monotonicNow()
        let interval = 1.0 / Double(Self.framesPerSecond)

        while !stopFlag.isSet {
            Thread.sleep(forTimeInterval: interval)
            guard !stopFlag.isSet else { break }

            lock.lock()
            let hasClients = !clients.isEmpty
            lock.unlock()

            let snapshot = engine.snapshot()
            let now = monotonicNow()

            if hasClients {
                var frames: [String] = []
                var seen = Set<String>()
                lock.lock()
                for u in snapshot.universes {
                    seen.insert(u.id)
                    let previous = lastSent[u.id]
                    if previous == nil || previous!.sequence != u.sequence
                        || previous!.values != u.values {
                        lastSent[u.id] = (u.values, u.sequence)
                        frames.append(dmxJSON(u))
                    }
                }
                // Universes the engine has dropped: tell the drawer to remove them.
                for (key, _) in lastSent where !seen.contains(key) {
                    lastSent.removeValue(forKey: key)
                    let parts = key.split(separator: "|")
                    if parts.count == 2 {
                        frames.append("{\"type\":\"gone\",\"from\":\"\(parts[0])\","
                                      + "\"universe\":\(parts[1])}")
                    }
                }
                lock.unlock()
                for frame in frames { broadcast("data: " + frame + "\n\n") }
            }

            // Non-DMX opcodes (ArtPoll, ArtPollReply, ArtSync, ...), already
            // throttled by the engine, relayed as the sidecar did.
            let others = engine.drainOtherEvents()
            if hasClients {
                for event in others {
                    broadcast("data: {\"type\":\"other\",\"op\":\"\(event.op)\","
                              + "\"from\":\"\(event.from)\"}\n\n")
                }
            }

            // Stats once a second, like the sidecar.
            if now - lastStatsTime >= 1 {
                let elapsed = now - lastStatsTime
                let pps = Int((Double(snapshot.totalPackets - lastTotalPackets) / elapsed).rounded())
                lastTotalPackets = snapshot.totalPackets
                lastStatsTime = now
                if hasClients {
                    broadcast("data: {\"type\":\"stats\",\"pkts\":\(snapshot.totalPackets),"
                              + "\"dmxPkts\":\(snapshot.dmxPackets),\"pps\":\(pps),"
                              + "\"universes\":\(snapshot.universes.count),"
                              + "\"clients\":\(clientCount)}\n\n")
                }
            }

            if now - lastPing >= 15 {
                lastPing = now
                broadcast(": ping\n\n")
            }
        }

        lock.lock()
        let open = clients
        clients = []
        lock.unlock()
        for client in open { shutdown(client, SHUT_RDWR); close(client) }
    }

    private func broadcast(_ text: String) {
        lock.lock()
        let targets = clients
        lock.unlock()

        var dead: [Int32] = []
        for client in targets where !send(client, text) { dead.append(client) }
        guard !dead.isEmpty else { return }

        lock.lock()
        clients.removeAll { dead.contains($0) }
        let remaining = clients.count
        lock.unlock()
        for client in dead { close(client) }
        engine.log("web UI: viewer disconnected (\(remaining) open)")
    }

    // MARK: - JSON (hand-built: 512 ints, 20x a second, per universe)

    private func helloJSON() -> String {
        var interfaces = "["
        for (index, entry) in Self.localAddresses().enumerated() {
            if index > 0 { interfaces += "," }
            interfaces += "{\"name\":\"\(entry.name)\",\"address\":\"\(entry.address)\"}"
        }
        interfaces += "]"
        let host = ProcessInfo.processInfo.hostName
        return "{\"type\":\"hello\",\"artnetPort\":\(artNetPort),"
             + "\"fps\":\(Self.framesPerSecond),\"host\":\"\(host)\","
             + "\"interfaces\":\(interfaces)}"
    }

    private func dmxJSON(_ u: UniverseSnapshot) -> String {
        var channels = String()
        channels.reserveCapacity(2048)
        channels += "["
        for (index, value) in u.values.enumerated() {
            if index > 0 { channels += "," }
            channels += String(value)
        }
        channels += "]"
        return "{\"type\":\"dmx\",\"from\":\"\(u.sourceIP)\",\"universe\":\(u.universe),"
             + "\"net\":\(u.net),\"subnet\":\(u.subnet),\"uni\":\(u.uni),"
             + "\"seq\":\(u.sequence),\"len\":\(u.length),\"channels\":\(channels)}"
    }

    /// Non-loopback IPv4 addresses, so the app can print the URL to type.
    static func localAddresses() -> [(name: String, address: String)] {
        var results: [(name: String, address: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return results }
        defer { freeifaddrs(head) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let rawAddress = current.pointee.ifa_addr,
                  rawAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(rawAddress, socklen_t(rawAddress.pointee.sa_len),
                                     &host, socklen_t(NI_MAXHOST),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let address = String(decoding: bytes, as: UTF8.self)
            let name = String(cString: current.pointee.ifa_name)
            if !address.isEmpty { results.append((name: name, address: address)) }
        }
        return results
    }
}
