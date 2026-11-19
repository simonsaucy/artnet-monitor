//
//  ArtNetMonitorApp.swift
//  Art-Net Monitor
//
//  Art-Net monitor for the Resolume Mac: a Hog console sending control DMX into
//  Resolume, and Resolume's own pixel output on its way to the PCL Pixel Stix
//  processors (10.0.0.78–82, universes 0–19).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ArtNetMonitorApp: App {

    @State private var store = MonitorStore()

    var body: some Scene {
        Window("Art-Net Monitor", id: "monitor") {
            ContentView()
                .environment(store)
        }
        .defaultSize(width: 760, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Monitor") {
                Button(store.isRunning ? "Stop Monitoring" : "Start Monitoring") {
                    store.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command])

                if CaptureMode.allCases.count > 1 {
                    Picker("Mode", selection: Binding(get: { store.mode },
                                                      set: { store.setMode($0) })) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                Divider()

                Toggle("Serve Web UI on \(WebUIServer.defaultPort)",
                       isOn: Binding(get: { store.serveWebUI },
                                     set: { store.serveWebUI = $0 }))

                Button("Choose Web UI Page…") { chooseIndexHTML(store: store) }

                Button("Open Web UI in Browser") {
                    let host = store.webAddresses.first
                        ?? "http://localhost:\(WebUIServer.defaultPort)"
                    if let url = URL(string: host) { NSWorkspace.shared.open(url) }
                }
                .disabled(!store.webServing)

                Divider()

                Button("Send Test Packets") { store.sendTestPackets() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}

/// Shared by the menu bar and the gear menu.
@MainActor
func chooseIndexHTML(store: MonitorStore) {
    let panel = NSOpenPanel()
    panel.title = "Choose the viewer's index.html"
    panel.allowedContentTypes = [.html]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    if panel.runModal() == .OK, let url = panel.url {
        store.chooseIndexHTML(url)
    }
}
