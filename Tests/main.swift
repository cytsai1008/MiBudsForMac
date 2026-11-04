// Run with ./build.sh test
import Foundation
// Auth vectors come from running the real libxm_bluetooth.so (arm64) under an emulator.

func hex(_ s: String) -> [UInt8] {
    stride(from: 0, to: s.count, by: 2).map {
        UInt8(s[s.index(s.startIndex, offsetBy: $0)..<s.index(s.startIndex, offsetBy: $0 + 2)], radix: 16)!
    }
}

let vectors = [
    ("00000000000000000000000000000000", "bca5905bc849392e7bf9fdcdc570ef77"),
    ("000102030405060708090a0b0c0d0e0f", "8713913c41434e091cad794a1b5d95c4"),
    ("ffeeddccbbaa99887766554433221100", "507ed059421c0502b083c60cbf7f08df"),
]
for (input, want) in vectors {
    assert(Auth.respond(hex(input)) == hex(want), "auth vector \(input)")
}

// Set ANC to noise cancelling: command, wants response, sn 5.
let anc = Packet(isCommand: true, wantsResponse: true, opcode: Op.setTargetInfo, sn: 5, params: [2, 4, 1])
assert(anc.encode() == hex("fedcbac40800040502" + "0401ef"))
assert(Payload.config(ConfigID.noiseLevel, [1, 0]) == [4, 0, 11, 1, 0])

// Reader: split frames, garbage, and a response.
var reader = PacketReader()
let resp = Packet(isCommand: false, wantsResponse: false, opcode: Op.getTargetInfo, status: 0, sn: 9,
                  params: [4, 7, 0x64, 0xD5, 0xFF])
let stream = [0x00, 0x11] + anc.encode() + resp.encode()
assert(reader.feed(Array(stream[0..<6])).isEmpty)
assert(reader.feed(Array(stream[6...])) == [anc, resp])

// Battery attr 7: left 100%, right 85% charging, case missing.
let attrs = Payload.parseAttrs(resp.params)
assert(attrs[7]!.map(Battery.init(byte:)) == [Battery(byte: 0x64), Battery(byte: 0xD5), nil])

assert(Payload.parseConfigs(Payload.config(11, [2, 0]) + Payload.config(10, [1])) == [11: [2, 0], 10: [1]])

// ZiMi ANC turbo on, ZMI TW101 (0xEA02).
assert(ZiMi.ancTurbo(productID: 0xEA02, on: true) == [0x5A, 0x4D, 0xEA, 0x02, 85, 1])
// Level set: deep noise cancelling.
assert(Packet(isCommand: true, wantsResponse: true, opcode: Op.setConfig, sn: 1,
              params: Payload.config(ConfigID.noiseLevel, [1, 2])).encode() == hex("fedcbac4f2000601" + "04000b0102ef"))
// VID/PID attr.
assert(Payload.parseAttrs([5, Attr.vidPid, 0x27, 0x17, 0x00, 0x51, 4, Attr.battery, 1, 2, 3])
       == [Attr.vidPid: [0x27, 0x17, 0x00, 0x51], Attr.battery: [1, 2, 3]])

// Model table from the Xiaomi server snapshot.
assert(ANCLevel.options(for: .noiseCancelling, vendorID: 0x2717, productID: 0x508B).count == 1) // Buds 6 Lite: no choice
assert(ANCLevel.options(for: .noiseCancelling, vendorID: 0x2717, productID: 0x5037).map(\.1) == ["Light", "Balanced", "Deep"])
assert(ANCLevel.options(for: .noiseCancelling, vendorID: 0x2717, productID: 0x509E).count == 20)
assert(ANCLevel.options(for: .transparency, vendorID: nil, productID: nil).count == 4) // unknown model: all
assert(Models.hasNoNoiseControl(vendorID: 0x2717, productID: 0x5089)) // Redmi Buds 6 Active
assert(!Models.hasNoNoiseControl(vendorID: 0x2717, productID: 0x508B))

print("self-test OK")
