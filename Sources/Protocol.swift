import Foundation

// Xiaomi earphone protocol ("RCSP" from the aivs SDK in the Xiaomi Earbuds app).
// Frame: FE DC BA | flags | opcode | len (2, big endian) | payload | EF
//   flags: bit7 = command (0 = response), bit6 = wants response, low 3 bits = role (4 = earphone app)
//   command payload:  sn | params
//   response payload: status | sn | params

enum Op {
    static let getTargetInfo: UInt8 = 0x02
    static let setTargetInfo: UInt8 = 0x08 // params: attrs [len][type][value]; type 4 = ANC mode
    static let reportDeviceStatus: UInt8 = 0x0E
    static let authCheck: UInt8 = 0x50
    static let authResult: UInt8 = 0x51
    static let vendorExtend: UInt8 = 0xF1 // params: vendorID (2) | productID (2) | customOp | data
    static let setConfig: UInt8 = 0xF2
    static let getConfig: UInt8 = 0xF3
    static let notifyConfig: UInt8 = 0xF4
}

enum ConfigID {
    static let noiseLevel: UInt16 = 11 // value: [mode, level]
}

/// GetTargetInfo attribute types (va/f.java D(), parseTargetInfo).
enum Attr {
    static let vidPid: UInt8 = 3 // vendorID (2) | productID (2)
    static let battery: UInt8 = 7
}

// Vendor command sets in the APK that are NOT implemented, because they have no battery or
// noise control feature (com/xiaomi/aivsbluetoothsdk/protocol/vendor*, constant/Vendor*Cmd.java):
//   JieLi AI2000 (pid 8452, "COOWOO"): device info + FM frequency.
//   JieLi Anbei (pid 13503): one key-press command.
//   JieLi S18 (vendor 0x2717, pid 13500): voice data, virtual address, wake-up notices.
//   OneMore (1MORE Air2 S / Air2 Pro / Air2 Pokemon, pid 20506/20508/20512): device info, autoplay.
//   ZiMi alarm clock commands (alarms, reminders, countdown, light, brightness, time sync).
//   ZiMi earbuds extras other than ANC turbo: EQ mode, game mode, key function, auto volume, find phone.

// UNTESTED. From: constant/ThirdPartyVendor.java, protocol/vendorZiMi/param/ZiMiTwsSetAncTurboParam.java,
// protocol/rcsp/baseExt/VendorCommonParam.java, VendorCmdWithResponse.java (opcode 241 = 0xF1).
// For: ZMI (ZiMi, vendor 0x5A4D) earbuds. The Xiaomi Earbuds app never calls this command, so the
// mode byte values are a guess (0 = off, 1 = on).
enum ZiMi {
    static let vendorID: UInt16 = 0x5A4D
    static let ancTurboOp: UInt8 = 85
    /// Product IDs from ThirdPartyVendor.java. NZBT01 (0xAC01) is left out: the SDK treats it as the alarm clock.
    /// shortcut: the APK does not say which of these are earbuds; "TW" names suggest TW100/TW101 are.
    static let earbudProducts: Set<UInt16> = [0xBA02, 0xBA03, 0xBA04, 0xEA01, 0xEA02, 0xEA03] // B508 B608 WBS02 TW100 TW101 K76

    static func ancTurbo(productID: UInt16, on: Bool) -> [UInt8] {
        [UInt8(vendorID >> 8), UInt8(vendorID & 0xFF), UInt8(productID >> 8), UInt8(productID & 0xFF), ancTurboOp, on ? 1 : 0]
    }
}

// UNTESTED on Redmi Buds 6 Lite levels. From: bluetoothsdk/setting/function/NoiseLevelConstants.java,
// FunctionConfigImpl.noiseLevel(), settings/ui/noise/NoiseReductionVM.setNoiseLevel().
// Sent as SetDeviceConfig config 11 = [mode, level]. For: models with a noise level choice in the
// Xiaomi app (which models is decided by Xiaomi's server, not the APK). Buds without levels ignore it.
enum ANCLevel {
    static let noiseCancelling: [(UInt8, String)] = [
        (0, "Balanced"), (1, "Light"), (2, "Deep"), (5, "Deep+"), (3, "Adaptive"), (4, "Anti-wind"),
    ]
    static let transparency: [(UInt8, String)] = [
        (0, "Transparent"), (1, "Voice enhancement"), (3, "Voice enhancement+"), (2, "Ambient enhancement"),
    ]

