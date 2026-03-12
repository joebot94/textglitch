// GridEngine.swift — Core state machine (port of Python engine.py)

import Foundation
import Combine

enum TextMode: String, CaseIterable {
    case letter, word, phrase, chunk
    var label: String {
        switch self {
        case .letter: return "LETTER"
        case .word:   return "WORD"
        case .phrase: return "PHRASE"
        case .chunk:  return "CHUNK"
        }
    }
}

enum Distribution: String, CaseIterable {
    case sequential
    case allSame = "all-same"
    case random
    var label: String {
        switch self {
        case .sequential: return "SEQUENTIAL"
        case .allSame:    return "ALL SAME"
        case .random:     return "RANDOM"
        }
    }
}

enum TextTransform: String, CaseIterable {
    case upper, lower, none
    var label: String {
        switch self {
        case .upper: return "UPPER"
        case .lower: return "lower"
        case .none:  return "As-Is"
        }
    }
}

enum ColorMode: String, CaseIterable {
    case global
    case perCell = "per-cell"
    case random
    case cycle
    var label: String {
        switch self {
        case .global:  return "GLOBAL"
        case .perCell: return "PER CELL"
        case .random:  return "RANDOM"
        case .cycle:   return "CYCLE"
        }
    }
}

final class GridEngine {
    // MARK: - Combine subjects (replaces Qt signals)
    let ticked          = PassthroughSubject<Int, Never>()
    let playingChanged  = PassthroughSubject<Bool, Never>()
    let displayChanged  = PassthroughSubject<Void, Never>()
    let presetChanged   = PassthroughSubject<String, Never>()
    let tokensUpdated   = PassthroughSubject<Int, Never>()

    // MARK: - Grid layout
    var gridProfile: String = "4×4"
    var gridRows: Int = 4
    var gridCols: Int = 4
    var presetName: String = "Corners"
    var customCells: [Int] = [0, 3, 12, 15]
    var blankedCells: Set<Int> = []

    // MARK: - Text
    var rawText: String = defaultText
    var textMode: TextMode = .word
    var chunkSize: Int = 4
    var distribution: Distribution = .sequential
    var textTransform: TextTransform = .upper

    private(set) var tokens: [String] = []
    private var randSnap: [Int] = Array(repeating: 0, count: maxCells)

    // MARK: - Color
    var colorMode: ColorMode = .global
    var globalColor: String = "#ff6600"
    var cellColors: [String] = Array(repeating: "#ff6600", count: maxCells)
    var bgColor: String = "#000000"

    // MARK: - Style
    var fontFamily: String = "Impact"
    var fontSizePct: Int = 35
    var glowEnabled: Bool = true
    var flashEnabled: Bool = true
    var showBoxes: Bool = true

    // MARK: - Playback
    var pointer: Int = 0
    var speedMs: Int = 400
    var bpm: Double = 128.0
    var bpmSync: Bool = false
    var beatDivision: Double = 1.0
    private(set) var isPlaying: Bool = false

    private var timer: Timer?

    // MARK: - Computed
    var cellCount: Int { gridRows * gridCols }

    var effectiveMs: Int {
        if bpmSync && bpm > 0 {
            return max(16, Int((60_000.0 / bpm) * beatDivision))
        }
        return max(16, speedMs)
    }

    var activeIndices: [Int] {
        if presetName == "Custom" {
            return uniqueInOrder(customCells, cellCount: cellCount)
        }
        return computePresetIndices(preset: presetName, rows: gridRows, cols: gridCols)
    }

    var visibleIndices: [Int] {
        activeIndices.filter { !blankedCells.contains($0) }
    }

    // MARK: - Init
    init() {
        parseTokens()
        normalizeCustomCells()
    }

    // MARK: - Grid profile
    @discardableResult
    func setGridProfile(_ name: String) -> Bool {
        guard let canonical = normalizeGridProfile(name),
              gridProfileNames.contains(canonical) else { return false }
        guard canonical != gridProfile else { return true }

        gridProfile = canonical
        let profile = gridProfiles.first { $0.name == canonical }
        gridRows = profile?.rows ?? 4
        gridCols = profile?.cols ?? 4
        normalizeCustomCells()
        normalizeBlanks()
        displayChanged.send()
        return true
    }

    @discardableResult
    func setPreset(_ name: String, emitDisplay: Bool = true) -> Bool {
        let canonical = normalizePresetName(name)
        guard presetNames.contains(canonical) else { return false }
        let changed = canonical != presetName
        presetName = canonical
        if emitDisplay { displayChanged.send() }
        if changed { presetChanged.send(canonical) }
        return true
    }

    func normalizeCustomCells() {
        customCells = uniqueInOrder(customCells, cellCount: cellCount)
        if customCells.isEmpty && cellCount > 0 {
            customCells = computePresetIndices(preset: "Corners", rows: gridRows, cols: gridCols)
        }
    }

    func normalizeBlanks() {
        blankedCells = blankedCells.filter { $0 >= 0 && $0 < cellCount }
    }

