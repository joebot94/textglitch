// AutoPresetSwitcher.swift — Auto choreography scheduler (port of preset_auto_switcher.py)

import Foundation

final class AutoPresetSwitcher {
    weak var engine: GridEngine?

    var enabled: Bool = false
    var intervalMs: Int = 3000
    var mode: String = "sequential"   // sequential | random
    var enabledPresets: [String] = autoSwitchablePresets
    var sceneCycle: [String] = []

    // Callbacks replacing Qt signals
    var onAutoChanged: ((Bool) -> Void)?
    var onSwitched: ((String, String) -> Void)?
    var onCountdownChanged: ((Int) -> Void)?
    var onStatusMessage: ((String) -> Void)?

    private var switchTimer: Timer?
    private var countdownTimer: Timer?
    private var nextSwitchAt: Date = .distantPast
    private var seqIndex: Int = -1
    private var lastAutoPreset: String = ""
    private var switchInProgress = false

    // MARK: - Public controls

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            syncSeqIndexToCurrent()
            scheduleNextSwitch()
        } else {
            stopTimers()
            onCountdownChanged?(0)
        }
        onAutoChanged?(on)
    }

    func toggleEnabled() { setEnabled(!enabled) }

    func setIntervalMs(_ ms: Int) {
        intervalMs = max(80, min(600_000, ms))
        if enabled { scheduleNextSwitch() }
    }

    func setMode(_ m: String) {
        guard ["sequential", "random"].contains(m), m != mode else { return }
        mode = m
        if enabled { scheduleNextSwitch() }
    }

    func setEnabledPresets(_ presets: [String]) {
        enabledPresets = normalizedPresetList(presets)
        syncSeqIndexToCurrent()
        if enabled { scheduleNextSwitch() }
    }

    func setSceneCycle(_ presets: [String]) {
        sceneCycle = normalizedPresetList(presets)
        syncSeqIndexToCurrent()
        if enabled { scheduleNextSwitch() }
    }

    @discardableResult
    func applyManualPreset(_ name: String, source: String = "manual") -> Bool {
        guard let engine = engine else { return false }
        let canonical = normalizePresetName(name)
        guard presetNames.contains(canonical) else { return false }
        guard engine.setPreset(canonical, emitDisplay: true) else { return false }
        syncSeqIndexToCurrent()
        if enabled { scheduleNextSwitch() }
        onSwitched?(canonical, source)
        return true
    }

    @discardableResult
    func switchNext(source: String = "manual-next") -> Bool { step(1, source: source, auto: false) }

    @discardableResult
    func switchPrevious(source: String = "manual-prev") -> Bool { step(-1, source: source, auto: false) }

    func nextSwitchCountdownMs() -> Int {
        guard enabled, switchTimer?.isValid == true else { return 0 }
        return max(0, Int(nextSwitchAt.timeIntervalSinceNow * 1000))
    }

    // MARK: - Timer internals

    private func scheduleNextSwitch() {
        let cycle = currentCycle()
        guard enabled else { return }
        guard !cycle.isEmpty else {
            stopTimers()
            onCountdownChanged?(0)
            onStatusMessage?("Auto switch enabled but no presets selected.")
            return
        }
        switchTimer?.invalidate()
        let interval = Double(intervalMs) / 1000.0
        nextSwitchAt = Date().addingTimeInterval(interval)
        switchTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.onSwitchTimeout()
        }
        if countdownTimer?.isValid != true {
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.emitCountdown()
            }
        }
        emitCountdown()
    }

    private func stopTimers() {
        switchTimer?.invalidate()
        switchTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        nextSwitchAt = .distantPast
    }

    private func emitCountdown() {
        onCountdownChanged?(nextSwitchCountdownMs())
        if !enabled {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    private func onSwitchTimeout() {
        guard !switchInProgress, enabled else { return }
        switchInProgress = true
        defer { switchInProgress = false }
        let changed = step(1, source: "auto", auto: true)
        if !changed { onStatusMessage?("Auto switch skipped: no valid target.") }
        if enabled { scheduleNextSwitch() }
    }

    // MARK: - Selection policy

    private func currentCycle() -> [String] {
        normalizedPresetList(sceneCycle.isEmpty ? enabledPresets : sceneCycle)
    }

    private func normalizedPresetList(_ presets: [String]) -> [String] {
        var seen = Set<String>()
        return presets.compactMap { name -> String? in
            let canonical = normalizePresetName(name)
            guard presetNames.contains(canonical), canonical != "Custom" else { return nil }
            return seen.insert(canonical).inserted ? canonical : nil
        }
    }

    private func syncSeqIndexToCurrent() {
        let cycle = currentCycle()
        guard !cycle.isEmpty, let engine = engine else { seqIndex = -1; return }
        let current = normalizePresetName(engine.presetName)
        seqIndex = cycle.firstIndex(of: current) ?? -1
    }

    @discardableResult
    private func step(_ direction: Int, source: String, auto: Bool) -> Bool {
        guard let engine = engine else { return false }
        let cycle = currentCycle()
        guard !cycle.isEmpty else { return false }

        let current = normalizePresetName(engine.presetName)
        let target: String

        if direction < 0 {
            let idx = cycle.firstIndex(of: current) ?? 0
            target = cycle[((idx - 1) + cycle.count) % cycle.count]
        } else if auto && mode == "random" {
            target = randomTarget(cycle: cycle, current: current)
        } else {
            let idx = cycle.firstIndex(of: current) ?? (seqIndex >= 0 ? seqIndex : -1)
            target = cycle[(idx + 1) % cycle.count]
        }

        guard !target.isEmpty, engine.setPreset(target, emitDisplay: true) else { return false }
        if auto { lastAutoPreset = target }
        syncSeqIndexToCurrent()
        onSwitched?(target, source)
        return true
    }

    private func randomTarget(cycle: [String], current: String) -> String {
        if cycle.count == 1 { return cycle[0] }
        var choices = cycle.filter { $0 != current }
        if choices.count > 1, choices.contains(lastAutoPreset) {
            choices.removeAll { $0 == lastAutoPreset }
        }
        return choices.randomElement() ?? cycle[0]
    }
}
