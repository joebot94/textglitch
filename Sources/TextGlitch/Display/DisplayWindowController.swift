// DisplayWindowController.swift — Output grid window (port of display_window.py DisplayWindow)

import AppKit
import Combine

final class DisplayWindowController: NSWindowController, NSWindowDelegate {
    private let engine: GridEngine
    private var gridView: NSView!
    private var cells: [CellView] = []
    private var cancellables: Set<AnyCancellable> = []

    init(engine: GridEngine) {
        self.engine = engine
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TEXT GRID — Display"
        win.minSize = NSSize(width: 400, height: 400)
        win.backgroundColor = .black
        super.init(window: win)
        win.delegate = self
        setupGrid()
        bindEngine()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupGrid() {
        gridView = FlippedView()
        gridView.wantsLayer = true
        gridView.layer?.backgroundColor = NSColor.black.cgColor
        window?.contentView = gridView
        rebuildCells()
    }

    private func rebuildCells() {
        cells.forEach { $0.removeFromSuperview() }
        cells.removeAll()
        for i in 0..<engine.cellCount {
            let cell = CellView(index: i, engine: engine)
            gridView.addSubview(cell)
            cells.append(cell)
        }
        layoutCells()
    }

    private func layoutCells() {
        guard let frame = gridView?.bounds, !cells.isEmpty else { return }
        let rows = engine.gridRows
        let cols = engine.gridCols
        let spacing: CGFloat = engine.showBoxes ? 1 : 0
        let cellW = (frame.width  - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        let cellH = (frame.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)

        for (i, cell) in cells.enumerated() {
            let row = i / cols
            let col = i % cols
            let x = CGFloat(col) * (cellW + spacing)
            let y = CGFloat(row) * (cellH + spacing)
            cell.frame = CGRect(x: x, y: y, width: cellW, height: cellH)
        }
    }

    // MARK: - Engine bindings

    private func bindEngine() {
        engine.ticked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onTick() }
            .store(in: &cancellables)

        engine.displayChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshAll() }
            .store(in: &cancellables)
    }

    private func onTick() {
        let activeSet = Set(engine.visibleIndices)
        for cell in cells {
            if activeSet.contains(cell.index) {
                cell.triggerFlash()
            } else {
                cell.needsDisplay = true
            }
        }
    }

    private func refreshAll() {
        gridView.layer?.backgroundColor = (NSColor(hex: engine.bgColor) ?? .black).cgColor
        if cells.count != engine.cellCount {
            rebuildCells()
        } else {
            layoutCells()
            cells.forEach { $0.needsDisplay = true }
        }
    }

    // MARK: - Window delegate

    func windowDidResize(_ notification: Notification) {
        layoutCells()
    }

    // MARK: - Fullscreen / screen targeting

    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    func moveToScreen(_ screenIndex: Int) {
        let screens = NSScreen.screens
        guard screenIndex < screens.count else { return }
        let screen = screens[screenIndex]
        window?.setFrame(screen.frame, display: true)
        if window?.styleMask.contains(.fullScreen) == false {
            window?.toggleFullScreen(nil)
        }
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape — exit fullscreen
            if window?.styleMask.contains(.fullScreen) == true { toggleFullscreen() }
        case 3:   // F — toggle fullscreen
            toggleFullscreen()
        case 49:  // Space — play/pause
            engine.togglePlay()
        case 124: // Right arrow
            engine.step(1)
        case 123: // Left arrow
            engine.step(-1)
        case 15:  // R — reset
            engine.reset()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Flipped view (top-left origin like Qt)

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
