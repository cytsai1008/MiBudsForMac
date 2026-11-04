import Foundation
import IOBluetooth

/// One session with a Xiaomi / Redmi earbud, over classic RFCOMM or BLE.
@MainActor
final class Buds: NSObject, ObservableObject, LinkOwner {
    @Published var deviceName: String?
    @Published var status = "Not connected"
    @Published var ready = false
    @Published var left: Battery?
    @Published var right: Battery?
    @Published var box: Battery?
    /// The buds send no case level while both are out of the case; then `box` is the last known level.
    @Published var boxIsOld = false
    @Published var anc: ANCMode?
    @Published var ancLevel: UInt8?
    @Published var vendorID: UInt16?
    @Published var productID: UInt16?
    @Published var ancTurbo = false

    var isZiMiEarbuds: Bool {
        vendorID == ZiMi.vendorID && productID.map(ZiMi.earbudProducts.contains) == true
    }

    private var link: Link?
    private var reader = PacketReader()
    private var sn: UInt8 = 0
    /// Packet auth (opcodes 0x50/0x51) or raw JieLi auth; the link decides.
    private var packetAuth = true
    private var challenge: [UInt8] = []
    private var rawStage = 0
    private var pollTimer: Timer?
    private var disconnectNote: IOBluetoothUserNotification?

