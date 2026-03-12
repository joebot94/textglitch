// OscHandler.swift — Bidirectional OSC via Network.framework (port of osc_handler.py)

import Foundation
import Network

final class OscHandler {
    weak var engine: GridEngine?
    var presetSwitcher: AutoPresetSwitcher?

    var receiveEnabled: Bool = false
    var sendEnabled: Bool = false

    var receiveIP: String = "0.0.0.0"
    var receivePort: Int = 8000
    var sendIP: String = "192.168.1.1"
    var sendPort: Int = 8001

    // Callbacks
    var onStatusChanged: ((String) -> Void)?

    private var listener: NWListener?
    private var sendConnection: NWConnection?
    private let queue = DispatchQueue(label: "osc", qos: .userInitiated)

    // MARK: - Server

    func startServer(ip: String = "0.0.0.0", port: Int = 8000) {
        stopServer()
        receiveEnabled = true
        receiveIP = ip
        receivePort = port

        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? 8000
            listener = try NWListener(using: params, on: nwPort)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleIncoming(conn)
            }
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStatusChanged?("OSC server listening on \(ip):\(port)")
                case .failed(let err):
                    self?.onStatusChanged?("OSC server error: \(err)")
                default: break
                }
            }
            listener?.start(queue: queue)
        } catch {
            onStatusChanged?("OSC listener error: \(error)")
        }
    }

    func stopServer() {
        listener?.cancel()
        listener = nil
        receiveEnabled = false
        onStatusChanged?("OSC server stopped")
    }

    // MARK: - Client

    func openClient(ip: String, port: Int) {
        sendConnection?.cancel()
        let host = NWEndpoint.Host(ip)
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? 8001
        sendConnection = NWConnection(host: host, port: nwPort, using: .udp)
        sendConnection?.start(queue: queue)
        sendIP = ip
        sendPort = port
        onStatusChanged?("OSC client → \(ip):\(port)")
    }

    func closeClient() {
        sendConnection?.cancel()
        sendConnection = nil
    }

    // MARK: - Send

    func send(address: String, args: [OscArg] = []) {
        guard sendEnabled, let conn = sendConnection else { return }
        let data = buildOscPacket(address: address, args: args)
        conn.send(content: data, completion: .idempotent)
    }

    func sendBeat(_ pointer: Int) {
        if sendEnabled { send(address: "/textgrid/beat", args: [.int(Int32(pointer))]) }
    }

    func sendState(_ playing: Bool) {
        if sendEnabled { send(address: "/textgrid/state", args: [.string(playing ? "playing" : "stopped")]) }
    }

    // MARK: - Incoming connection handling

    private func handleIncoming(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveData(conn)
    }

    private func receiveData(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            if let data = data, !data.isEmpty {
                self?.parseOscPacket(data)
            }
            self?.receiveData(conn)
        }
    }

    // MARK: - OSC parsing

    private func parseOscPacket(_ data: Data) {
        guard let (address, args) = parseOsc(data) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.dispatchOsc(address: address, args: args)
        }
    }

    private func dispatchOsc(address: String, args: [OscArg]) {
        guard let engine = engine else { return }
        switch address {
        case "/textgrid/play":   engine.play()
        case "/textgrid/stop":   engine.stop()
        case "/textgrid/tick":   engine.externalTick()
        case "/textgrid/reset":  engine.reset()

        case "/textgrid/bpm":
            if case .float(let v) = args.first {
                let bpm = max(40, min(300, Double(v)))
                engine.bpm = bpm
                engine.bpmSync = true
                engine.updateSpeed()
            }

        case "/textgrid/preset":
            if case .string(let name) = args.first {
                let canonical = normalizePresetName(name)
                if presetNames.contains(canonical) {
                    if let ps = presetSwitcher {
                        ps.applyManualPreset(canonical, source: "osc")
                    } else {
                        engine.setPreset(canonical, emitDisplay: true)
                    }
                }
            }

        case "/textgrid/grid":
            if case .string(let name) = args.first {
                engine.setGridProfile(name)
            }

        case "/textgrid/pointer":
            if case .int(let v) = args.first {
                let n = max(1, engine.tokens.count)
                engine.pointer = Int(v) % n
                engine.ticked.send(engine.pointer)
            }

        case "/textgrid/speed":
            if case .int(let v) = args.first {
                engine.speedMs = max(16, Int(v))
                engine.bpmSync = false
                engine.updateSpeed()
            }

        case "/textgrid/blank":
            let indices = parseCellIndices(args: args, cellCount: engine.cellCount)
            engine.setCellsBlank(indices, blank: true)

        case "/textgrid/unblank":
            let indices = parseCellIndices(args: args, cellCount: engine.cellCount)
            engine.setCellsBlank(indices, blank: false)

        case "/textgrid/clear_blanks":
            engine.clearBlanks()

        default: break
        }
    }

    private func parseCellIndices(args: [OscArg], cellCount: Int) -> [Int] {
        var values: [Int] = []
        for arg in args {
            switch arg {
            case .int(let v):    values.append(Int(v))
            case .string(let s): values += s.components(separatedBy: CharacterSet(charactersIn: ",; ")).compactMap { Int($0) }
            default: break
            }
        }
        // 1-based correction
        if !values.isEmpty, !values.contains(0), values.min()! >= 1, values.max()! <= cellCount {
            values = values.map { $0 - 1 }
        }
        var seen = Set<Int>()
        return values.filter { 0 <= $0 && $0 < cellCount && seen.insert($0).inserted }
    }

    func shutdown() {
        stopServer()
        closeClient()
    }
}

