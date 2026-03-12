// DisplayWindowController.swift — Output grid window, now backed by MetalDisplayView.

import AppKit
import MetalKit

final class DisplayWindowController: NSWindowController, NSWindowDelegate {
    private let engine: GridEngine
    private var metalView: MetalDisplayView!

    init(engine: GridEngine) {
        self.engine = engine
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TEXT GRID — Display"
        win.minSize = NSSize(width: 300, height: 300)
        win.backgroundColor = .black
        super.init(window: win)
        win.delegate = self
        setupMetal()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: – Metal setup

    private func setupMetal() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            // Extremely unlikely on macOS 13+, but handle gracefully
            let label = NSTextField(labelWithString: "⚠️ Metal unavailable on this GPU.")
            label.textColor = .red
            window?.contentView = label
            return
        }

        // MTKView wants a device in its initialiser for proper layer setup
        metalView = MetalDisplayView(frame: window!.contentRect(forFrameRect: window!.frame),
                                     device: dev)
        metalView.autoresizingMask = [.width, .height]
        window?.contentView = metalView
        metalView.configure(engine: engine)
    }

    // MARK: – Fullscreen / screen targeting

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

    // MARK: – Key handling

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Escape — exit fullscreen
            if window?.styleMask.contains(.fullScreen) == true { toggleFullscreen() }
        case 3:   // F — toggle fullscreen
            toggleFullscreen()
        case 49:  // Space — play/pause
            engine.togglePlay()
        case 124: // →
            engine.step(1)
        case 123: // ←
            engine.step(-1)
        case 15:  // R — reset
            engine.reset()
        default:
            super.keyDown(with: event)
        }
    }
}