    /// Levels the model offers, in the Xiaomi app's display order. Unknown model: every named level.
    static func options(for mode: ANCMode, vendorID: UInt16?, productID: UInt16?) -> [(UInt8, String)] {
        let all = mode == .noiseCancelling ? noiseCancelling : mode == .transparency ? transparency : []
        guard mode != .off, let model = Models.find(vendorID, productID) else { return all }
        let levels = (mode == .noiseCancelling ? model.noise : model.transparency) ?? []
        // shortcut: 20-step models use a depth scale whose meaning is not in the APK, so show plain numbers.
        if levels.count == 20 { return levels.map { ($0, "Level \($0)") } }
        let names = Dictionary(all, uniquingKeysWith: { a, _ in a })
        return levels.map { ($0, names[$0] ?? "Level \($0)") }
    }
}

/// Noise levels per model ("tws_gear" in func_list, funcs 1002/1003/1006/1007 = noise, 1004/1005 = transparency).
/// From: Xiaomi server POST https://sg.tws.wear.xiaomiwear.com/twswear/product/get_product_list
/// (com/mi/earphone/device/manager/net/DeviceService.java), snapshot 2026-11-04.
/// shortcut: a fixed snapshot; new models fall back to all named levels. Refresh by re-running that request.
/// UNTESTED except Redmi Buds 6 Lite (no levels, so the picker hides).
enum Models {
    struct Info {
        let name: String
        let noise: [UInt8]?
        let transparency: [UInt8]?
    }

    static let table: [UInt32: Info] = {
        let rows: [(UInt16, UInt16, String, [UInt8]?, [UInt8]?)] = [
            (0x5A4D, 0xEA0F, "Redmi Buds 4 Pro", [1, 0, 2], [0, 1]),
            (0x2717, 0x5037, "Redmi Buds 4", [1, 0, 2], [0, 1]),
            (0x2717, 0x502B, "Xiaomi Buds 3", [1, 0, 2, 4], [0, 1]),
            (0x2717, 0x502D, "Xiaomi Buds 3T Pro", [1, 0, 2], [0, 1]),
            (0x2717, 0x503B, "Xiaomi Buds 4 Pro", [0, 1, 2, 3, 4, 5], [0, 1, 2]),
            (0x2717, 0x505A, "Xiaomi Buds 3 Star Wars", [1, 0, 2, 4], [0, 1]),
            (0x2717, 0x505F, "Redmi Buds 4 Active", nil, nil),
            (0x2717, 0x5075, "Redmi Buds 5", [1, 0, 2], [0, 1, 2]),
            (0x2717, 0x5082, "Xiaomi Buds 5", [0, 2], nil),
            (0x2717, 0x506D, "Redmi Buds 5 Pro", [1, 0, 2], [0, 1, 2]),
            (0x2717, 0x5089, "Redmi Buds 6 Active", nil, nil),
            (0x2717, 0x508B, "Redmi Buds 6 Lite", [0], [0]),
            (0x2717, 0x5080, "Xiaomi OpenWear Stereo", nil, nil),
            (0x2717, 0x50A0, "Redmi Buds 6", [1, 0, 2], [0, 1, 2]),
            (0x2717, 0x50AC, "Xiaomi Buds 5 Pro Wi-Fi", Array(0...19), [0, 1, 2]),
            (0x2717, 0x509B, "Redmi Buds 6 Play", nil, nil),
            (0x2717, 0x50B4, "Xiaomi Buds 5 Pro", Array(0...19), [0, 1, 2]),
            (0x2717, 0x509E, "Redmi Buds 6 Pro", Array(0...19), [0, 1, 2]),
            (0x2717, 0x50E5, "REDMI Buds 8 Pro", Array(0...19), [0, 1, 2]),
            (0x2717, 0x50E2, "REDMI Buds 8 Active", nil, nil),
            (0x2717, 0x50D7, "Xiaomi OpenWear Stereo Pro", nil, nil),
            (0x2717, 0x50EB, "Xiaomi Buds 6", [0, 2], nil),
            (0x2717, 0x50F0, "REDMI Headphones Neo", [1, 0, 2], [0]),
            (0x2717, 0x50EF, "REDMI Buds 8 Lite", [0], [0]),
            (0x2717, 0x50DC, "Xiaomi Clip", nil, nil),
            (0x2717, 0x50F3, "REDMI Buds 8", [1, 0, 2], [0, 1, 2]),
        ]
        return Dictionary(uniqueKeysWithValues: rows.map { (UInt32($0.0) << 16 | UInt32($0.1), Info(name: $0.2, noise: $0.3, transparency: $0.4)) })
    }()

