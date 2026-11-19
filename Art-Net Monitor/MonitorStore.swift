//
//  MonitorStore.swift
//  Art-Net Monitor
//
//  The one @MainActor object the UI observes. It snapshots the lock-protected
//  engine on a timer (about 20 times a second) instead of publishing per
//  packet — Resolume can push 40+ fps across twenty universes, and SwiftUI does
//  not need to hear about every one.
//

import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class MonitorStore {

    // MARK: Published state

    var universes: [UniverseSnapshot] = []
    var stats = MonitorStats()
    var logLines: [String] = []
    var mode: CaptureMode = .preferred
    var state: CaptureState = .idle
    /// Bumped about four times a second so the text view's "just changed"
    /// outlines keep fading even when no new packets arrive.
    var fadeTick = 0

    /// Web UI (the Art-Net drawer in index.html) server state.
    var webServing = false
    var webClients = 0
    var webError: String?
    /// Addresses to type into the drawer, e.g. "http://10.0.0.23:6455".
    var webAddresses: [String] = []

    var isRunning: Bool { state.isActive }

    var statusText: String {
        switch state {
        case .idle: return "Idle"
        case .starting: return mode.startingText
        case .running:
            if stats.packetsPerSecond > 0 { return "Live · \(mode.title)" }
            return "Waiting for packets · \(mode.title)"
        case .failed(let message): return message
        }
    }

    enum StatusTint { case idle, live, waiting, error }

    var statusTint: StatusTint {
        switch state {
        case .idle: return .idle
        case .starting: return .waiting
        case .running: return stats.packetsPerSecond > 0 ? .live : .waiting
        case .failed: return .error
        }
    }

    // MARK: Internals

    private let engine = CaptureEngine()
    private var source: CaptureSource?
    private let webServer: WebUIServer
    private var ticker: Task<Void, Never>?
    private var lastLogVersion = -1
    private var lastTotalForPPS = 0
    private var lastPPSTime = monotonicNow()
    private var lastFadeTick = monotonicNow()
    /// Held for the app's lifetime; the store outlives every window.
    private var terminationObserver: NSObjectProtocol?

    /// Reuse one sender so the debug menu item doesn't open a socket per click.
    private let testSender = TestPacketSender()

    init() {
        webServer = WebUIServer(engine: engine)
        if let saved = UserDefaults.standard.string(forKey: "captureMode"),
           let restored = CaptureMode(rawValue: saved) {
            mode = restored
        }
        logLines = engine.snapshot().log

        // Clean up on quit: close the FIFO (tcpdump then dies on SIGPIPE) or
        // the UDP socket before the process goes away.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
    }


    // MARK: Control

    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode else { return }
        let wasRunning = isRunning
        if wasRunning { stop() }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: "captureMode")
        if wasRunning { start() }
    }

    func start() {
        guard source == nil else { return }
        engine.resetCounters()
        universes = []
        stats = MonitorStats()
        lastTotalForPPS = 0
        lastPPSTime = monotonicNow()

        let newSource = mode.makeSource(engine: engine)
        source = newSource
        newSource.start()
        state = newSource.state
        startWebServerIfWanted()
        startTicker()
    }

    func stop() {
        source?.stop()
        source = nil
        webServer.stop()
        webServing = false
        webClients = 0
        ticker?.cancel()
        ticker = nil
        state = .idle
        stats.packetsPerSecond = 0
        refresh()
    }

    func toggle() {
        if isRunning || source != nil { stop() } else { start() }
    }

    /// Called once from the window's onAppear.
    func startIfConfiguredForLaunch() {
        guard UserDefaults.standard.bool(forKey: "startOnLaunch") else { return }
        engine.log("start on launch is on — starting \(mode.title.lowercased()) mode")
        start()
    }

    // MARK: Web UI server

    var serveWebUI: Bool {
        get { UserDefaults.standard.object(forKey: "serveWebUI") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "serveWebUI")
            if newValue {
                if isRunning { startWebServerIfWanted() }
            } else {
                webServer.stop()
                webServing = false
                webClients = 0
            }
        }
    }

    /// Display name of the index.html being served at "/", if any.
    var indexHTMLName: String?

    /// Remember the user's pick as a security-scoped bookmark. A plain path is
    /// not enough: the viewer's index.html normally lives under
    /// ~/Library/CloudStorage, which macOS gates behind a privacy prompt, and a
    /// cold read there can block for a long time.
    func chooseIndexHTML(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "indexHTMLBookmark")
            loadIndexHTML()
        } catch {
            engine.log("web UI: could not remember that file — \(error.localizedDescription)")
        }
    }

    func clearIndexHTML() {
        UserDefaults.standard.removeObject(forKey: "indexHTMLBookmark")
        indexHTMLName = nil
        webServer.setIndexHTML(nil, name: nil)
        engine.log("web UI: no index.html chosen — serving the built-in page")
    }

    /// Resolve the bookmark and read the page into memory, once.
    private func loadIndexHTML() {
        guard let bookmark = UserDefaults.standard.data(forKey: "indexHTMLBookmark") else {
            indexHTMLName = nil
            webServer.setIndexHTML(nil, name: nil)
            return
        }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            indexHTMLName = url.lastPathComponent
            webServer.setIndexHTML(data, name: url.lastPathComponent)
            engine.log("web UI: serving \(url.lastPathComponent) "
                       + "(\(data.count / 1024) KB) at /")
            if stale {
                let fresh = try url.bookmarkData(options: .withSecurityScope,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
                UserDefaults.standard.set(fresh, forKey: "indexHTMLBookmark")
            }
        } catch {
            indexHTMLName = nil
            webServer.setIndexHTML(nil, name: nil)
            engine.log("web UI: could not read the chosen index.html — "
                       + "\(error.localizedDescription)")
        }
    }

    private func startWebServerIfWanted() {
        guard serveWebUI else { return }
        loadIndexHTML()
        webServer.start()
        webAddresses = WebUIServer.localAddresses()
            .map { "http://\($0.address):\(WebUIServer.defaultPort)" }
    }

    func sendTestPackets() {
        let sent = testSender.sendBurst()
        engine.log("sent \(sent) test packets to 127.0.0.1:\(artNetPort) "
                   + "(universes 0, 1, 21 + ArtPoll)")
    }

    // MARK: Login item

    var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                engine.log("added Art-Net Monitor to your login items")
            } else {
                try SMAppService.mainApp.unregister()
                engine.log("removed Art-Net Monitor from your login items")
            }
        } catch {
            engine.log("could not change the login item: \(error.localizedDescription)")
        }
        refresh()
    }

    // MARK: Snapshot loop

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var lastReap = monotonicNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
                let now = monotonicNow()
                if now - lastReap >= 1 {
                    lastReap = now
                    self.engine.reapSilent()
                }
            }
        }
    }

    private func refresh() {
        let snapshot = engine.snapshot()

        if universes != snapshot.universes { universes = snapshot.universes }

        let now = monotonicNow()
        let elapsed = now - lastPPSTime
        if elapsed >= 1 {
            let pps = Int((Double(snapshot.totalPackets - lastTotalForPPS) / elapsed).rounded())
            lastTotalForPPS = snapshot.totalPackets
            lastPPSTime = now
            stats.packetsPerSecond = pps
        }
        stats.totalPackets = snapshot.totalPackets
        stats.dmxPackets = snapshot.dmxPackets
        stats.universeCount = snapshot.universes.count

        if now - lastFadeTick >= 0.25 {
            lastFadeTick = now
            fadeTick &+= 1
        }

        if snapshot.logVersion != lastLogVersion {
            lastLogVersion = snapshot.logVersion
            logLines = snapshot.log
        }

        switch webServer.state {
        case .running:
            if !webServing { webServing = true }
            if webError != nil { webError = nil }
            let count = webServer.clientCount
            if count != webClients { webClients = count }
        case .failed(let message):
            if webServing { webServing = false }
            if webError != message { webError = message }
        case .idle, .starting:
            if webServing { webServing = false }
        }

        if let source {
            let sourceState = source.state
            if state != sourceState { state = sourceState }
            if case .failed = sourceState {
                self.source = nil
                ticker?.cancel()
                ticker = nil
                stats.packetsPerSecond = 0
            }
        }
    }
}
