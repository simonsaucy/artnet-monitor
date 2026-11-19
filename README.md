# Art-Net Monitor

A native macOS SwiftUI app that watches Art-Net on the Resolume Mac at church —
the Hog console's control DMX going into Resolume, and Resolume's own pixel
output on its way to the PCL Pixel Stix processors (10.0.0.78–82, universes
0–19). It replaces the `artnet-monitor.js` Node sidecar and its browser drawer.

Requires macOS 15 or newer. Open `Art-Net Monitor.xcodeproj` and press Run.

## The two modes

**Capture** (default, recommended). Runs
`/usr/sbin/tcpdump -i pktap -n -l -x -s 0 'udp port 6454'` as root and parses
its text output. It never binds UDP 6454, so Resolume keeps its DMX input, and
because pktap sees the wire it also shows Resolume's *outgoing* unicast to the
pixel processors.

Elevation is one `NSAppleScript` `do shell script … with administrator
privileges` call, so you get a single password prompt. tcpdump's output is
redirected into a FIFO the app creates in the temp directory and opens `O_RDWR`
(so the open doesn't block if you cancel the prompt). The app watches the
tcpdump PID with `kill(pid, 0)` — `EPERM` means alive, `ESRCH` means gone. On
Stop the app closes the FIFO and tcpdump dies on `SIGPIPE`; we can't signal a
root process ourselves.

**Listen** (fallback). A plain BSD UDP socket on `0.0.0.0:6454` with
`SO_REUSEADDR`, `SO_REUSEPORT` and `SO_BROADCAST`. It shares the port, but
macOS delivers a *unicast* datagram on a shared port to exactly one socket — if
Resolume's Art-Net input is on, Resolume usually wins. Expect broadcast only.
The UI labels this.

Do **not** replace Capture with a plain bind on 6454. We already hit this: the
monitor either sees nothing or steals Resolume's input.

## Universe numbering

The 15-bit port address is `(Net << 8) | SubUni`, 0-based, which is the number
Resolume shows. Because Resolume's three input fields only go 0–15, the app
also prints `Net.Subnet.Uni` (`subnet = SubUni >> 4`, `uni = SubUni & 15`).

Universe 21 → `0.1.5`. Universe 19 → `0.1.3`. Universe 256 → `1.0.0`.

Universes are keyed by `sourceIP|universe`, and one that has been silent for 10
seconds is dropped. Non-DMX opcodes (ArtPoll, ArtPollReply, ArtSync, …) are
named and logged at most once per source every 2 seconds.

## Architecture

- `ArtNet.swift` — wire-format decoding. 8-byte `"Art-Net\0"` header, opcode is
  little-endian `UInt16` at +8; for ArtDmx (`0x5000`) seq is at +12, SubUni at
  +14, Net at +15 & 0x7F, length is big-endian `UInt16` at +16, data from +18.
- `CaptureEngine.swift` — the one piece of shared state, behind an `NSLock`.
  Capture threads write into it; the main actor reads immutable snapshots out.
- `PktapCapture.swift` / `UDPListener.swift` — the two capture sources, each on
  its own background thread.
- `MonitorStore.swift` — the `@MainActor` store the UI observes. It snapshots
  the engine about 20 times a second; nothing is published per packet.
- `Theme.swift`, `ContentView.swift`, `UniverseCard.swift`, `FlowLayout.swift` —
  the Cueline look.

Every background type is explicitly `nonisolated`, so the project compiles
cleanly whether Default Actor Isolation is `MainActor` (it is set to `MainActor`
here, matching the current Xcode template) or `nonisolated`. Strict concurrency
is set to `complete`. Debug and Release both build with zero warnings.

The store uses `@Observable` rather than `ObservableObject`/`@Published` — same
main-actor snapshot design, but per-property observation, so the packet log
doesn't redraw every time a universe's channels change.

App Sandbox is **off** on purpose (see `Art-Net Monitor.entitlements`): the FIFO
and the AppleScript elevation both need it off.

## Testing without hardware

In the app: **Monitor ▸ Send Test Packets** (⇧⌘T), or the gear menu in the top
bar. It sends ArtDmx on universes 0, 1 and 21 plus an ArtPoll to
`127.0.0.1:6454`. Switch to **Listen**, press **Start**, then fire the test
packets — three universe cards appear, universe 21 showing `0.1.5`.

From outside the app, or from another machine:

```bash
node Tools/send-test-packets.js              # 127.0.0.1 for 5 seconds
node Tools/send-test-packets.js 10.0.0.23 20 # another Mac, 20 seconds
```

### Testing on a live network without touching fixtures

`Tools/send-test-packets.js` sends real levels on universes 0, 1 and 21 — and
0-19 are the Pixel Stix universes, so do **not** broadcast it on the lighting
network. Use the safe probe instead, which sends universe 999 with all 512
channels held at zero plus a non-soliciting ArtPoll:

```bash
node Tools/safe-broadcast-test.js 192.168.111.255 4   # your subnet broadcast
```

Nothing can light up from that, and it is enough to prove the monitor is
receiving. Verified working against the sandboxed build: universe 999 appeared
as `3.14.7` with 0 active channels.

Capture mode will **not** see loopback traffic — pktap doesn't carry it. Point
the script at the Mac's LAN address from another machine to exercise Capture.

## Checking Capture mode with the Hog

1. Leave Resolume running with its Art-Net input enabled. That's the point — the
   monitor must not disturb it.
2. Pick **Capture**, press **Start**, enter your admin password at the prompt.
   The status pill goes amber "Authorizing…", then green once tcpdump reports
   `listening on pktap`. That line appears in Recent packets.
3. Bring up a channel on the Hog. Within a second a card should appear for the
   console's IP on whatever universe it sends. Check the `Net.Subnet.Uni`
   triple matches what the Hog is set to.
4. Run a pixel cue in Resolume. You should also see cards sourced from the
   Resolume Mac's own IP on universes 0–19, heading for 10.0.0.78–82. That
   outgoing unicast is the traffic Listen mode cannot see, so it's the real
   proof Capture is working.
5. Confirm Resolume is still receiving: its DMX input should keep working the
   whole time.
6. Hover cells in Grid view to read channel and value; switch to Text view for
   a list of every channel above zero, with the most recent change called out.
7. Press **Stop**. `ps aux | grep tcpdump` should show nothing left behind.
   Quitting the app does the same cleanup.

If the prompt is cancelled, the status pill turns red and says so — no capture
starts, and the FIFO is removed.

## Startup options

The gear menu in the top bar has:

- **Start monitoring when the app opens** — auto-starts the selected mode on
  launch. With Capture selected that means a password prompt at launch.
- **Open Art-Net Monitor at login** — registers the app as a login item
  (`SMAppService`). This needs a real signing identity, which the project now
  has: automatic signing, team `T94H6C9572`, signed with
  `Apple Development: Simon Saucy`.

## Two targets

| Target | Sandbox | Modes | For |
|---|---|---|---|
| **Art-Net Monitor** | off | Capture + Listen | the Resolume Mac — the real tool |
| **Art-Net Monitor Listen** | on | Listen only | TestFlight / Mac App Store |

The TestFlight target exists because App Store Connect rejects non-sandboxed
macOS uploads with `ITMS-90296: App Sandbox not enabled`, and that check runs on
the upload itself — internal-only testing does not get an exemption. Under the
sandbox, running tcpdump as root is forbidden (App Review guideline 2.4.5(v):
"They may not request escalation to root privileges"), so Capture mode is
compiled out of that target via the `SANDBOXED` condition and the mode picker
hides itself when only one mode is available.

**What the Listen-only build can and cannot see.** It receives broadcast
Art-Net. It cannot see Resolume's unicast to the pixel processors — macOS hands
a unicast datagram on a shared port to exactly one socket, and Resolume's DMX
input wins. So it is useful for watching a console that broadcasts, and useless
for watching Resolume's pixel output. Use the full target for that.

Also note TestFlight builds expire 90 days after upload.

### Building each

```bash
xcodebuild -scheme "Art-Net Monitor"        -configuration Release build   # full
xcodebuild -scheme "Art-Net Monitor Listen" -configuration Release build   # sandboxed
```

### Getting the Listen build onto TestFlight

These steps need the Apple Developer portal, so they are yours to do:

1. Register the App ID `com.thecrossing.artnet-monitor.listen`
   (Certificates, Identifiers & Profiles > Identifiers).
2. Create an **Apple Distribution** certificate if you do not have one.
3. Create the app record in App Store Connect using that bundle ID.
4. In Xcode pick the **Art-Net Monitor Listen** scheme, Product > Archive, then
   Distribute App > **TestFlight (Internal Only)**.
5. Add yourself and your machines as internal testers.

If certificate creation fails with *"This operation can only be performed by the
Account Holder"* on an individual membership — where you are the Account Holder —
check <https://developer.apple.com/account> for a pending Apple Developer Program
License Agreement and accept it, then sign out and back in under
Xcode > Settings > Accounts.

## Signing

Automatic signing, team `T94H6C9572`. A Development certificate is enough to
build and run it here and on any Mac in the team's provisioning. It is **not**
Developer ID, so copying the built `.app` to an unprovisioned Mac still trips
Gatekeeper — on the Resolume Mac, clone this repo and build it there, or get a
Developer ID certificate and switch the target over.

## Regenerating the app icon

`Tools/make-app-icon.swift` draws the Cueline mark and writes the PNG sizes:

```bash
swift Tools/make-app-icon.swift /tmp/icons
```

Then copy them into `Art-Net Monitor/Assets.xcassets/AppIcon.appiconset/`.

## Reference

The behaviour this app matches lives in the Webserver folder next door:
`artnet-monitor.js` and the Art-Net drawer in `index.html`.
