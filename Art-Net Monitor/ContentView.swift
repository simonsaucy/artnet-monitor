//
//  ContentView.swift
//  Art-Net Monitor
//
//  Deliberately no NavigationSplitView — it imposes its own materials and
//  overrides the pure-black Cueline look.
//

import SwiftUI

struct ContentView: View {

    @Environment(MonitorStore.self) private var store

    @AppStorage("universeViewMode") private var viewModeRaw = UniverseViewMode.grid.rawValue
    @AppStorage("startOnLaunch") private var startOnLaunch = false

    @State private var didRunLaunchAction = false

    private var viewMode: UniverseViewMode {
        UniverseViewMode(rawValue: viewModeRaw) ?? .grid
    }

    private var viewModeBinding: Binding<UniverseViewMode> {
        Binding(get: { viewMode }, set: { viewModeRaw = $0.rawValue })
    }

    private var modeBinding: Binding<CaptureMode> {
        Binding(get: { store.mode }, set: { store.setMode($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Cue.borderPrimary)
            content(for: viewMode)
        }
        .background(Cue.bgPrimary)
        .frame(minWidth: 520, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didRunLaunchAction else { return }
            didRunLaunchAction = true
            store.startIfConfiguredForLaunch()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            HStack(spacing: 11) {
                CueLogo()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Art-Net Monitor")
                        .font(Cue.ui(15, .bold))
                        .foregroundStyle(Cue.textPrimary)
                    Text("UDP 6454 · 32 × 16 DMX")
                        .font(Cue.mono(11))
                        .foregroundStyle(Cue.textSecondary)
                }
            }
            .fixedSize()

            CueSegmented(options: CaptureMode.allCases.map {
                (value: $0, title: $0.title, help: $0.blurb)
            }, selection: modeBinding)

            Button(store.isRunning ? "Stop" : "Start") {
                store.toggle()
            }
            .buttonStyle(CueButtonStyle(prominent: !store.isRunning,
                                        destructive: store.isRunning))
            .keyboardShortcut(.return, modifiers: [.command])

            StatusPill(text: store.statusText, tint: store.statusTint)

            startupMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Cue.bgSecondary)
    }

    private var startupMenu: some View {
        Menu {
            Toggle("Start monitoring when the app opens", isOn: $startOnLaunch)
            Toggle("Open Art-Net Monitor at login", isOn: Binding(
                get: { store.opensAtLogin },
                set: { store.setOpensAtLogin($0) }))
            Divider()
            Button("Send test packets to 127.0.0.1") { store.sendTestPackets() }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Cue.textSecondary)
                .frame(width: 30, height: 30)
                .background(Cue.bgTertiary, in: RoundedRectangle(
                    cornerRadius: Cue.radiusMedium, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Startup options and test packets")
    }

    // MARK: Body

    private func content(for mode: UniverseViewMode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            statTiles

            HStack(spacing: 8) {
                CueSegmented(options: UniverseViewMode.allCases.map {
                    (value: $0,
                     title: $0.title,
                     help: $0 == .grid ? "512 cells per universe"
                                       : "Every channel above zero, as text")
                }, selection: viewModeBinding)
                Spacer(minLength: 0)
                Text(store.mode == .capture ? "pktap · tcpdump" : "udp 6454 · shared")
                    .font(Cue.mono(10.5))
                    .foregroundStyle(Cue.textQuaternary)
                    .lineLimit(1)
            }

            universeList(mode: mode)

            SectionCaption(text: "Recent packets")
            logPane
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statTiles: some View {
        HStack(spacing: 8) {
            StatTile(value: "\(store.stats.packetsPerSecond)",
                     label: "pkts / s",
                     tint: store.stats.packetsPerSecond > 0 ? Cue.green : Cue.textPrimary)
            StatTile(value: "\(store.stats.universeCount)", label: "universes")
            StatTile(value: store.stats.totalPackets.formatted(.number),
                     label: "total")
        }
    }

    @ViewBuilder
    private func universeList(mode: UniverseViewMode) -> some View {
        if store.universes.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.universes) { universe in
                        UniverseCard(universe: universe,
                                     viewMode: mode,
                                     fadeTick: mode == .text ? store.fadeTick : 0)
                    }
                }
                .padding(.bottom, 2)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Cue.textQuaternary)
            Text(store.isRunning ? "No Art-Net yet" : "Not monitoring")
                .font(Cue.ui(17, .semibold))
                .foregroundStyle(Cue.textPrimary)
            Text(store.isRunning ? store.mode.blurb
                                 : "Pick a mode and press Start. \(store.mode.blurb)")
                .font(Cue.ui(12.5))
                .foregroundStyle(Cue.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }

    private var logPane: some View {
        ScrollView {
            Text(store.logLines.joined(separator: "\n"))
                .font(Cue.mono(11))
                .foregroundStyle(Cue.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
        }
        .frame(height: 120)
        .background(Cue.bgPrimary, in: RoundedRectangle(cornerRadius: Cue.radiusMedium,
                                                        style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Cue.radiusMedium, style: .continuous)
                .strokeBorder(Cue.borderPrimary, lineWidth: 0.5)
        }
    }
}
