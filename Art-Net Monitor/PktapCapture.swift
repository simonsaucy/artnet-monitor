//
//  PktapCapture.swift
//  Art-Net Monitor
//
//  Primary capture mode. We never bind UDP 6454 — Resolume's DMX input owns it,
//  and on macOS a unicast packet arriving on a SO_REUSEPORT-shared port is
//  delivered to exactly one socket. So either we see nothing or we steal
//  Resolume's input. Instead we read packets out of /usr/sbin/tcpdump running on
//  the pktap pseudo-interface as root, which also shows us Resolume's own
//  outgoing unicast to the PCL Pixel Stix processors.
//
//  Elevation is a single NSAppleScript "with administrator privileges" call, so
//  the user sees one password prompt. tcpdump's stdout is redirected into a FIFO
//  we create ourselves and read on a background thread.
//

import Foundation

nonisolated final class PktapCapture: CaptureSource, @unchecked Sendable {

    private let engine: CaptureEngine
    private let stateBox = StateBox()
    private let stopFlag = FlagBox()
    private let pidBox = PIDBox()

    private let authQueue = DispatchQueue(label: "com.thecrossing.artnet.auth")
    private let fifoPathLock = NSLock()
    private var fifoPath: String?
    private var fifoFD: Int32 = -1

    var state: CaptureState { stateBox.state }

    init(engine: CaptureEngine) {
        self.engine = engine
    }

    // MARK: - Lifecycle

    func start() {
        guard !state.isActive else { return }
        stopFlag.clear()
        pidBox.set(0)
        stateBox.set(.starting)

        let path = NSTemporaryDirectory()
            .appending("artnet-monitor-\(UUID().uuidString).fifo")

        unlink(path)
        guard mkfifo(path, 0o600) == 0 else {
            fail("Could not create the capture pipe: \(errnoText())")
            return
        }

        // O_RDWR, not O_RDONLY: opening a FIFO read-only blocks until a writer
        // shows up, and the writer only shows up if the user types their
        // password. With O_RDWR the open returns immediately and a cancelled
        // prompt just means no data ever arrives.
        let fd = open(path, O_RDWR)
        guard fd >= 0 else {
            let message = errnoText()
            unlink(path)
            fail("Could not open the capture pipe: \(message)")
            return
        }

        fifoPathLock.lock()
        fifoPath = path
        fifoFD = fd
        fifoPathLock.unlock()

        engine.log("capture: asking for administrator rights to run tcpdump")

        // Read the FIFO on its own thread.
        let reader = Thread { [weak self] in self?.readLoop(fd: fd) }
        reader.name = "artnet.pktap.reader"
        reader.stackSize = 512 * 1024
        reader.start()

        // Elevate on a dedicated serial queue so the password prompt never
        // blocks the UI. NSAppleScript is used from this one thread only.
        // Single-quote the FIFO path for the shell (a UUID under
        // NSTemporaryDirectory() never contains a quote), then escape the whole
        // command once for the AppleScript string literal.
        let shell = "/usr/sbin/tcpdump -i pktap -n -l -x -s 0 'udp port \(artNetPort)'"
                  + " > '\(path)' 2>&1 & echo $!"
        let literal = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(literal)\" with administrator privileges"

        authQueue.async { [weak self] in
            guard let self else { return }
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: source)
            let result = script?.executeAndReturnError(&errorInfo)

            if let errorInfo {
                let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                if number == -128 {
                    self.fail("Cancelled — capture mode needs an administrator password.")
                } else {
                    let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                        ?? "AppleScript error \(number)"
                    self.fail("Could not start tcpdump: \(message)")
                }
                self.stopFlag.set()
                return
            }

            let text = (result?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = pid_t(text) {
                self.pidBox.set(pid)
                self.engine.log("capture: tcpdump running as root, pid \(pid)")
            } else {
                self.engine.log("capture: tcpdump started (no pid reported)")
            }
            if case .starting = self.stateBox.state {
                self.stateBox.set(.running)
            }
        }
    }

    func stop() {
        stopFlag.set()
        closeFIFO()
        if state.isActive { stateBox.set(.idle) }
    }

    private func fail(_ message: String) {
        stateBox.set(.failed(message))
        engine.log("capture: \(message)")
        closeFIFO()
    }

    /// Closing our end of the FIFO leaves tcpdump with no reader, so its next
    /// write raises SIGPIPE and the root process dies on its own. We cannot
    /// signal it ourselves — it belongs to root.
    private func closeFIFO() {
        fifoPathLock.lock()
        let fd = fifoFD
        let path = fifoPath
        fifoFD = -1
        fifoPath = nil
        fifoPathLock.unlock()

        if fd >= 0 { close(fd) }
        if let path { unlink(path) }
    }

    private func errnoText() -> String {
        String(cString: strerror(errno))
    }

    // MARK: - Reading

    private func readLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = ""
        var lastPIDCheck = monotonicNow()

        var parser = TcpdumpTextParser(engine: engine)

        while !stopFlag.isSet {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 500)

            if ready < 0 {
                if errno == EINTR { continue }
                break
            }

            if ready > 0, pfd.revents & Int16(POLLIN) != 0 {
                let n = buffer.withUnsafeMutableBytes { raw in
                    read(fd, raw.baseAddress, raw.count)
                }
                if n > 0 {
                    pending += String(decoding: buffer[0..<n], as: UTF8.self)
                    while let nl = pending.firstIndex(of: "\n") {
                        let line = String(pending[pending.startIndex..<nl])
                        pending = String(pending[pending.index(after: nl)...])
                        parser.feed(line) { [weak self] in
                            if case .starting = self?.stateBox.state {
                                self?.stateBox.set(.running)
                            }
                        }
                    }
                    if pending.utf8.count > 1 << 20 { pending = "" }  // safety valve
                } else if n == 0 {
                    // With O_RDWR this should not happen, but don't spin.
                    continue
                } else if errno != EAGAIN && errno != EINTR {
                    break
                }
            }

            // Watch the root tcpdump: kill(pid, 0) gives EPERM while it's alive
            // (we're not root) and ESRCH once it's gone.
            let now = monotonicNow()
            if now - lastPIDCheck > 1 {
                lastPIDCheck = now
                let pid = pidBox.pid
                if pid > 0, kill(pid, 0) != 0, errno == ESRCH {
                    if !stopFlag.isSet {
                        stateBox.set(.failed("tcpdump stopped unexpectedly."))
                        engine.log("capture: tcpdump (pid \(pid)) exited")
                    }
                    break
                }
            }
        }

        parser.flush()
    }
}