    // MARK: - Text
    func setText(_ text: String) {
        rawText = text
        parseTokens()
    }

    func setTextMode(_ mode: TextMode) {
        textMode = mode
        parseTokens()
    }

    func setChunkSize(_ size: Int) {
        chunkSize = max(1, min(64, size))
        if textMode == .chunk { parseTokens() }
    }

    func parseTokens() {
        let t = rawText
        switch textMode {
        case .letter:
            tokens = t.filter { !$0.isWhitespace }.map { String($0) }
        case .word:
            tokens = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        case .chunk:
            let cleaned = t.filter { !$0.isWhitespace }
            let size = max(1, chunkSize)
            var result: [String] = []
            var idx = cleaned.startIndex
            while idx < cleaned.endIndex {
                let end = cleaned.index(idx, offsetBy: size, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
                result.append(String(cleaned[idx..<end]))
                idx = end
            }
            tokens = result
        case .phrase:
            tokens = t.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        if pointer >= max(1, tokens.count) { pointer = 0 }
        tokensUpdated.send(tokens.count)
    }

    private func applyTransform(_ s: String) -> String {
        switch textTransform {
        case .upper: return s.uppercased()
        case .lower: return s.lowercased()
        case .none:  return s
        }
    }

    // MARK: - Cell accessors
    func isCellBlanked(_ idx: Int) -> Bool { blankedCells.contains(idx) }

    func isCellVisible(_ idx: Int) -> Bool {
        activeIndices.contains(idx) && !blankedCells.contains(idx)
    }

    func getCellText(_ cellIdx: Int) -> String {
        let active = visibleIndices
        guard !tokens.isEmpty, let order = active.firstIndex(of: cellIdx) else { return "" }
        let n = tokens.count
        let tok: String
        switch distribution {
        case .allSame:    tok = tokens[pointer % n]
        case .random:     tok = tokens[randSnap[cellIdx % maxCells] % n]
        case .sequential: tok = tokens[(pointer + order) % n]
        }
        return applyTransform(tok)
    }

    func getCellColor(_ cellIdx: Int) -> String {
        let active = visibleIndices
        let order = active.firstIndex(of: cellIdx) ?? 0
        switch colorMode {
        case .perCell: return cellColors[cellIdx % maxCells]
        case .random:  return neonPalette[randSnap[cellIdx % maxCells] % neonPalette.count]
        case .cycle:   return neonPalette[(pointer + order) % neonPalette.count]
        case .global:  return globalColor
        }
    }

    // MARK: - Playback
    func play() {
        isPlaying = true
        scheduleTimer()
        playingChanged.send(true)
    }

    func stop() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
        playingChanged.send(false)
    }

    func togglePlay() { isPlaying ? stop() : play() }

    func reset() {
        pointer = 0
        ticked.send(0)
    }

    func step(_ direction: Int = 1) {
        guard !tokens.isEmpty else { return }
        let n = max(1, tokens.count)
        pointer = ((pointer + direction) % n + n) % n
        if distribution == .random || colorMode == .random {
            randSnap = (0..<maxCells).map { _ in Int.random(in: 0..<100_000) }
        }
        ticked.send(pointer)
    }

    func externalTick() {
        DispatchQueue.main.async { [weak self] in self?.doTick() }
    }

    func updateSpeed() {
        if isPlaying { scheduleTimer() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = Double(effectiveMs) / 1000.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.doTick()
        }
    }

    func doTick() {
        guard !tokens.isEmpty else { return }
        pointer = (pointer + 1) % max(1, tokens.count)
        if distribution == .random || colorMode == .random {
            randSnap = (0..<maxCells).map { _ in Int.random(in: 0..<100_000) }
        }
        ticked.send(pointer)
    }

    // MARK: - Custom cell helpers
    func toggleCustomCell(_ idx: Int) {
        guard idx >= 0 && idx < cellCount else { return }
        if let i = customCells.firstIndex(of: idx) {
            customCells.remove(at: i)
        } else {
            customCells.append(idx)
            customCells.sort()
        }
        setPreset("Custom", emitDisplay: true)
    }

    // MARK: - Blanking
    func setCellBlank(_ idx: Int, blank: Bool = true) {
        guard idx >= 0 && idx < cellCount else { return }
        let changed: Bool
        if blank { changed = blankedCells.insert(idx).inserted }
        else { changed = blankedCells.remove(idx) != nil }
        if changed { displayChanged.send() }
    }

    func setCellsBlank(_ indices: [Int], blank: Bool = true) {
        let before = blankedCells
        for idx in indices where idx >= 0 && idx < cellCount {
            if blank { blankedCells.insert(idx) }
            else { blankedCells.remove(idx) }
        }
        if blankedCells != before { displayChanged.send() }
    }

    func clearBlanks() {
        guard !blankedCells.isEmpty else { return }
        blankedCells.removeAll()
        displayChanged.send()
    }
}
