import CoreBluetooth
import Foundation
import IOBluetooth

/// A byte pipe to the buds. Callbacks arrive on the main thread.
protocol Link: AnyObject {
    func write(_ bytes: [UInt8])
    func close()
}

/// Events a link reports back to `Buds`.
@MainActor
protocol LinkOwner: AnyObject {
    func linkStatus(_ text: String)
    func linkOpened(name: String?, packetAuth: Bool)
    func linkData(_ bytes: [UInt8])
    func linkClosed(_ text: String)
    /// The classic link found no earbuds service; try something else.
    func linkUnavailable(_ text: String)
}

// MARK: - Classic Bluetooth RFCOMM (service 0xFD2D tested on Redmi Buds 6 Lite before this code moved here; retest needed)

/// From: ua/i.java (ConnectionThread) and BluetoothConstant.java.
final class RfcommLink: NSObject, Link, IOBluetoothRFCOMMChannelDelegate {
    private weak var owner: LinkOwner?
    private let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    private var packetAuth = true

    /// Same order as the Xiaomi app. Bool = packet auth (0x50/0x51) instead of raw auth.
    private static let services: [(IOBluetoothSDPUUID, Bool)] = [
        (IOBluetoothSDPUUID(uuid16: 0xFD2D), true), // Redmi Buds 6 Lite (tested in the earlier build)
        // UNTESTED. From: BluetoothConstant.UUID_SPP_XIAOAI, BluetoothAuth.s() (raw auth).
        // For: XiaoAI-era Xiaomi earbuds that do not expose 0xFD2D.
        (uuid128("00001101-0000-1000-8000-008584d01810"), false),
        // UNTESTED. From: BluetoothConstant.UUID_SPP, BluetoothAuth.s() (raw auth).
        // For: earbuds that only expose the standard serial port profile.
        (IOBluetoothSDPUUID(uuid16: 0x1101), false),
    ]

    init(device: IOBluetoothDevice, owner: LinkOwner) {
        self.device = device
        self.owner = owner
        super.init()
        device.performSDPQuery(self)
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        for (uuid, packet) in Self.services {
            var id: BluetoothRFCOMMChannelID = 0
            guard let rec = device.getServiceRecord(for: uuid), rec.getRFCOMMChannelID(&id) == kIOReturnSuccess else { continue }
            packetAuth = packet
            var ch: IOBluetoothRFCOMMChannel?
            if device.openRFCOMMChannelAsync(&ch, withChannelID: id, delegate: self) == kIOReturnSuccess {
                channel = ch
                main { $0.linkStatus("Connecting…") }
                return
            }
        }
        main { $0.linkUnavailable("No serial earbuds service") }
    }

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        let name = device.name, packet = packetAuth
        main { error == kIOReturnSuccess ? $0.linkOpened(name: name, packetAuth: packet) : $0.linkClosed("Connect failed (\(error))") }
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length: Int) {
        let bytes = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: length))
        main { $0.linkData(bytes) }
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        channel = nil
        main { $0.linkClosed("Disconnected") }
    }

    func write(_ bytes: [UInt8]) {
        guard let ch = channel else { return }
        var b = bytes
        let mtu = Int(ch.getMTU())
        var i = 0
        while i < b.count {
            let n = min(mtu, b.count - i)
            _ = b.withUnsafeMutableBytes { ch.writeSync($0.baseAddress! + i, length: UInt16(n)) }
            i += n
        }
    }

    func close() {
        owner = nil // the owner already reset itself
        channel?.close()
    }

    private func main(_ f: @escaping @MainActor (LinkOwner) -> Void) {
        let owner = owner
        DispatchQueue.main.async { MainActor.assumeIsolated { if let o = owner { f(o) } } }
    }

    private static func uuid128(_ s: String) -> IOBluetoothSDPUUID {
        let u = UUID(uuidString: s)!.uuid
        var bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        return IOBluetoothSDPUUID(bytes: &bytes, length: 16)
    }
}

// MARK: - Bluetooth Low Energy GATT

// UNTESTED. From: ua/c.java (BLE connect, service/characteristic pick at the end of the file)
// and BluetoothConstant.java (UUID_SERVICE / UUID_WRITE / UUID_NOTIFICATION / *_ANBEI).
// For: Xiaomi devices that talk the same protocol over BLE service 0xAF00 instead of
// classic serial (LE-only or LE Audio earbuds). Which earbud models do this is not in the APK.
// Characteristics AF05 (write) + AF06 (notify) use raw auth; AF07 + AF08 ("anbei") use packet auth.
final class BleLink: NSObject, Link, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let service = CBUUID(string: "AF00")
    private static let pairs: [(write: CBUUID, notify: CBUUID, packetAuth: Bool)] = [
        (CBUUID(string: "AF05"), CBUUID(string: "AF06"), false),
        (CBUUID(string: "AF07"), CBUUID(string: "AF08"), true),
    ]

    private weak var owner: LinkOwner?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var packetAuth = false

    init(owner: LinkOwner) {
        self.owner = owner
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        if let p = c.retrieveConnectedPeripherals(withServices: [Self.service]).first {
            connect(p)
        } else {
            main { $0.linkStatus("Scanning Bluetooth LE…") }
            c.scanForPeripherals(withServices: [Self.service])
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        c.stopScan()
        connect(p)
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        main { $0.linkStatus("Connecting (LE)…") }
        central.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Self.service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        main { $0.linkClosed("LE connect failed") }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        main { $0.linkClosed("Disconnected") }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else { return fail(p) }
        p.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let chars = s.characteristics ?? []
        for pair in Self.pairs {
            guard let w = chars.first(where: { $0.uuid == pair.write }),
                  let n = chars.first(where: { $0.uuid == pair.notify }) else { continue }
            writeChar = w
            packetAuth = pair.packetAuth
            p.setNotifyValue(true, for: n)
            return
        }
        fail(p)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c.isNotifying else { return fail(p) }
        let name = p.name, packet = packetAuth
        main { $0.linkOpened(name: name, packetAuth: packet) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let d = c.value else { return }
        let bytes = [UInt8](d)
        main { $0.linkData(bytes) }
    }

    private func fail(_ p: CBPeripheral) {
        central.cancelPeripheralConnection(p)
        main { $0.linkClosed("No earbuds service over LE") }
    }

    func write(_ bytes: [UInt8]) {
        guard let p = peripheral, let c = writeChar else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        let mtu = p.maximumWriteValueLength(for: type)
        var i = 0
        while i < bytes.count {
            let n = min(mtu, bytes.count - i)
            p.writeValue(Data(bytes[i..<i + n]), for: c, type: type)
            i += n
        }
    }

    func close() {
        owner = nil // the owner already reset itself
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    private func main(_ f: @escaping @MainActor (LinkOwner) -> Void) {
        let owner = owner
        DispatchQueue.main.async { MainActor.assumeIsolated { if let o = owner { f(o) } } }
    }
}