// MARK: - tcpdump -x text parsing

/// Turns `tcpdump -n -l -x` text back into packets. The source IP comes from
/// the "IP a.b.c.d.port > " header line; the bytes come from the indented hex
/// lines that follow it.
nonisolated struct TcpdumpTextParser {

    private let engine: CaptureEngine
    private var source: String?
    private var hex: [UInt8] = []

    init(engine: CaptureEngine) {
        self.engine = engine
        hex.reserveCapacity(2048)
    }

    mutating func feed(_ line: String, onListening: () -> Void) {
        // Indented hex dump line, e.g. "\t0x0030:  4172 742d 4e65 7400 ...".
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.count != line.count, trimmed.hasPrefix("0x"),
           let colon = trimmed.firstIndex(of: ":") {
            appendHex(trimmed[trimmed.index(after: colon)...])
            return
        }

        // Any non-hex line ends the previous packet.
        flush()

        if line.contains("listening on") {
            engine.log("capture: \(line.trimmingCharacters(in: .whitespaces))")
            onListening()
            return
        }
        if line.contains("tcpdump:") || line.lowercased().contains("permission denied") {
            engine.log("capture: \(line.trimmingCharacters(in: .whitespaces))")
            return
        }

        source = Self.sourceIP(from: line)
    }

    mutating func flush() {
        defer { source = nil; hex.removeAll(keepingCapacity: true) }
        guard let source, !hex.isEmpty else { return }
        engine.ingest(hex, from: source)
    }

    private mutating func appendHex(_ text: Substring) {
        var high: UInt8?
        for ch in text.utf8 {
            let nibble: UInt8
            switch ch {
            case 0x30...0x39: nibble = ch - 0x30          // 0-9
            case 0x61...0x66: nibble = ch - 0x61 + 10     // a-f
            case 0x41...0x46: nibble = ch - 0x41 + 10     // A-F
            default: continue
            }
            if let h = high {
                hex.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        if hex.count > 65_536 { hex.removeAll(keepingCapacity: true) }
    }

    /// Pull "10.0.0.78" out of "... IP 10.0.0.78.6454 > 10.0.0.82.6454: UDP, length 530".
    static func sourceIP(from line: String) -> String? {
        var rest: Substring
        if let r = line.range(of: " IP ") {
            rest = line[r.upperBound...]
        } else if let r = line.range(of: " IP6 ") {
            rest = line[r.upperBound...]
        } else {
            return nil
        }
        guard let gt = rest.range(of: " > ") else { return nil }
        let addressAndPort = rest[rest.startIndex..<gt.lowerBound]
        guard let dot = addressAndPort.lastIndex(of: "."),
              dot > addressAndPort.startIndex else { return nil }
        let address = addressAndPort[addressAndPort.startIndex..<dot]
        return address.isEmpty ? nil : String(address)
    }
}
