// GridPresets.swift — Preset index computation (port of Python engine preset math)

import Foundation

func normalizePresetName(_ name: String) -> String {
    let raw = name.trimmingCharacters(in: .whitespaces)
    if presetNames.contains(raw) { return raw }
    let aliases: [String: String] = [
        "all4x4": "All", "all": "All", "all 4x4": "All", "all 4×4": "All",
    ]
    return aliases[raw.lowercased()] ?? raw
}

func normalizeGridProfile(_ name: String) -> String? {
    let raw = name
        .trimmingCharacters(in: .whitespaces)
        .lowercased()
        .replacingOccurrences(of: " ", with: "")
    let aliases: [String: String] = [
        "1x1": "1×1", "2x2": "2×2", "3x3": "3×3", "3x4": "3×4", "4x4": "4×4",
        "1×1": "1×1", "2×2": "2×2", "3×3": "3×3", "3×4": "3×4", "4×4": "4×4",
    ]
    return aliases[raw]
}

func computePresetIndices(preset: String, rows: Int, cols: Int) -> [Int] {
    let cellCount = rows * cols
    guard cellCount > 0 else { return [] }

    let p = normalizePresetName(preset)

    // Legacy 4×4 exact lookup
    if rows == 4, cols == 4, let cells = legacy4x4Presets[p] {
        return cells
    }

    switch p {
    case "All":
        return Array(0..<cellCount)

    case "3×3":
        if rows < 3 || cols < 3 { return Array(0..<cellCount) }
        let rr = centerWindow(length: rows, size: 3)
        let cc = centerWindow(length: cols, size: 3)
        return rr.flatMap { r in cc.map { c in gridIdx(r, c, cols: cols) } }

    case "2×2 Center":
        if rows < 2 || cols < 2 { return Array(0..<cellCount) }
        let rr = centerWindow(length: rows, size: 2)
        let cc = centerWindow(length: cols, size: 2)
        return rr.flatMap { r in cc.map { c in gridIdx(r, c, cols: cols) } }

    case "Corners":
        return uniqueInOrder([
            0, cols - 1,
            gridIdx(rows - 1, 0, cols: cols),
            gridIdx(rows - 1, cols - 1, cols: cols),
        ], cellCount: cellCount)

    case "Diag ↘":
        return uniqueInOrder(diagDown(rows: rows, cols: cols), cellCount: cellCount)

    case "Diag ↗":
        return uniqueInOrder(diagUp(rows: rows, cols: cols), cellCount: cellCount)

    case "X", "Both Diags":
        return uniqueInOrder(
            diagDown(rows: rows, cols: cols) + diagUp(rows: rows, cols: cols),
            cellCount: cellCount
        )

    case "Cross +":
        let centerRows = rows % 2 == 1 ? [rows / 2] : [rows / 2 - 1, rows / 2]
        let centerCols = cols % 2 == 1 ? [cols / 2] : [cols / 2 - 1, cols / 2]
        var out: [Int] = []
        for r in centerRows { out += (0..<cols).map { c in gridIdx(r, c, cols: cols) } }
        for c in centerCols { out += (0..<rows).map { r in gridIdx(r, c, cols: cols) } }
        return uniqueInOrder(out, cellCount: cellCount)

    case "Top Row":    return (0..<cols).map { gridIdx(0, $0, cols: cols) }
    case "Mid Row":    return (0..<cols).map { gridIdx(rows / 2, $0, cols: cols) }
    case "Bottom Row": return (0..<cols).map { gridIdx(rows - 1, $0, cols: cols) }
    case "Left Col":   return (0..<rows).map { gridIdx($0, 0, cols: cols) }
    case "Right Col":  return (0..<rows).map { gridIdx($0, cols - 1, cols: cols) }

    case "Outer Ring":
        var out = (0..<cols).map { gridIdx(0, $0, cols: cols) }
        if rows > 1 { out += (0..<cols).map { gridIdx(rows - 1, $0, cols: cols) } }
        for r in 1..<max(1, rows - 1) {
            out.append(gridIdx(r, 0, cols: cols))
            if cols > 1 { out.append(gridIdx(r, cols - 1, cols: cols)) }
        }
        return uniqueInOrder(out, cellCount: cellCount)

    case "Center 1":
        return [gridIdx((rows - 1) / 2, (cols - 1) / 2, cols: cols)]

    default:
        return Array(0..<cellCount)
    }
}

// MARK: - Private helpers

func uniqueInOrder(_ values: [Int], cellCount: Int) -> [Int] {
    var seen = Set<Int>()
    return values.filter { 0 <= $0 && $0 < cellCount && seen.insert($0).inserted }
}

private func gridIdx(_ r: Int, _ c: Int, cols: Int) -> Int { r * cols + c }

private func centerWindow(length: Int, size: Int) -> Range<Int> {
    if length <= size { return 0..<length }
    let start = max(0, (length - size) / 2)
    return start..<min(length, start + size)
}

private func diagDown(rows: Int, cols: Int) -> [Int] {
    (0..<min(rows, cols)).map { gridIdx($0, $0, cols: cols) }
}

private func diagUp(rows: Int, cols: Int) -> [Int] {
    let n = min(rows, cols)
    return (0..<n).compactMap { i -> Int? in
        let c = cols - 1 - i
        guard c >= 0 && c < cols else { return nil }
        return gridIdx(i, c, cols: cols)
    }
}