    /// Known model with no noise control feature in the server list.
    static func hasNoNoiseControl(vendorID: UInt16?, productID: UInt16?) -> Bool {
        guard let m = find(vendorID, productID) else { return false }
        return m.noise == nil && m.transparency == nil
    }

    static func find(_ vendorID: UInt16?, _ productID: UInt16?) -> Info? {
        guard let v = vendorID, let p = productID else { return nil }
        return table[UInt32(v) << 16 | UInt32(p)]
    }
}

enum ANCMode: UInt8, CaseIterable {
    // Case order is the menu order.
    case noiseCancelling = 1, off = 0, transparency = 2

    var title: String {
        switch self {
        case .off: "Off"
        case .noiseCancelling: "Noise Cancelling"
        case .transparency: "Transparency"
        }
    }
}

struct Packet: Equatable {
    var isCommand: Bool
    var wantsResponse: Bool
    var opcode: UInt8
    var status: UInt8 = 0 // responses only
    var sn: UInt8
    var params: [UInt8]

    static let role: UInt8 = 4

    func encode() -> [UInt8] {
        var flags = Packet.role
        if isCommand { flags |= 0x80 }
        if wantsResponse { flags |= 0x40 }
        let body = isCommand ? [sn] + params : [status, sn] + params
        let len = UInt16(body.count)
        return [0xFE, 0xDC, 0xBA, flags, opcode, UInt8(len >> 8), UInt8(len & 0xFF)] + body + [0xEF]
    }
}

/// Splits a byte stream into packets. Keeps partial data between calls.
struct PacketReader {
    private var buf: [UInt8] = []

    mutating func feed(_ data: [UInt8]) -> [Packet] {
        buf += data
        var out: [Packet] = []
        while true {
            guard let start = findHeader() else {
                buf = Array(buf.suffix(2)) // header may be split
                return out
            }
            buf.removeFirst(start)
            guard buf.count >= 7 else { return out }
            let len = Int(buf[5]) << 8 | Int(buf[6])
            guard buf.count >= 8 + len else { return out }
            if buf[7 + len] == 0xEF, let p = parse(flags: buf[3], opcode: buf[4], body: Array(buf[7..<7 + len])) {
                out.append(p)
                buf.removeFirst(8 + len)
            } else {
                buf.removeFirst(1) // bad frame, resync
            }
        }
    }

    private func findHeader() -> Int? {
        guard buf.count >= 3 else { return nil }
        return (0...(buf.count - 3)).first { buf[$0] == 0xFE && buf[$0 + 1] == 0xDC && buf[$0 + 2] == 0xBA }
    }

    private func parse(flags: UInt8, opcode: UInt8, body: [UInt8]) -> Packet? {
        let isCommand = flags & 0x80 != 0
        let wants = flags & 0x40 != 0
        if isCommand {
            guard body.count >= 1 else { return nil }
            return Packet(isCommand: true, wantsResponse: wants, opcode: opcode, sn: body[0], params: Array(body.dropFirst()))
        }
        guard body.count >= 2 else { return nil }
        return Packet(isCommand: false, wantsResponse: wants, opcode: opcode, status: body[0], sn: body[1], params: Array(body.dropFirst(2)))
    }
}

// MARK: - Payload helpers

enum Payload {
    /// Config list item: [len][type (2)][value], len counts type + value.
    static func config(_ type: UInt16, _ value: [UInt8]) -> [UInt8] {
        [UInt8(value.count + 2), UInt8(type >> 8), UInt8(type & 0xFF)] + value
    }

