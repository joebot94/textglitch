// AppDelegate.swift — App lifecycle, wires all components together

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine  = GridEngine()
    private let auto    = AutoPresetSwitcher()
    private let midi    = MidiHandler()
    private let audio   = AudioHandler()
    private let osc     = OscHandler()
    private let watcher = FileWatcher()

    private var displayWC: DisplayWindowController!
    private var controlWC: ControlWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use dark appearance throughout
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Wire handlers to engine
        auto.engine    = engine
        midi.engine    = engine
        audio.engine   = engine
        osc.engine     = engine
        osc.presetSwitcher = auto
        watcher.engine = engine

        // Wire engine ticks back to osc and midi out
        // (done in ControlWindowController bindings)

        // Create windows
        displayWC = DisplayWindowController(engine: engine)
        controlWC = ControlWindowController(
            engine:  engine,
            display: displayWC,
            auto:    auto,
            midi:    midi,
            audio:   audio,
            osc:     osc,
            watcher: watcher
        )

        controlWC.showWindow(nil)
        controlWC.window?.center()

        displayWC.showWindow(nil)
        displayWC.window?.setContentSize(NSSize(width: 600, height: 600))

        // Position display to right of control panel
        if let ctrlFrame = controlWC.window?.frame,
           let dispWin = displayWC.window {
            let origin = NSPoint(x: ctrlFrame.maxX + 16, y: ctrlFrame.minY)
            dispWin.setFrameOrigin(origin)
        }

        // Menu bar
        buildMenuBar()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
        midi.shutdown()
        audio.shutdown()
        osc.shutdown()
        watcher.shutdown()
    }

    // MARK: - Menu bar

    private func buildMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Text Grid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // View menu
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Show Display Window", action: #selector(showDisplay), keyEquivalent: "d")
        viewMenu.addItem(withTitle: "Toggle Fullscreen", action: #selector(toggleFullscreen), keyEquivalent: "f")

        // Playback menu
        let playMenuItem = NSMenuItem(title: "Playback", action: nil, keyEquivalent: "")
        mainMenu.addItem(playMenuItem)
        let playMenu = NSMenu(title: "Playback")
        playMenuItem.submenu = playMenu
        playMenu.addItem(withTitle: "Play / Pause", action: #selector(togglePlay), keyEquivalent: " ")
        playMenu.addItem(withTitle: "Step Forward", action: #selector(stepForward), keyEquivalent: "]")
        playMenu.addItem(withTitle: "Step Back",    action: #selector(stepBack),    keyEquivalent: "[")
        playMenu.addItem(withTitle: "Reset",        action: #selector(resetPointer), keyEquivalent: "r")

        NSApp.mainMenu = mainMenu
    }

    @objc private func showDisplay()    { displayWC.showWindow(nil) }
    @objc private func toggleFullscreen() { displayWC.toggleFullscreen() }
    @objc private func togglePlay()     { engine.togglePlay() }
    @objc private func stepForward()    { engine.step(1) }
    @objc private func stepBack()       { engine.step(-1) }
    @objc private func resetPointer()   { engine.reset() }
}
