//
//  TestPacketSender.swift
//  Art-Net Monitor
//
//  Debug helper so the app can be checked without a console or Resolume
//  attached: sends real ArtDmx frames (including universe 21, which is
//  0.1.5 in Resolume's three input fields) plus an ArtPoll to 127.0.0.1:6454.
//
//  Loopback traffic is broadcast-ish enough for Listen mode to pick it up.
//  Capture mode will not see it: pktap does not carry loopback by default.
//

import Foundation

nonisolated final class TestPacketSender: @unchecked Sendable {

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var sequence: UInt8 = 0
    private var phase: Double = 0

    /// Universes exercised by the test burst. 21 is the interesting one.
    static let universes = [0, 1, 21]

    deinit {
        if fd >= 0 { close(fd) }
    }

    /// Sends one frame per test universe plus an ArtPoll. Returns the count sent.
    func sendBurst() -> Int {
        lock.lock()
        defer { lock.unlock() }

        if fd < 0 {
            fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return 0 }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = artNetPort.bigEndian
        destination.sin_addr.s_addr = inet_addr("127.0.0.1")

        var sent = 0
        sequence = sequence == 255 ? 1 : sequence + 1
        phase += 0.12

        for universe in Self.universes {
            let packet = Self.artDmx(universe: universe,
                                     sequence: sequence,
                                     phase: phase + Double(universe))
            if send(packet, to: &destination) { sent += 1 }
        }
        if send(Self.artPoll(), to: &destination) { sent += 1 }
        return sent
    }

    private func send(_ bytes: [UInt8], to destination: inout sockaddr_in) -> Bool {
        let result = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bytes.withUnsafeBytes { raw in
                    sendto(fd, raw.baseAddress, raw.count, 0,
                           generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result > 0
    }

    // MARK: Packet builders

    static func artDmx(universe: Int, sequence: UInt8, phase: Double) -> [UInt8] {
        let subUni = UInt8(universe & 0xFF)
        let net = UInt8((universe >> 8) & 0x7F)
        let length = 512

        var packet = artNetHeader
        packet += [0x00, 0x50]              // OpDmx 0x5000, little-endian
        packet += [0x00, 0x0E]              // protocol version 14
        packet += [sequence]
        packet += [0x00]                    // physical
        packet += [subUni, net]
        packet += [UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]  // big-endian

        // A moving sine ramp on the first 24 channels, the rest at zero —
        // enough to see the grid light up and the text rows change.
        var data = [UInt8](repeating: 0, count: length)
        for channel in 0..<24 {
            let value = (sin(phase + Double(channel) * 0.4) + 1) / 2
            data[channel] = UInt8(max(0, min(255, (value * 255).rounded())))
        }
        data[9] = UInt8(truncatingIfNeeded: Int(sequence) * 3)  // channel 10 always moves
        packet += data
        return packet
    }

    static func artPoll() -> [UInt8] {
        var packet = artNetHeader
        packet += [0x00, 0x20]              // OpPoll 0x2000
        packet += [0x00, 0x0E]              // protocol version 14
        packet += [0x02, 0x00]              // TalkToMe, Priority
        return packet
    }
}