// MARK: - OSC packet types

enum OscArg {
    case int(Int32)
    case float(Float)
    case string(String)
}

// MARK: - OSC wire format (minimal implementation)

private func buildOscPacket(address: String, args: [OscArg]) -> Data {
    var data = Data()

    func padTo4(_ d: inout Data) {
        while d.count % 4 != 0 { d.append(0) }
    }

    // Address
    var addrData = (address + "\0").data(using: .utf8)!
    padTo4(&addrData)
    data.append(addrData)

    // Type tag string
    var typeTags = ","
    for arg in args {
        switch arg {
        case .int:    typeTags += "i"
        case .float:  typeTags += "f"
        case .string: typeTags += "s"
        }
    }
    var tagData = (typeTags + "\0").data(using: .utf8)!
    padTo4(&tagData)
    data.append(tagData)

    // Arguments
    for arg in args {
        switch arg {
        case .int(let v):
            var big = v.bigEndian
            data.append(Data(bytes: &big, count: 4))
        case .float(let v):
            var bits = v.bitPattern.bigEndian
            data.append(Data(bytes: &bits, count: 4))
        case .string(let s):
            var sData = (s + "\0").data(using: .utf8)!
            padTo4(&sData)
            data.append(sData)
        }
    }
    return data
}

private func parseOsc(_ data: Data) -> (String, [OscArg])? {
    var offset = 0

    func readPaddedString() -> String? {
        guard offset < data.count else { return nil }
        var end = offset
        while end < data.count && data[end] != 0 { end += 1 }
        let s = String(data: data[offset..<end], encoding: .utf8)
        offset = end + 1
        while offset % 4 != 0 { offset += 1 }
        return s
    }

    guard let address = readPaddedString(), address.hasPrefix("/") else { return nil }
    guard let typeTags = readPaddedString(), typeTags.hasPrefix(",") else { return nil }

    var args: [OscArg] = []
    for tag in typeTags.dropFirst() {
        guard offset + 4 <= data.count else { break }
        switch tag {
        case "i":
            let v = data[offset..<offset+4].withUnsafeBytes { $0.load(as: Int32.self) }.bigEndian
            args.append(.int(v)); offset += 4
        case "f":
            let bits = data[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
            args.append(.float(Float(bitPattern: bits))); offset += 4
        case "s":
            if let s = readPaddedString() { args.append(.string(s)) }
        default: break
        }
    }
    return (address, args)
}
