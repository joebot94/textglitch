// AudioHandler.swift — Real-time beat detection via AVAudioEngine (port of audio_handler.py)

import Foundation
import AVFoundation
import Accelerate

final class AudioHandler {
    weak var engine: GridEngine?

    var enabled: Bool = false

    // Callbacks
    var onBpmDetected: ((Double) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onError: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var isRunning = false

    // Beat detection state
    private let sampleRate: Double = 44100
    private let hopSize: Int = 512
    private var energyHistory: [Float] = Array(repeating: 0, count: 43)  // ~1s at 512/44100
    private var historyIndex: Int = 0
    private var beatCooldown: Int = 0
    private var bpmSamples: [Double] = []
    private var lastBeatTime: Double?

    // MARK: - Device enumeration

    static func availableDevices() -> [(id: String, name: String)] {
        // On macOS, AVAudioEngine uses system default unless overridden
        // Return system audio input devices via CoreAudio
        var devices: [(id: String, name: String)] = []
        var propSize: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &deviceIDs)

        for deviceID in deviceIDs {
            // Check if it has input channels
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(deviceID, &inputAddr, 0, nil, &inputSize)
            guard inputSize > 0 else { continue }

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameRef)
            let name = nameRef as String
            if !name.isEmpty {
                devices.append((id: "\(deviceID)", name: name))
            }
        }
        return devices
    }

    // MARK: - Start / Stop

    func start(deviceID: String? = nil) {
        stop()
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hopSize), format: format) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }

        do {
            try audioEngine.start()
            isRunning = true
        } catch {
            onError?("Audio start error: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
        energyHistory = Array(repeating: 0, count: 43)
        historyIndex = 0
        beatCooldown = 0
        bpmSamples.removeAll()
        lastBeatTime = nil
    }

    func shutdown() { stop() }

    // MARK: - Audio processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard enabled, let data = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        // RMS level
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(frameCount))
        let level = min(1.0, Double(rms) * 8.0)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }

        // Energy for beat detection
        var energy: Float = 0
        vDSP_svesq(data, 1, &energy, vDSP_Length(frameCount))
        energy /= Float(frameCount)

        // Simple energy-based onset detection:
        // beat if energy > 1.5× local average and cooldown elapsed
        let avgEnergy = energyHistory.reduce(0, +) / Float(energyHistory.count)
        energyHistory[historyIndex % energyHistory.count] = energy
        historyIndex += 1

        if beatCooldown > 0 {
            beatCooldown -= 1
            return
        }

        let threshold: Float = 1.5
        if energy > avgEnergy * threshold && avgEnergy > 0.0001 {
            beatCooldown = Int(sampleRate / Double(hopSize) * 0.3)  // 300ms cooldown

            let now = CACurrentMediaTime()
            if let last = lastBeatTime {
                let interval = now - last
                if interval > 0.2 && interval < 2.0 {
                    let bpm = 60.0 / interval
                    bpmSamples.append(bpm)
                    if bpmSamples.count > 8 { bpmSamples.removeFirst() }
                    let avgBpm = bpmSamples.reduce(0, +) / Double(bpmSamples.count)
                    if avgBpm > 40 && avgBpm < 250 {
                        DispatchQueue.main.async { [weak self] in
                            self?.onBpmDetected?((avgBpm * 10).rounded() / 10)
                        }
                    }
                }
            }
            lastBeatTime = now
            engine?.externalTick()
        }
    }
}
