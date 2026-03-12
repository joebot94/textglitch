// MidiHandler.swift — MIDI clock in/out via CoreMIDI (port of midi_handler.py)

import Foundation
import CoreMIDI
import QuartzCore

private let ppqn: Int = 24  // MIDI spec: 24 clock pulses per quarter note

final class MidiHandler {
    weak var engine: GridEngine?

    var enabled: Bool = false
    var sendEnabled: Bool = false

    // Callbacks replacing Qt signals
    var onBpmDetected: ((Double) -> Void)?
    var onPortError: ((String) -> Void)?

    private var midiClient: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var sourceEndpoint: MIDIEndpointRef = 0
    private var destEndpoint: MIDIEndpointRef = 0

    private var pulseCount: Int = 0
    private var pulsesPerTick: Int = ppqn
    private var lastClockTime: Double?
    private var bpmSamples: [Double] = []

    // MARK: - Init / Cleanup

    init() {
        MIDIClientCreateWithBlock("TextGlitch" as CFString, &midiClient) { [weak self] notification in
            self?.handleMidiNotification(notification)
        }
        MIDIOutputPortCreate(midiClient, "TextGlitch Out" as CFString, &outputPort)
    }

    func shutdown() {
        closeInput()
        closeOutput()
        if midiClient != 0 { MIDIClientDispose(midiClient) }
    }

    // MARK: - Available ports

    static func availableInputs() -> [String] {
        (0..<MIDIGetNumberOfSources()).compactMap { i -> String? in
            let src = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyName, &name)
            return name?.takeRetainedValue() as String?
        }
    }

    static func availableOutputs() -> [String] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { i -> String? in
            let dst = MIDIGetDestination(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(dst, kMIDIPropertyName, &name)
            return name?.takeRetainedValue() as String?
        }
    }

    // MARK: - Beat division

    func setBeatDivision(_ division: Double) {
        pulsesPerTick = max(1, Int(Double(ppqn) * division))
    }

    // MARK: - Input

    func openInput(portName: String) {
        closeInput()
        guard !portName.isEmpty else { return }

        // Find source endpoint by name
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyName, &cfName)
            if let name = cfName?.takeRetainedValue() as String?, name == portName {
                sourceEndpoint = src
                break
            }
        }
        guard sourceEndpoint != 0 else {
            onPortError?("MIDI input not found: \(portName)")
            return
        }

        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        let err = MIDIInputPortCreateWithBlock(midiClient, "TextGlitch In" as CFString, &inputPort) { [weak self] packetList, _ in
            self?.handlePacketList(packetList)
        }
        if err != noErr {
            onPortError?("MIDI input error: \(err)")
            return
        }
        MIDIPortConnectSource(inputPort, sourceEndpoint, selfPtr)
    }

    func closeInput() {
        if inputPort != 0 {
            MIDIPortDisconnectSource(inputPort, sourceEndpoint)
            MIDIPortDispose(inputPort)
            inputPort = 0
        }
        sourceEndpoint = 0
        pulseCount = 0
        bpmSamples.removeAll()
        lastClockTime = nil
    }

    // MARK: - Output

    func openOutput(portName: String) {
        closeOutput()
        guard !portName.isEmpty else { return }
        for i in 0..<MIDIGetNumberOfDestinations() {
            let dst = MIDIGetDestination(i)
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(dst, kMIDIPropertyName, &cfName)
            if let name = cfName?.takeRetainedValue() as String?, name == portName {
                destEndpoint = dst
                return
            }
        }
        onPortError?("MIDI output not found: \(portName)")
    }

    func closeOutput() {
        destEndpoint = 0
    }

    func sendClockPulse() {
        guard destEndpoint != 0, sendEnabled else { return }
        sendMidiBytes([0xF8])  // MIDI clock
    }

    func sendStart() {
        guard destEndpoint != 0 else { return }
        sendMidiBytes([0xFA])
    }

    func sendStop() {
        guard destEndpoint != 0 else { return }
        sendMidiBytes([0xFC])
    }

    // MARK: - Packet processing

    private func handlePacketList(_ packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            handlePacket(packet)
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private func handlePacket(_ packet: MIDIPacket) {
        let bytes = Mirror(reflecting: packet.data).children.prefix(Int(packet.length)).compactMap { $0.value as? UInt8 }
        for byte in bytes {
            switch byte {
            case 0xF8:  // MIDI Clock
                let now = CACurrentMediaTime()
                if let last = lastClockTime {
                    let interval = now - last
                    if interval > 0 {
                        let pulseBpm = 60.0 / (interval * Double(ppqn))
                        bpmSamples.append(pulseBpm)
                        if bpmSamples.count > 24 { bpmSamples.removeFirst() }
                        let avg = bpmSamples.reduce(0, +) / Double(bpmSamples.count)
                        let rounded = (avg * 10).rounded() / 10
                        DispatchQueue.main.async { [weak self] in
                            self?.onBpmDetected?(rounded)
                        }
                    }
                }
                lastClockTime = now

                if enabled {
                    pulseCount += 1
                    if pulseCount >= pulsesPerTick {
                        pulseCount = 0
                        engine?.externalTick()
                    }
                }

            case 0xFA, 0xFB:  // Start / Continue
                pulseCount = 0
                bpmSamples.removeAll()
                lastClockTime = nil

            default:
                break
            }
        }
    }

    // MARK: - Send helper

    private func sendMidiBytes(_ bytes: [UInt8]) {
        guard destEndpoint != 0 else { return }
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        packet = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
        MIDISend(outputPort, destEndpoint, &packetList)
    }

    private func handleMidiNotification(_ notification: UnsafePointer<MIDINotification>) {
        // Handle device connection/disconnection if needed
    }
}