    override init() {
        super.init()
        // macOS owns the Bluetooth connection; we attach when it connects the buds.
        IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        attach()
        // Refresh battery, and retry if the channel dropped while the buds stay connected.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ready == true ? self?.requestStatus() : self?.retry() }
        }
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Self.looksLikeBuds(device.name) else { return }
        // Right after connecting, the buds refuse the serial channel for a moment (error 911).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.attach() }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        disconnectNote = nil
        link?.close()
        reset("Not connected")
        box = nil
        boxIsOld = false
    }

    private func retry() {
        link?.close()
        reset("Not connected")
        attach()
    }

    /// Open our channel on buds that macOS has already connected.
    private func attach() {
        guard link == nil else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let dev = paired.first(where: { $0.isConnected() && Self.looksLikeBuds($0.name) }) else {
            status = "Not connected"
            return
        }
        deviceName = dev.name
        status = "Looking for service…"
        disconnectNote?.unregister()
        disconnectNote = dev.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        let l = RfcommLink(device: dev, owner: self)
        link = l
        // IOBluetooth can fail the open (error 911) without any callback, so try again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if let self, self.link === l, !self.ready { self.retry() }
        }
    }

    private func startBle() {
        status = "Looking for buds…"
        link = BleLink(owner: self)
    }

    static func looksLikeBuds(_ name: String?) -> Bool {
        guard let n = name?.lowercased() else { return false }
        return n.contains("buds") || n.contains("xiaomi") || n.contains("redmi")
    }

    private func reset(_ msg: String) {
        link = nil
        ready = false
        rawStage = 0
        reader = PacketReader()
        status = msg
    }

    // MARK: LinkOwner

    func linkStatus(_ text: String) { status = text }

    func linkUnavailable(_ text: String) {
        link = nil
        startBle()
    }

    func linkClosed(_ text: String) { reset(text) }

    func linkOpened(name: String?, packetAuth: Bool) {
        if let name { deviceName = name }
        self.packetAuth = packetAuth
        status = "Authenticating…"
        challenge = Auth.randomChallenge()
        if packetAuth {
            send(Op.authCheck, [1] + challenge)
        } else {
            rawStage = 1
            link?.write([0] + challenge)
        }
    }

    func linkData(_ bytes: [UInt8]) {
        if !packetAuth && rawStage > 0 && bytes.first != 0xFE {
            return rawAuth(bytes)
        }
        for p in reader.feed(bytes) { handle(p) }
    }

    // MARK: Protocol

    // UNTESTED. From: impl/BluetoothAuth.java s() and v() (the path used when ta.a.n() is false).
    // For: buds reached over plain SPP (0x1101 / XiaoAI UUID) or BLE AF05/AF06.
    // We challenge, buds answer; we send "\x02pass"; buds challenge, we answer; buds send "\x02pass".
    private func rawAuth(_ b: [UInt8]) {
        let pass: [UInt8] = [2] + Array("pass".utf8)
        switch rawStage {
        case 1 where b == [1] + Auth.respond(challenge):
            link?.write(pass)
            rawStage = 2
        case 2 where b.count == 17 && b[0] == 0:
            link?.write([1] + Auth.respond(Array(b[1...])))
            rawStage = 3
        case 3 where b.starts(with: pass):
            rawStage = 0
            authenticated()
        default:
            status = "Authentication failed"
            link?.close()
        }
    }

    private func handle(_ p: Packet) {
        switch (p.isCommand, p.opcode) {
        case (false, Op.authCheck):
            let ok = p.params.count >= 17 && Array(p.params[1..<17]) == Auth.respond(challenge)
            send(Op.authResult, [1, ok ? 0 : 1])
            if !ok { status = "Authentication failed" }
        case (true, Op.authCheck) where p.params.count >= 17:
            respond(p, [1] + Auth.respond(Array(p.params[1..<17])))
        case (true, Op.authResult):
            respond(p, [1])
            if p.params.count >= 2 && p.params[1] == 0 { authenticated() } else { status = "Authentication failed" }
        case (false, Op.getTargetInfo):
            let attrs = Payload.parseAttrs(p.params)
            if let b = attrs[Attr.battery] { setBattery(b) }
            if let v = attrs[Attr.vidPid], v.count == 4 {
                vendorID = UInt16(v[0]) << 8 | UInt16(v[1])
                productID = UInt16(v[2]) << 8 | UInt16(v[3])
            }
        case (false, Op.getConfig), (true, Op.notifyConfig):
            if let v = Payload.parseConfigs(p.params)[ConfigID.noiseLevel] { setANC(v) }
            if p.isCommand { respond(p, []) }
        case (true, Op.reportDeviceStatus):
            let attrs = Payload.parseAttrs(p.params)
            if let b = attrs[0] { setBattery(b) }
            if let a = attrs[4]?.first, let m = ANCMode(rawValue: a) { anc = m }
            respond(p, [])
        case (true, _):
            respond(p, []) // ack anything else the buds ask about
        default:
            break
        }
    }

    private func authenticated() {
        ready = true
        status = "Connected"
        requestStatus()
    }

    func requestStatus() {
        send(Op.getTargetInfo, [0xFF, 0xFF, 0xFF, 0xFF])
        send(Op.getConfig, [UInt8(ConfigID.noiseLevel >> 8), UInt8(ConfigID.noiseLevel & 0xFF)])
    }

    /// Tested on Redmi Buds 6 Lite with the build before Links.swift; retest needed. Same as the Xiaomi app's updateNoise(): vendor attr type 4, length 2.
    func setANC(_ mode: ANCMode) {
        send(Op.setTargetInfo, [2, 4, mode.rawValue])
        anc = mode
        ancLevel = nil
        send(Op.getConfig, [UInt8(ConfigID.noiseLevel >> 8), UInt8(ConfigID.noiseLevel & 0xFF)]) // read back the level
    }

    /// UNTESTED. See ANCLevel in Protocol.swift.
    func setANCLevel(_ level: UInt8) {
        guard let mode = anc, mode != .off else { return }
        send(Op.setConfig, Payload.config(ConfigID.noiseLevel, [mode.rawValue, level]))
        ancLevel = level
    }

    /// UNTESTED. See ZiMi in Protocol.swift.
    func setANCTurbo(_ on: Bool) {
        guard isZiMiEarbuds, let pid = productID else { return }
        send(Op.vendorExtend, ZiMi.ancTurbo(productID: pid, on: on))
        ancTurbo = on
    }

    private func setANC(_ v: [UInt8]) {
        guard let m = v.first.flatMap(ANCMode.init(rawValue:)) else { return }
        anc = m
        ancLevel = v.count > 1 && m != .off ? v[1] : nil
    }

    private func setBattery(_ b: [UInt8]) {
        let list = b.map(Battery.init(byte:))
        if list.count > 0 { left = list[0] }
        if list.count > 1 { right = list[1] }
        if list.count > 2 {
            if let c = list[2] {
                box = c
                boxIsOld = false
            } else if box != nil {
                box?.charging = false
                boxIsOld = true
            }
        }
    }

    private func send(_ op: UInt8, _ params: [UInt8]) {
        sn &+= 1
        link?.write(Packet(isCommand: true, wantsResponse: true, opcode: op, sn: sn, params: params).encode())
    }

    private func respond(_ p: Packet, _ params: [UInt8]) {
        guard p.wantsResponse else { return }
        link?.write(Packet(isCommand: false, wantsResponse: false, opcode: p.opcode, sn: p.sn, params: params).encode())
    }
}
