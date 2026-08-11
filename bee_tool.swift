import CoreBluetooth
import Foundation

// ============================================================================
// bee-rescue — a CoreBluetooth tool to scan, connect to, and read the battery
// of a Bee wearable (bee.computer / Omi-compatible) directly from a Mac.
//
// Usage:
//   bee_tool scan       # list all nearby BLE devices (find your Bee)
//   bee_tool battery     # connect, print battery %, exit  (default)
//   bee_tool connect     # connect, dump all services/chars, stream 60s
//   bee_tool monitor <n> # print battery every <n> seconds forever
//
// UUIDs sourced from github.com/BasedHardware/omi (Bee device connection).
// ============================================================================

let BEE_SERVICE = CBUUID(string: "03D5D5C4-A86C-11EE-9D89-8F2089A49E7E")
let BEE_CONTROL = CBUUID(string: "05e1f93c-d8d0-5ed8-dd88-379e4c1a3e3e")
let BEE_AUDIO   = CBUUID(string: "b189a505-a86c-11ee-a5fb-8f2089a49e7e")
let CMD_BATTERY: UInt16 = 0xC00F

enum Mode { case scan, battery, connect, monitor(Int) }

final class BeeTool: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let mode: Mode
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var controlChar: CBCharacteristic?
    var seen = Set<UUID>()
    var finished = false

    init(mode: Mode) {
        self.mode = mode
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func finish(_ code: Int32) {
        if finished { return }
        finished = true
        exit(code)
    }

    // MARK: Central state

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            switch mode {
            case .scan:
                print("Scanning for ALL BLE devices (Ctrl-C to stop)...\n")
            default:
                print("Bluetooth on — scanning for 'Bee'...")
            }
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .poweredOff:      print("ERROR: Bluetooth is OFF. Turn it on."); finish(1)
        case .unauthorized:    print("ERROR: Bluetooth permission denied. System Settings > Privacy & Security > Bluetooth → allow Terminal."); finish(1)
        case .unsupported:     print("ERROR: BLE not supported."); finish(1)
        default:               break
        }
    }

    // MARK: Discovery

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? "(unnamed)"

        if case .scan = mode {
            if seen.insert(p.identifier).inserted {
                var extra = ""
                if let s = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
                    extra += " services=\(s.map{$0.uuidString})"
                }
                print(String(format: "%-24@ rssi=%4ddBm  %@%@", name as NSString, RSSI.intValue, p.identifier.uuidString, extra))
            }
            return
        }

        guard name.lowercased().contains("bee"), peripheral == nil else { return }
        print("Found '\(name)' rssi=\(RSSI)dBm — connecting...")
        if RSSI.intValue < -70 {
            print("  ⚠️  weak signal — move the Bee right next to your Mac")
        }
        peripheral = p
        p.delegate = self
        c.stopScan()
        c.connect(p, options: nil)
    }

    // MARK: Connection

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("Connected ✓  discovering services...")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("Connect FAILED — code=\((error as NSError?)?.code ?? -1): \(error?.localizedDescription ?? "?")")
        finish(1)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let code = (error as NSError?)?.code ?? 0
        if code == 7 {
            print("Device dropped the link (code 7) — usually a dead/near-dead battery. Charge it and retry.")
        } else if code != 0 {
            print("Disconnected — code=\(code): \(error?.localizedDescription ?? "?")")
        } else {
            print("Disconnected.")
        }
        if case .monitor = mode { return }   // monitor keeps retrying
        finish(code == 0 ? 0 : 1)
    }

    // MARK: GATT

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in p.services ?? [] {
            if case .connect = mode { print("SERVICE \(svc.uuid)") }
            p.discoverCharacteristics(nil, for: svc)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        for ch in svc.characteristics ?? [] {
            if case .connect = mode {
                var props = [String]()
                if ch.properties.contains(.read) { props.append("R") }
                if ch.properties.contains(.write) { props.append("W") }
                if ch.properties.contains(.notify) { props.append("N") }
                if ch.properties.contains(.writeWithoutResponse) { props.append("WNR") }
                print("  CHAR \(ch.uuid) [\(props.joined(separator: "|"))]")
            }
            if ch.uuid == BEE_CONTROL {
                controlChar = ch
                p.setNotifyValue(true, for: ch)
            } else if ch.uuid == BEE_AUDIO, case .connect = mode {
                p.setNotifyValue(true, for: ch)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == BEE_CONTROL, let c = controlChar else { return }
        requestBattery(p, c)
    }

    func requestBattery(_ p: CBPeripheral, _ c: CBCharacteristic) {
        let cmd: [UInt8] = [UInt8(CMD_BATTERY & 0xFF), UInt8((CMD_BATTERY >> 8) & 0xFF)]
        p.writeValue(Data(cmd), for: c, type: .withResponse)
    }

    // Parse a Bee control notification the way BasedHardware/omi does:
    //   raw = [respCode_lo, respCode_hi, ...payload]
    //   if respCode == 0x8000 (echo): payload = [cmd_lo, cmd_hi, ...actualPayload]
    // Returns (commandID, payload) or nil if too short.
    static func parseControl(_ d: [UInt8]) -> (cmd: UInt16, payload: [UInt8])? {
        guard d.count >= 2 else { return nil }
        let code = UInt16(d[0]) | (UInt16(d[1]) << 8)
        let rest = d.count > 2 ? Array(d.dropFirst(2)) : []
        if code == 0x8000 && rest.count >= 2 {
            let echoed = UInt16(rest[0]) | (UInt16(rest[1]) << 8)
            return (echoed, rest.count > 2 ? Array(rest.dropFirst(2)) : [])
        }
        return (code, rest)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        if ch.uuid == BEE_CONTROL {
            let bytes = Array(d)
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            guard let (cmd, payload) = Self.parseControl(bytes) else { return }

            // Only a battery (0xC00F) response carries [level, charging].
            guard cmd == CMD_BATTERY else {
                if case .connect = mode {
                    print("[control] raw=\(hex)  cmd=0x\(String(format:"%04X",cmd)) payload=\(payload.map{String(format:"%02X",$0)}.joined(separator:" "))")
                }
                return
            }
            guard payload.count >= 2 else {
                print("[\(Self.hhmmss())] battery response too short  raw=\(hex)")
                return
            }
            let level = payload[0], charging = payload[1] != 0
            print("[\(Self.hhmmss())] battery=\(level)%  charging=\(charging)   raw=\(hex)")
            switch mode {
            case .battery:
                finish(0)
            case .monitor(let secs):
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(secs)) { [weak self] in
                    guard let self, let p = self.peripheral, let c = self.controlChar else { return }
                    self.requestBattery(p, c)
                }
            default: break
            }
        } else if ch.uuid == BEE_AUDIO, case .connect = mode {
            print("[audio] \(d.count) bytes (AAC/ADTS)")
        }
    }

    static func hhmmss() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - main

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "battery"
let mode: Mode
switch cmd {
case "scan":    mode = .scan
case "connect": mode = .connect
case "monitor": mode = .monitor(args.count > 2 ? (Int(args[2]) ?? 180) : 180)
case "battery": mode = .battery
default:
    print("Usage: bee_tool [scan|battery|connect|monitor <seconds>]")
    exit(2)
}

let tool = BeeTool(mode: mode)

// scan/connect run for a fixed window; battery/monitor run until done
switch mode {
case .scan:    RunLoop.main.run(until: Date(timeIntervalSinceNow: 20)); print("\nScan done.")
case .connect: RunLoop.main.run(until: Date(timeIntervalSinceNow: 60)); print("\nDone.")
case .battery: RunLoop.main.run(until: Date(timeIntervalSinceNow: 25)); print("Timed out — Bee not found / not advertising."); exit(1)
case .monitor: RunLoop.main.run()   // forever
}
