//
//  ArtNet.swift
//  Art-Net Monitor
//
//  Art-Net wire-format parsing. Everything here is `nonisolated` — it runs on
//  the capture threads, never on the main actor.
//

import Foundation

/// The 8-byte Art-Net magic: "Art-Net" plus a NUL.
nonisolated let artNetHeader: [UInt8] = Array("Art-Net".utf8) + [0]

/// Human names for the opcodes we might see. Opcode is little-endian UInt16 at
/// offset 8 of every Art-Net packet.
nonisolated func artNetOpcodeName(_ op: UInt16) -> String {
    switch op {
    case 0x2000: return "ArtPoll"
    case 0x2100: return "ArtPollReply"
    case 0x2300: return "ArtDiagData"
    case 0x2400: return "ArtCommand"
    case 0x5000: return "ArtDmx"
    case 0x5100: return "ArtNzs"
    case 0x5200: return "ArtSync"
    case 0x6000: return "ArtAddress"
    case 0x7000: return "ArtInput"
    case 0x8000: return "ArtTodRequest"
    case 0x8100: return "ArtTodData"
    case 0x8200: return "ArtTodControl"
    case 0x8300: return "ArtRdm"
    case 0x8400: return "ArtRdmSub"
    case 0x9700: return "ArtTimeCode"
    case 0x9800: return "ArtTrigger"
    case 0xF800: return "ArtIpProg"
    case 0xF900: return "ArtIpProgReply"
    default: return String(format: "0x%04x", op)
    }
}

/// One decoded ArtDmx packet.
nonisolated struct ArtDmxPacket: Sendable {
    var sequence: Int
    /// Low byte of the port address: subnet in the high nibble, universe in the low.
    var subUni: Int
    /// Top 7 bits of the port address.
    var net: Int
    /// Number of channel bytes actually present (1...512).
    var length: Int
    /// Offset into the source buffer where channel data begins.
    var dataOffset: Int

    /// 15-bit port address, 0-based — this is the number Resolume shows.
    var universe: Int { (net << 8) | subUni }
    var subnet: Int { subUni >> 4 }
    var uni: Int { subUni & 15 }

    /// "net.subnet.uni", the triple that matches Resolume's three input fields.
    var triple: String { "\(net).\(subnet).\(uni)" }
}

/// What a single Art-Net packet turned out to be.
nonisolated enum ArtNetPacket: Sendable {
    case dmx(ArtDmxPacket)
    case other(opcode: UInt16, name: String)
}

nonisolated enum ArtNetDecoder {

    /// Index of the Art-Net header inside `bytes`, searching from `from`.
    /// Capture mode hands us whole Ethernet/IP frames, so the payload starts
    /// somewhere in the middle.
    static func headerIndex(in bytes: [UInt8], from start: Int = 0) -> Int? {
        guard bytes.count >= 12 else { return nil }
        let limit = bytes.count - artNetHeader.count
        guard start <= limit else { return nil }
        var i = start
        while i <= limit {
            if bytes[i] == 0x41 {  // 'A'
                var match = true
                for k in 1..<artNetHeader.count where bytes[i + k] != artNetHeader[k] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    /// Decode the Art-Net packet that begins at `offset`.
    static func decode(_ bytes: [UInt8], at offset: Int) -> ArtNetPacket? {
        guard bytes.count - offset >= 12 else { return nil }
        for k in 0..<artNetHeader.count where bytes[offset + k] != artNetHeader[k] {
            return nil
        }

        // Opcode: little-endian UInt16 at +8.
        let op = UInt16(bytes[offset + 8]) | (UInt16(bytes[offset + 9]) << 8)

        if op == 0x5000, bytes.count - offset >= 18 {
            let seq = Int(bytes[offset + 12])
            let subUni = Int(bytes[offset + 14])
            let net = Int(bytes[offset + 15] & 0x7F)
            // Length: big-endian UInt16 at +16.
            let declared = Int(bytes[offset + 16]) << 8 | Int(bytes[offset + 17])
            let available = bytes.count - (offset + 18)
            let length = max(0, min(declared, min(512, available)))
            return .dmx(ArtDmxPacket(sequence: seq,
                                     subUni: subUni,
                                     net: net,
                                     length: length,
                                     dataOffset: offset + 18))
        }

        return .other(opcode: op, name: artNetOpcodeName(op))
    }
}
