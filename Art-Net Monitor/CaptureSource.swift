//
//  CaptureSource.swift
//  Art-Net Monitor
//

import Foundation

/// Capture is compiled out of the sandboxed TestFlight build: the App Sandbox
/// forbids running tcpdump as root, so only the plain UDP socket survives there.
/// Nothing outside this enum names `.capture` directly, so the rest of the app
/// compiles unchanged either way.
nonisolated enum CaptureMode: String, CaseIterable, Sendable, Identifiable {
#if !SANDBOXED
    case capture
#endif
    case listen

    /// The mode a fresh install starts on.
    static var preferred: CaptureMode { allCases[0] }

    var id: String { rawValue }

    var title: String {
        switch self {
#if !SANDBOXED
        case .capture: return "Capture"
#endif
        case .listen: return "Listen"
        }
    }

    var blurb: String {
        switch self {
#if !SANDBOXED
        case .capture:
            return "tcpdump on pktap — sees everything, including Resolume's own "
                 + "unicast output to the pixel processors, and never takes UDP 6454."
#endif
        case .listen:
            return "Plain UDP socket on 0.0.0.0:6454. Shares the port, but macOS "
                 + "hands unicast to only one socket, so Resolume's unicast to the "
                 + "pixel processors will not show up — only broadcast Art-Net."
        }
    }

    /// Shown under the view toggle.
    var footerLabel: String {
        switch self {
#if !SANDBOXED
        case .capture: return "pktap · tcpdump"
#endif
        case .listen: return "udp 6454 · shared"
        }
    }

    /// Status text while the source is coming up.
    var startingText: String {
        switch self {
#if !SANDBOXED
        case .capture: return "Authorizing…"
#endif
        case .listen: return "Starting…"
        }
    }

    /// Builds the capture source for this mode.
    func makeSource(engine: CaptureEngine) -> CaptureSource {
        switch self {
#if !SANDBOXED
        case .capture: return PktapCapture(engine: engine)
#endif
        case .listen: return UDPListener(engine: engine)
        }
    }
}

nonisolated enum CaptureState: Sendable, Equatable {
    case idle
    case starting
    case running
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .running: return true
        case .idle, .failed: return false
        }
    }
}

nonisolated protocol CaptureSource: AnyObject, Sendable {
    func start()
    func stop()
    /// Current state, safe to read from any thread.
    var state: CaptureState { get }
}

/// Small lock-protected box so capture sources can publish their state without
/// calling back into the main actor.
nonisolated final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CaptureState = .idle

    var state: CaptureState {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: CaptureState) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

/// Lock-protected bool, for the stop flags the reader threads poll.
nonisolated final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() { lock.lock(); value = true; lock.unlock() }
    func clear() { lock.lock(); value = false; lock.unlock() }
}

/// Lock-protected Int32, for the tcpdump PID.
nonisolated final class PIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: pid_t = 0

    var pid: pid_t {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: pid_t) { lock.lock(); value = newValue; lock.unlock() }
}

nonisolated let artNetPort: UInt16 = 6454
