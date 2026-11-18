//
//  ArtNetMonitorApp.swift
//  Art-Net Monitor
//
//  Art-Net monitor for the Resolume Mac: a Hog console sending control DMX into
//  Resolume, and Resolume's own pixel output on its way to the PCL Pixel Stix
//  processors (10.0.0.78–82, universes 0–19).
//

import SwiftUI

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

                Picker("Mode", selection: Binding(get: { store.mode },
                                                  set: { store.setMode($0) })) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Divider()

                Button("Send Test Packets") { store.sendTestPackets() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}
