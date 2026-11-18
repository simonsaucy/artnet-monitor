//
//  UDPListener.swift
//  Art-Net Monitor
//
//  Fallback mode: a plain BSD UDP socket on 0.0.0.0:6454 with SO_REUSEADDR,
//  SO_REUSEPORT and SO_BROADCAST, so it can share the port with Resolume.
//
//  Caveat worth repeating in the UI: on macOS a *unicast* datagram arriving on
//  a port shared via SO_REUSEPORT is delivered to exactly one socket. If
//  Resolume's Art-Net input is enabled, it usually wins, so this mode normally
//  only shows broadcast traffic.
//

import Foundation

nonisolated final class UDPListener: CaptureSource, @unchecked Sendable {

    private let engine: CaptureEngine
    private let stateBox = StateBox()
    private let stopFlag = FlagBox()

    private let fdLock = NSLock()
    private var fd: Int32 = -1

    var state: CaptureState { stateBox.state }

    init(engine: CaptureEngine) {
        self.engine = engine
    }

    func start() {
        guard !state.isActive else { return }
        stopFlag.clear()
        stateBox.set(.starting)

        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            fail("Could not create a UDP socket: \(errnoText())")
            return
        }

        var on: Int32 = 1
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &on, optionSize)
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEPORT, &on, optionSize)
        setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &on, optionSize)

        // Half-second receive timeout so the reader thread can notice stop().
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = artNetPort.bigEndian
        address.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(socketFD, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let message = errnoText()
            close(socketFD)
            fail("Could not bind UDP \(artNetPort): \(message)")
            return
        }

        fdLock.lock(); fd = socketFD; fdLock.unlock()
        stateBox.set(.running)
        engine.log("listen: bound udp 0.0.0.0:\(artNetPort) "
                   + "(unicast may still go to Resolume only)")

        let reader = Thread { [weak self] in self?.readLoop(fd: socketFD) }
        reader.name = "artnet.udp.reader"
        reader.stackSize = 512 * 1024
        reader.start()
    }

    func stop() {
        stopFlag.set()
        fdLock.lock()
        let socketFD = fd
        fd = -1
        fdLock.unlock()
        if socketFD >= 0 {
            shutdown(socketFD, SHUT_RDWR)
            close(socketFD)
        }
        if state.isActive { stateBox.set(.idle) }
    }

    private func fail(_ message: String) {
        stateBox.set(.failed(message))
        engine.log("listen: \(message)")
    }

    private func errnoText() -> String { String(cString: strerror(errno)) }

    private func readLoop(fd socketFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)

        while !stopFlag.isSet {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)

            let received: Int = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    buffer.withUnsafeMutableBytes { raw in
                        recvfrom(socketFD, raw.baseAddress, raw.count, 0,
                                 generic, &fromLength)
                    }
                }
            }

            if received > 0 {
                let payload = Array(buffer[0..<received])
                engine.ingest(payload, from: Self.ipString(from))
            } else if received < 0 {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { continue }
                break
            }
        }
    }

    private static func ipString(_ address: sockaddr_in) -> String {
        var addr = address.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return "?"
        }
        let bytes = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