    static func parseConfigs(_ b: [UInt8]) -> [UInt16: [UInt8]] {
        var out: [UInt16: [UInt8]] = [:]
        var i = 0
        while i + 3 <= b.count {
            let len = Int(b[i])
            guard len >= 2, len != 255, i + 1 + len <= b.count else { break }
            out[UInt16(b[i + 1]) << 8 | UInt16(b[i + 2])] = Array(b[(i + 3)..<(i + 1 + len)])
            i += 1 + len
        }
        return out
    }

    /// Attribute list: [len][type][value], len counts type + value.
    static func parseAttrs(_ b: [UInt8]) -> [UInt8: [UInt8]] {
        var out: [UInt8: [UInt8]] = [:]
        var i = 0
        while i + 2 <= b.count {
            let len = Int(b[i])
            guard len >= 1, i + 1 + len <= b.count else { break }
            out[b[i + 1]] = Array(b[(i + 2)..<(i + 1 + len)])
            i += 1 + len
        }
        return out
    }
}

struct Battery: Equatable {
    var percent: Int
    var charging: Bool

    /// Byte: bit7 = charging, low 7 bits = percent, 0xFF = not present.
    init?(byte: UInt8) {
        guard byte != 0xFF else { return nil }
        percent = Int(byte & 0x7F)
        charging = byte & 0x80 != 0
    }
}

// MARK: - Auth (Bluetooth E21 / SAFER+, as in libxm_bluetooth.so)

enum Auth {
    static let address: [UInt8] = [0x11, 0x22, 0x33, 0x33, 0x22, 0x11]

    /// Answer to a 16-byte challenge.
    static func respond(_ rand: [UInt8]) -> [UInt8] {
        precondition(rand.count == 16)
        var key = rand
        key[15] ^= 6
        return SaferPlus.arPrime(key: key, data: (0..<16).map { address[$0 % 6] })
    }

    static func randomChallenge() -> [UInt8] {
        (0..<16).map { _ in UInt8.random(in: 0...255) }
    }
}

enum SaferPlus {
    static let (exp, log): ([UInt8], [UInt8]) = {
        var e = [UInt8](repeating: 0, count: 256), l = [UInt8](repeating: 0, count: 256)
        var v = 1
        for i in 0..<256 {
            e[i] = UInt8(v % 256)
            l[v % 256] = UInt8(i)
            v = v * 45 % 257
        }
        return (e, l)
    }()
    static let perm = [8, 11, 12, 15, 2, 1, 6, 5, 10, 9, 14, 13, 0, 7, 4, 3]
    static let xorPos: Set<Int> = [0, 3, 4, 7, 8, 11, 12, 15]

    static func keySchedule(_ key: [UInt8]) -> [[UInt8]] {
        var k = key + [key.reduce(0, ^)]
        var keys = [Array(k[0..<16])]
        for p in 2...17 {
            k = k.map { $0 << 3 | $0 >> 5 }
            keys.append((0..<16).map { i in k[(p - 1 + i) % 17] &+ exp[Int(exp[(17 * p + i + 1) % 256])] })
        }
        return keys
    }

    static func mix(_ x: [UInt8], _ k: [UInt8]) -> [UInt8] {
        (0..<16).map { xorPos.contains($0) ? x[$0] ^ k[$0] : x[$0] &+ k[$0] }
    }

    static func round(_ x: [UInt8], _ k1: [UInt8], _ k2: [UInt8]) -> [UInt8] {
        var y = (0..<16).map { i in
            xorPos.contains(i) ? exp[Int(x[i] ^ k1[i])] &+ k2[i] : log[Int(x[i] &+ k1[i])] ^ k2[i]
        }
        for level in 0..<4 {
            var z = [UInt8](repeating: 0, count: 16)
            for j in stride(from: 0, to: 16, by: 2) {
                z[j] = 2 &* y[j] &+ y[j + 1]
                z[j + 1] = y[j] &+ y[j + 1]
            }
            y = level < 3 ? perm.map { z[$0] } : z
        }
        return y
    }

    /// Ar' : SAFER+ where the input is added back before round 3.
    static func arPrime(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let ks = keySchedule(key)
        var x = data
        for r in 0..<8 {
            if r == 2 { x = mix(x, data) }
            x = round(x, ks[2 * r], ks[2 * r + 1])
        }
        return mix(x, ks[16])
    }
}
