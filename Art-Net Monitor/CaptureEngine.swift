//
//  CaptureEngine.swift
//  Art-Net Monitor
//
//  The shared, lock-protected state that capture threads write into and the
//  main actor reads snapshots out of. Nothing in here touches SwiftUI, and
//  nothing publishes per packet.
//

import Foundation

// MARK: - Snapshot types (immutable, Sendable, safe to hand to the main actor)

nonisolated struct ChannelChange: Sendable, Equatable {
    var channel: Int   // 1-based
    var from: Int
    var to: Int
}

nonisolated struct UniverseSnapshot: Identifiable, Sendable, Equatable {
    var id: String            // "sourceIP|universe"
    var sourceIP: String
    var universe: Int
    var net: Int
    var subnet: Int
    var uni: Int
    var sequence: Int
    var length: Int
    var packets: Int
    var values: [UInt8]       // always 512
    var activeCount: Int
    var lastChange: ChannelChange?
    /// Monotonic timestamp (seconds) of the last change per channel, for the
    /// "just changed" outline in the text view.
    var changedAt: [Double]

    var triple: String { "\(net).\(subnet).\(uni)" }
}

nonisolated struct MonitorStats: Sendable, Equatable {
    var packetsPerSecond: Int = 0
    var universeCount: Int = 0
    var totalPackets: Int = 0
    var dmxPackets: Int = 0
}

nonisolated struct EngineSnapshot: Sendable {
    var universes: [UniverseSnapshot] = []
    var totalPackets: Int = 0
    var dmxPackets: Int = 0
    var logVersion: Int = 0
    var log: [String] = []
}

nonisolated func monotonicNow() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: - Engine

nonisolated final class CaptureEngine: @unchecked Sendable {

    /// Universes silent for this long are dropped, like the Node sidecar.
    static let silenceTimeout: Double = 10
    /// Non-DMX opcodes are logged at most once per source per this interval.
    static let otherLogThrottle: Double = 2
    static let maxLogLines = 80

    private final class UniverseState {
        let sourceIP: String
        let universe: Int
        let net: Int
        let subnet: Int
        let uni: Int
        var values = [UInt8](repeating: 0, count: 512)
        var changedAt = [Double](repeating: 0, count: 512)
        var sequence = 0
        var length = 0
        var packets = 0
        var activeCount = 0
        var lastChange: ChannelChange?
        var lastSeen: Double = 0
        var dirty = true

        init(sourceIP: String, universe: Int, net: Int, subnet: Int, uni: Int) {
            self.sourceIP = sourceIP
            self.universe = universe
            self.net = net
            self.subnet = subnet
            self.uni = uni
        }
    }

    private let lock = NSLock()
    private var universes: [String: UniverseState] = [:]
    private var order: [String] = []          // keeps card order stable
    private var totalPackets = 0
    private var dmxPackets = 0
    private var otherSeen: [String: Double] = [:]
    private var logLines: [String] = []
    private var logVersion = 0

    private let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: Writing (capture threads)

    func log(_ text: String) {
        let stamp = logFormatter.string(from: Date())
        lock.lock()
        logLines.insert("\(stamp)  \(text)", at: 0)
        if logLines.count > Self.maxLogLines { logLines.removeLast() }
        logVersion += 1
        lock.unlock()
    }

    /// Feed one captured datagram payload. `bytes` may be a whole IP frame;
    /// we find the Art-Net header inside it.
    func ingest(_ bytes: [UInt8], from sourceIP: String) {
        guard let offset = ArtNetDecoder.headerIndex(in: bytes) else { return }
        guard let packet = ArtNetDecoder.decode(bytes, at: offset) else { return }
        let now = monotonicNow()

        switch packet {
        case .dmx(let dmx):
            lock.lock()
            totalPackets += 1
            dmxPackets += 1
            let key = "\(sourceIP)|\(dmx.universe)"
            let state: UniverseState
            if let existing = universes[key] {
                state = existing
            } else {
                state = UniverseState(sourceIP: sourceIP,
                                      universe: dmx.universe,
                                      net: dmx.net,
                                      subnet: dmx.subnet,
                                      uni: dmx.uni)
                universes[key] = state
                order.append(key)
                let stamp = logFormatter.string(from: Date())
                logLines.insert("\(stamp)  new universe \(dmx.universe) "
                                + "(net \(dmx.net) / sub \(dmx.subnet) / uni \(dmx.uni)) "
                                + "from \(sourceIP)", at: 0)
                if logLines.count > Self.maxLogLines { logLines.removeLast() }
                logVersion += 1
            }

            var active = 0
            var change: ChannelChange?
            for i in 0..<512 {
                let value: UInt8 = i < dmx.length ? bytes[dmx.dataOffset + i] : 0
                if value > 0 { active += 1 }
                if state.values[i] != value {
                    change = ChannelChange(channel: i + 1,
                                           from: Int(state.values[i]),
                                           to: Int(value))
                    state.values[i] = value
                    state.changedAt[i] = now
                }
            }
            if let change { state.lastChange = change }
            state.activeCount = active
            state.sequence = dmx.sequence
            state.length = dmx.length
            state.packets += 1
            state.lastSeen = now
            state.dirty = true
            lock.unlock()

        case .other(_, let name):
            lock.lock()
            totalPackets += 1
            let key = "\(name)|\(sourceIP)"
            let last = otherSeen[key] ?? -.greatestFiniteMagnitude
            let shouldLog = now - last > Self.otherLogThrottle
            if shouldLog {
                otherSeen[key] = now
                let stamp = logFormatter.string(from: Date())
                logLines.insert("\(stamp)  \(name)  from \(sourceIP)", at: 0)
                if logLines.count > Self.maxLogLines { logLines.removeLast() }
                logVersion += 1
            }
            lock.unlock()
        }
    }

    // MARK: Reading (main actor)

    func snapshot() -> EngineSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var out = EngineSnapshot()
        out.totalPackets = totalPackets
        out.dmxPackets = dmxPackets
        out.logVersion = logVersion
        out.log = logLines
        out.universes.reserveCapacity(order.count)
        for key in order {
            guard let u = universes[key] else { continue }
            out.universes.append(UniverseSnapshot(id: key,
                                                  sourceIP: u.sourceIP,
                                                  universe: u.universe,
                                                  net: u.net,
                                                  subnet: u.subnet,
                                                  uni: u.uni,
                                                  sequence: u.sequence,
                                                  length: u.length,
                                                  packets: u.packets,
                                                  values: u.values,
                                                  activeCount: u.activeCount,
                                                  lastChange: u.lastChange,
                                                  changedAt: u.changedAt))
        }
        return out
    }

    /// Drop universes that have gone quiet. Call about once a second.
    func reapSilent() {
        let now = monotonicNow()
        lock.lock()
        var dropped: [UniverseState] = []
        for (key, u) in universes where now - u.lastSeen > Self.silenceTimeout {
            dropped.append(u)
            universes.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
        if !dropped.isEmpty {
            let stamp = logFormatter.string(from: Date())
            for u in dropped {
                logLines.insert("\(stamp)  universe \(u.universe) from \(u.sourceIP) went silent",
                                at: 0)
            }
            while logLines.count > Self.maxLogLines { logLines.removeLast() }
            logVersion += 1
        }
        lock.unlock()
    }

    /// Clear everything but the log, for a fresh capture run.
    func resetCounters() {
        lock.lock()
        universes.removeAll()
        order.removeAll()
        otherSeen.removeAll()
        totalPackets = 0
        dmxPackets = 0
        lock.unlock()
    }
}
