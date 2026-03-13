// ControlWindowController.swift — Main control panel with 8 tabs (port of control_window.py)

import AppKit
import Combine

final class ControlWindowController: NSWindowController, NSWindowDelegate {

    // Dependencies
    private let engine: GridEngine
    private let displayWC: DisplayWindowController
    private let auto: AutoPresetSwitcher
    private let midi: MidiHandler
    private let audio: AudioHandler
    private let osc: OscHandler
    private let watcher: FileWatcher

    // Combine
    private var cancellables: Set<AnyCancellable> = []

    // Tab views (kept for refresh access)
    private var tabView: NSTabView!

    // MARK: - Init

    init(
        engine: GridEngine,
        display: DisplayWindowController,
        auto: AutoPresetSwitcher,
        midi: MidiHandler,
        audio: AudioHandler,
        osc: OscHandler,
        watcher: FileWatcher
    ) {
        self.engine  = engine
        self.displayWC = display
        self.auto    = auto
        self.midi    = midi
        self.audio   = audio
        self.osc     = osc
        self.watcher = watcher

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "TEXT GRID — Control"
        win.minSize = NSSize(width: 320, height: 560)
        super.init(window: win)
        win.delegate = self

        buildUI()
        bindEngine()
        bindHandlers()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI construction

    private func buildUI() {
        let contentView = NSView()
        window?.contentView = contentView

        // Header
        let header = makeHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        // Tab view
        tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeTab("LAYOUT", view: buildLayoutTab()))
        tabView.addTabViewItem(makeTab("TEXT",   view: buildTextTab()))
        tabView.addTabViewItem(makeTab("STYLE",  view: buildStyleTab()))
        tabView.addTabViewItem(makeTab("PLAY",   view: buildPlayTab()))
        tabView.addTabViewItem(makeTab("MIDI",   view: buildMidiTab()))
        tabView.addTabViewItem(makeTab("AUDIO",  view: buildAudioTab()))
        tabView.addTabViewItem(makeTab("OSC",    view: buildOscTab()))
        tabView.addTabViewItem(makeTab("FILES",  view: buildFilesTab()))
        contentView.addSubview(tabView)

        // Transport bar
        let transport = buildTransportBar()
        transport.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(transport)

        // Status label
        let status = makeLabel("")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        status.textColor = NSColor(white: 0.25, alpha: 1)
        status.tag = 9999
        contentView.addSubview(status)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),

            tabView.topAnchor.constraint(equalTo: header.bottomAnchor),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            transport.topAnchor.constraint(equalTo: tabView.bottomAnchor),
            transport.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            transport.heightAnchor.constraint(equalToConstant: 52),

            status.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    private func makeHeader() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.05, alpha: 1).cgColor

        let title = makeLabel("TEXT GRID")
        title.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        title.textColor = NSColor(hex: engine.globalColor) ?? .orange

        let sub = makeLabel("DISPLAY SYSTEM v2.0")
        sub.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        sub.textColor = NSColor(white: 0.18, alpha: 1)

        let stack = NSStackView(views: [title, NSView(), sub])
        stack.orientation = .horizontal
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    private func makeTab(_ label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = label
        item.view = scrollWrap(view)
        return item
    }

    // MARK: - LAYOUT tab

    private var trailDecayLabel: NSTextField!

    private func buildLayoutTab() -> NSView {
        let stack = vStack(spacing: 10, margins: 12)

        // Grid profile
        stack.addArrangedSubview(sectionLabel("GRID PROFILE"))
        let profilePop = NSPopUpButton()
        profilePop.addItems(withTitles: gridProfileNames)
        profilePop.selectItem(withTitle: engine.gridProfile)
        profilePop.tag = 100
        profilePop.target = self; profilePop.action = #selector(gridProfileChanged(_:))
        stack.addArrangedSubview(profilePop)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("PRESET"))

        // Preset grid
        let presetGrid = NSGridView()
        presetGrid.rowSpacing = 3
        presetGrid.columnSpacing = 3
        var row: [NSButton] = []
        for (i, name) in presetNames.enumerated() {
            let btn = toggleButton(name, tag: 200 + i, action: #selector(presetButtonPressed(_:)))
            btn.state = name == engine.presetName ? .on : .off
            row.append(btn)
            if row.count == 2 {
                presetGrid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty { presetGrid.addRow(with: row) }
        stack.addArrangedSubview(presetGrid)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("AUTO SWITCH PRESETS"))

        let autoRow = hStack()
        let autoBtn = toggleButton("AUTO", tag: 300, action: #selector(autoToggled(_:)))
        autoBtn.state = auto.enabled ? .on : .off
        let seqBtn  = toggleButton("SEQ",  tag: 301, action: #selector(autoModeChanged(_:)))
        seqBtn.state = auto.mode == "sequential" ? .on : .off
        let rndBtn  = toggleButton("RND",  tag: 302, action: #selector(autoModeChanged(_:)))
        rndBtn.state = auto.mode == "random" ? .on : .off
        autoRow.addArrangedSubview(autoBtn)
        autoRow.addArrangedSubview(seqBtn)
        autoRow.addArrangedSubview(rndBtn)
        stack.addArrangedSubview(autoRow)

        let intervalRow = hStack()
        intervalRow.addArrangedSubview(makeLabel("INTERVAL"))
        let intervalField = NSTextField()
        intervalField.stringValue = "\(auto.intervalMs)"
        intervalField.tag = 310
        intervalField.target = self; intervalField.action = #selector(autoIntervalEdited(_:))
        intervalField.frame = NSRect(x: 0, y: 0, width: 70, height: 22)
        intervalRow.addArrangedSubview(intervalField)
        for (ms, label) in [(250, "250"), (500, "500"), (1000, "1s"), (2000, "2s")] {
            let btn = actionButton(label, tag: 320 + ms / 50)
            btn.target = self; btn.action = #selector(quickInterval(_:))
            intervalRow.addArrangedSubview(btn)
        }
        stack.addArrangedSubview(intervalRow)

        let cdLabel = makeLabel("") ; cdLabel.tag = 311
        stack.addArrangedSubview(cdLabel)

        stack.addArrangedSubview(sectionLabel("AUTO PRESET POOL"))
        let poolGrid = NSGridView(); poolGrid.rowSpacing = 4; poolGrid.columnSpacing = 4
        var pRow: [NSButton] = []
        let enabled = Set(auto.enabledPresets)
        for (i, name) in autoSwitchablePresets.enumerated() {
            let cb = NSButton(checkboxWithTitle: name, target: self, action: #selector(autoPoolToggled(_:)))
            cb.state = enabled.contains(name) ? .on : .off
            cb.tag = 400 + i
            pRow.append(cb)
            if pRow.count == 2 { poolGrid.addRow(with: pRow); pRow = [] }
        }
        if !pRow.isEmpty { poolGrid.addRow(with: pRow) }
        stack.addArrangedSubview(poolGrid)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("BOXES / BORDERS"))
        let boxRow = hStack()
        let boxOn  = toggleButton("ON",  tag: 500, action: #selector(boxesToggled(_:))); boxOn.state  = engine.showBoxes ? .on : .off
        let boxOff = toggleButton("OFF", tag: 501, action: #selector(boxesToggled(_:))); boxOff.state = engine.showBoxes ? .off : .on
        boxRow.addArrangedSubview(boxOn); boxRow.addArrangedSubview(boxOff)
        stack.addArrangedSubview(boxRow)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("EFFECTS"))
        let fxRow1 = hStack()
        let glowCb  = NSButton(checkboxWithTitle: "GLOW",      target: self, action: #selector(glowToggled(_:)));       glowCb.state  = engine.glowEnabled          ? .on : .off
        let flashCb = NSButton(checkboxWithTitle: "FLASH",     target: self, action: #selector(flashToggled(_:)));      flashCb.state = engine.flashEnabled         ? .on : .off
        let scanCb  = NSButton(checkboxWithTitle: "SCANLINES", target: self, action: #selector(scanLinesToggled(_:)));  scanCb.state  = engine.scanLinesEnabled      ? .on : .off
        let chromaCb = NSButton(checkboxWithTitle: "CHROMA",   target: self, action: #selector(chromaToggled(_:)));     chromaCb.state = engine.chromaticAberration ? .on : .off
        fxRow1.addArrangedSubview(glowCb)
        fxRow1.addArrangedSubview(flashCb)
        fxRow1.addArrangedSubview(scanCb)
        fxRow1.addArrangedSubview(chromaCb)
        stack.addArrangedSubview(fxRow1)

        let fxRow2 = hStack()
        let strobeCb = NSButton(checkboxWithTitle: "STROBE", target: self, action: #selector(strobeToggled(_:)))
        strobeCb.state = engine.strobeEnabled ? .on : .off
        let trailCb  = NSButton(checkboxWithTitle: "TRAIL",  target: self, action: #selector(trailToggled(_:)))
        trailCb.state = engine.trailEnabled ? .on : .off
        fxRow2.addArrangedSubview(strobeCb)
        fxRow2.addArrangedSubview(trailCb)
        stack.addArrangedSubview(fxRow2)

        stack.addArrangedSubview(sectionLabel("TRAIL DECAY"))
        let decayRow = hStack()
        let decaySlider = NSSlider(value: Double(engine.trailDecay), minValue: 0.70, maxValue: 0.99,
                                   target: self, action: #selector(trailDecayChanged(_:)))
        decaySlider.tag = 960
        trailDecayLabel = makeLabel(String(format: "%.2f", engine.trailDecay))
        decayRow.addArrangedSubview(decaySlider)
        decayRow.addArrangedSubview(trailDecayLabel)
        stack.addArrangedSubview(decayRow)

        stack.addArrangedSubview(NSView())
        return stack
    }

    // MARK: - TEXT tab

    private var textView: NSTextView!
    private var tokenLabel: NSTextField!
    private var chunkLabel: NSTextField!

    private func buildTextTab() -> NSView {
        let stack = vStack(spacing: 10, margins: 12)

        stack.addArrangedSubview(sectionLabel("INPUT TEXT"))

        // Proper scrollable text view setup — NSTextView.scrollableTextView()
        // automatically wires up the clip view, container, and sizing correctly
        let scrolled = NSTextView.scrollableTextView()
        scrolled.hasVerticalScroller = true
        scrolled.autohidesScrollers = true
        textView = (scrolled.documentView as! NSTextView)
        textView.string = engine.rawText
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.textColor = NSColor(white: 0.8, alpha: 1)
        textView.backgroundColor = NSColor(white: 0.07, alpha: 1)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = self
        scrolled.heightAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(scrolled)

        tokenLabel = makeLabel("0 tokens")
        stack.addArrangedSubview(tokenLabel)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("TEXT MODE"))
        let modeRow = hStack()
        for mode in TextMode.allCases {
            let btn = toggleButton(mode.label, tag: 600 + TextMode.allCases.firstIndex(of: mode)!, action: #selector(textModePressed(_:)))
            btn.state = engine.textMode == mode ? .on : .off
            modeRow.addArrangedSubview(btn)
        }
        stack.addArrangedSubview(modeRow)

        stack.addArrangedSubview(sectionLabel("CHUNK SIZE (CHUNK MODE)"))
        let chunkRow = hStack()
        let chunkField = NSTextField()
        chunkField.stringValue = "\(engine.chunkSize)"; chunkField.tag = 610
        chunkField.target = self; chunkField.action = #selector(chunkEdited(_:))
        chunkField.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        chunkLabel = makeLabel("\(engine.chunkSize) chars/tile")
        chunkRow.addArrangedSubview(chunkField); chunkRow.addArrangedSubview(chunkLabel)
        stack.addArrangedSubview(chunkRow)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("CELL DISTRIBUTION"))
        for (i, dist) in Distribution.allCases.enumerated() {
            let btn = toggleButton(dist.label, tag: 700 + i, action: #selector(distPressed(_:)))
            btn.state = engine.distribution == dist ? .on : .off
            stack.addArrangedSubview(btn)
        }

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("TRANSFORM"))
        let ttRow = hStack()
        for (i, tt) in TextTransform.allCases.enumerated() {
            let btn = toggleButton(tt.label, tag: 800 + i, action: #selector(transformPressed(_:)))
            btn.state = engine.textTransform == tt ? .on : .off
            ttRow.addArrangedSubview(btn)
        }
        stack.addArrangedSubview(ttRow)

        stack.addArrangedSubview(NSView())
        return stack
    }

    // MARK: - STYLE tab

    private var fontSizeLabel: NSTextField!
    private var brightnessLabel: NSTextField!
    private var swatchButtons: [(NSButton, String)] = []
    private var customColorWell: NSColorWell!

    private func buildStyleTab() -> NSView {
        let stack = vStack(spacing: 10, margins: 12)

        stack.addArrangedSubview(sectionLabel("FONT"))
        let fontPop = NSPopUpButton(); fontPop.tag = 900
        fontPop.addItems(withTitles: availableFonts)
        if let idx = availableFonts.firstIndex(of: engine.fontFamily) { fontPop.selectItem(at: idx) }
        fontPop.target = self; fontPop.action = #selector(fontChanged(_:))
        stack.addArrangedSubview(fontPop)

        stack.addArrangedSubview(sectionLabel("FONT SIZE"))
        let sizeRow = hStack()
        let sizeSlider = NSSlider(value: Double(engine.fontSizePct), minValue: 5, maxValue: 80, target: self, action: #selector(fontSizeChanged(_:)))
        sizeSlider.tag = 910
        fontSizeLabel = makeLabel("\(engine.fontSizePct)%")
        sizeRow.addArrangedSubview(sizeSlider); sizeRow.addArrangedSubview(fontSizeLabel)
        stack.addArrangedSubview(sizeRow)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("COLOR MODE"))
        for (i, mode) in ColorMode.allCases.enumerated() {
            let btn = toggleButton(mode.label, tag: 1000 + i, action: #selector(colorModePressed(_:)))
            btn.state = engine.colorMode == mode ? .on : .off
            stack.addArrangedSubview(btn)
        }

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("TEXT COLOR (GLOBAL / CYCLE)"))

        // Palette rows — 6 per row, no text on buttons
        let swatchOuter = vStack(spacing: 4, margins: 0)
        var currentSwatchRow = hStack(spacing: 4)
        for (i, colorHex) in neonPalette.enumerated() {
            let btn = makeColorSwatch(colorHex, selected: colorHex == engine.globalColor, tag: 1100 + i)
            swatchButtons.append((btn, colorHex))
            currentSwatchRow.addArrangedSubview(btn)
            if (i + 1) % 6 == 0 {
                swatchOuter.addArrangedSubview(currentSwatchRow)
                currentSwatchRow = hStack(spacing: 4)
            }
        }
        // Remaining palette items + custom color well on last row
        if currentSwatchRow.arrangedSubviews.count > 0 {
            swatchOuter.addArrangedSubview(currentSwatchRow)
        }
        // Custom color well row
        let customRow = hStack(spacing: 6)
        customColorWell = NSColorWell()
        customColorWell.color = NSColor(hex: engine.globalColor) ?? .orange
        customColorWell.tag = 1198
        customColorWell.widthAnchor.constraint(equalToConstant: 30).isActive = true
        customColorWell.heightAnchor.constraint(equalToConstant: 26).isActive = true
        customColorWell.target = self
        customColorWell.action = #selector(colorWellChanged(_:))
        let customLbl = sectionLabel("CUSTOM")
        customRow.addArrangedSubview(customColorWell)
        customRow.addArrangedSubview(customLbl)
        swatchOuter.addArrangedSubview(customRow)
        stack.addArrangedSubview(swatchOuter)

        stack.addArrangedSubview(sectionLabel("BACKGROUND"))
        let bgRow = hStack(spacing: 4)
        let bgColors = ["#000000", "#050505", "#0a0000", "#000a00", "#00000a", "#080808"]
        for (i, c) in bgColors.enumerated() {
            let btn = makeColorSwatch(c, selected: c == engine.bgColor, tag: 1200 + i)
            bgRow.addArrangedSubview(btn)
        }
        stack.addArrangedSubview(bgRow)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("BRIGHTNESS"))
        let brightnessRow = hStack()
        let brightnessSlider = NSSlider(value: Double(engine.brightness), minValue: 0.2, maxValue: 3.0,
                                        target: self, action: #selector(brightnessChanged(_:)))
        brightnessSlider.tag = 970
        brightnessLabel = makeLabel(String(format: "%.1f×", engine.brightness))
        brightnessRow.addArrangedSubview(brightnessSlider)
        brightnessRow.addArrangedSubview(brightnessLabel)
        stack.addArrangedSubview(brightnessRow)

        stack.addArrangedSubview(NSView())
        return stack
    }

    // MARK: - PLAY tab

    private var speedLabel: NSTextField!
    private var bpmField: NSTextField!
    private var intervalLabel: NSTextField!
    private var tapTimes: [Double] = []

    private func buildPlayTab() -> NSView {
        let stack = vStack(spacing: 10, margins: 12)

        stack.addArrangedSubview(sectionLabel("TIMING MODE"))
        let timingRow = hStack()
        let manualBtn = toggleButton("MANUAL",   tag: 1300, action: #selector(timingModePressed(_:))); manualBtn.state = !engine.bpmSync ? .on : .off
        let bpmSyncBtn = toggleButton("BPM SYNC", tag: 1301, action: #selector(timingModePressed(_:))); bpmSyncBtn.state = engine.bpmSync ? .on : .off
        timingRow.addArrangedSubview(manualBtn); timingRow.addArrangedSubview(bpmSyncBtn)
        stack.addArrangedSubview(timingRow)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("SPEED (MANUAL)"))
        let speedRow = hStack()
        let speedSlider = NSSlider(value: Double(engine.speedMs), minValue: 20, maxValue: 2000, target: self, action: #selector(speedChanged(_:)))
        speedSlider.tag = 1310
        speedLabel = makeLabel("\(engine.speedMs) ms")
        speedRow.addArrangedSubview(speedSlider); speedRow.addArrangedSubview(speedLabel)
        stack.addArrangedSubview(speedRow)

        let quickRow = hStack()
        for (ms, label) in [(80, "80ms"), (200, "200ms"), (400, "400ms"), (800, "800ms")] {
            let btn = actionButton(label, tag: 1320 + ms)
            btn.target = self; btn.action = #selector(quickSpeed(_:))
            quickRow.addArrangedSubview(btn)
        }
        stack.addArrangedSubview(quickRow)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("BPM"))
        bpmField = NSTextField()
        bpmField.stringValue = "\(engine.bpm)"
        bpmField.tag = 1400
        bpmField.target = self; bpmField.action = #selector(bpmEdited(_:))
        bpmField.font = NSFont.monospacedSystemFont(ofSize: 20, weight: .bold)
        stack.addArrangedSubview(bpmField)

        let tapBtn = NSButton(title: "TAP TEMPO", target: self, action: #selector(tapTempo))
        tapBtn.bezelStyle = .rounded
        tapBtn.heightAnchor.constraint(equalToConstant: 50).isActive = true
        stack.addArrangedSubview(tapBtn)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("BEAT DIVISION"))
        let divRow = hStack()
        for (i, (label, val)) in [("½", 2.0), ("¼", 1.0), ("⅛", 0.5), ("1/16", 0.25)].enumerated() {
            let btn = toggleButton(label, tag: 1500 + i, action: #selector(divisionPressed(_:)))
            btn.state = engine.beatDivision == val ? .on : .off
            divRow.addArrangedSubview(btn)
        }
        stack.addArrangedSubview(divRow)

        intervalLabel = makeLabel(""); intervalLabel.tag = 1510; intervalLabel.alignment = .center
        updateIntervalLabel()
        stack.addArrangedSubview(intervalLabel)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("DISPLAY OUTPUT"))
        let screenRow = hStack()
        for (i, scr) in NSScreen.screens.enumerated() {
            let name = scr.localizedName.prefix(12)
            let btn = actionButton("→ \(name)", tag: 1600 + i)
            btn.target = self; btn.action = #selector(moveToScreen(_:))
            screenRow.addArrangedSubview(btn)
        }
        stack.addArrangedSubview(screenRow)

        let fsBtn = NSButton(title: "⛶  FULLSCREEN (F)", target: self, action: #selector(toggleFullscreen))
        fsBtn.bezelStyle = .rounded
        stack.addArrangedSubview(fsBtn)

        stack.addArrangedSubview(NSView())
        return stack
    }

    // MARK: - MIDI tab

    private var midiInPop: NSPopUpButton!
    private var midiOutPop: NSPopUpButton!
    private var midiStatusLabel: NSTextField!

    private func buildMidiTab() -> NSView {
        let stack = vStack(spacing: 10, margins: 12)

        stack.addArrangedSubview(sectionLabel("MIDI INPUT (CLOCK IN)"))
        midiInPop = NSPopUpButton()
        midiInPop.addItem(withTitle: "— select port —")
        midiInPop.addItems(withTitles: MidiHandler.availableInputs())
        stack.addArrangedSubview(midiInPop)

        let midiInRow = hStack()
        let midiInOpen  = actionButton("OPEN",  tag: 2000); midiInOpen.target  = self; midiInOpen.action  = #selector(openMidiIn)
        let midiInClose = actionButton("CLOSE", tag: 2001); midiInClose.target = self; midiInClose.action = #selector(closeMidiIn)
        let midiEnable  = NSButton(checkboxWithTitle: "ENABLED", target: self, action: #selector(midiEnableToggled(_:))); midiEnable.state = midi.enabled ? .on : .off
        midiInRow.addArrangedSubview(midiInOpen); midiInRow.addArrangedSubview(midiInClose); midiInRow.addArrangedSubview(midiEnable)
        stack.addArrangedSubview(midiInRow)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("MIDI OUTPUT (CLOCK OUT)"))
        midiOutPop = NSPopUpButton()
        midiOutPop.addItem(withTitle: "— select port —")
        midiOutPop.addItems(withTitles: MidiHandler.availableOutputs())
        stack.addArrangedSubview(midiOutPop)

        let midiOutRow = hStack()
        let midiOutOpen  = actionButton("OPEN",  tag: 2010); midiOutOpen.target  = self; midiOutOpen.action  = #selector(openMidiOut)
        let midiOutClose = actionButton("CLOSE", tag: 2011); midiOutClose.target = self; midiOutClose.action = #selector(closeMidiOut)
        let midiSend     = NSButton(checkboxWithTitle: "SEND", target: self, action: #selector(midiSendToggled(_:))); midiSend.state = midi.sendEnabled ? .on : .off
        midiOutRow.addArrangedSubview(midiOutOpen); midiOutRow.addArrangedSubview(midiOutClose); midiOutRow.addArrangedSubview(midiSend)
        stack.addArrangedSubview(midiOutRow)

        midiStatusLabel = makeLabel("No MIDI port open")
        stack.addArrangedSubview(midiStatusLabel)
        stack.addArrangedSubview(NSView())
        return stack
    }

    // MARK: - AUDIO tab

    private var audioDevicePop: NSPopUpButton!
    private var vuBar: NSProgressIndicator!
    private var audioBpmLabel: NSTextField!
    private var audioStatusLabel: NSTextField!

    private func buildAudioTab() -> NSView {
        let stack = vStack(spacing: 10, margins: 12)

        stack.addArrangedSubview(sectionLabel("AUDIO INPUT DEVICE"))
        audioDevicePop = NSPopUpButton()
        audioDevicePop.addItem(withTitle: "— system default —")
        for dev in AudioHandler.availableDevices() {
            audioDevicePop.addItem(withTitle: "\(dev.name)")
        }
        stack.addArrangedSubview(audioDevicePop)

        let audioRow = hStack()
        let startBtn = actionButton("START", tag: 3000); startBtn.target = self; startBtn.action = #selector(startAudio)
        let stopBtn  = actionButton("STOP",  tag: 3001); stopBtn.target  = self; stopBtn.action  = #selector(stopAudio)
        let audioCb  = NSButton(checkboxWithTitle: "ENABLED", target: self, action: #selector(audioEnableToggled(_:))); audioCb.state = audio.enabled ? .on : .off
        audioRow.addArrangedSubview(startBtn); audioRow.addArrangedSubview(stopBtn); audioRow.addArrangedSubview(audioCb)
        stack.addArrangedSubview(audioRow)

        stack.addArrangedSubview(sectionLabel("LEVEL"))
        vuBar = NSProgressIndicator()
        vuBar.isIndeterminate = false
        vuBar.minValue = 0; vuBar.maxValue = 1
        vuBar.doubleValue = 0
        vuBar.heightAnchor.constraint(equalToConstant: 8).isActive = true
        stack.addArrangedSubview(vuBar)

        audioBpmLabel = makeLabel("BPM: —")
        audioBpmLabel.font = NSFont.monospacedSystemFont(ofSize: 22, weight: .bold)
        audioBpmLabel.textColor = NSColor(hex: engine.globalColor) ?? .orange
        audioBpmLabel.alignment = .center
        stack.addArrangedSubview(audioBpmLabel)

        audioStatusLabel = makeLabel("Audio not started")
        stack.addArrangedSubview(audioStatusLabel)
        stack.addArrangedSubview(NSView())
        return stack
    }

    // MARK: - OSC tab

    private var oscRxIPField: NSTextField!
    private var oscRxPortField: NSTextField!
    private var oscTxIPField: NSTextField!
    private var oscTxPortField: NSTextField!
    private var oscStatusLabel: NSTextField!

    private func buildOscTab() -> NSView {
        let stack = vStack(spacing: 10, margins: 12)

        stack.addArrangedSubview(sectionLabel("RECEIVE (SERVER)"))
        let rxRow = hStack()
        oscRxIPField = NSTextField(); oscRxIPField.stringValue = "0.0.0.0"; oscRxIPField.placeholderString = "IP"
        oscRxPortField = NSTextField(); oscRxPortField.stringValue = "8000"; oscRxPortField.placeholderString = "Port"
        rxRow.addArrangedSubview(makeLabel("IP")); rxRow.addArrangedSubview(oscRxIPField)
        rxRow.addArrangedSubview(makeLabel("Port")); rxRow.addArrangedSubview(oscRxPortField)
        stack.addArrangedSubview(rxRow)

        let rxCtrlRow = hStack()
        let startSrv = actionButton("START SERVER", tag: 4000); startSrv.target = self; startSrv.action = #selector(startOscServer)
        let stopSrv  = actionButton("STOP",         tag: 4001); stopSrv.target  = self; stopSrv.action  = #selector(stopOscServer)
        let rxEnable = NSButton(checkboxWithTitle: "RECEIVE", target: self, action: #selector(oscReceiveToggled(_:))); rxEnable.state = osc.receiveEnabled ? .on : .off
        rxCtrlRow.addArrangedSubview(startSrv); rxCtrlRow.addArrangedSubview(stopSrv); rxCtrlRow.addArrangedSubview(rxEnable)
        stack.addArrangedSubview(rxCtrlRow)

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("SEND (CLIENT)"))
        let txRow = hStack()
        oscTxIPField = NSTextField(); oscTxIPField.stringValue = "192.168.1.1"; oscTxIPField.placeholderString = "IP"
        oscTxPortField = NSTextField(); oscTxPortField.stringValue = "8001"; oscTxPortField.placeholderString = "Port"
        txRow.addArrangedSubview(makeLabel("IP")); txRow.addArrangedSubview(oscTxIPField)
        txRow.addArrangedSubview(makeLabel("Port")); txRow.addArrangedSubview(oscTxPortField)
        stack.addArrangedSubview(txRow)

        let txCtrlRow = hStack()
        let openClient  = actionButton("CONNECT", tag: 4010); openClient.target  = self; openClient.action  = #selector(connectOscClient)
        let closeClient = actionButton("CLOSE",   tag: 4011); closeClient.target = self; closeClient.action = #selector(closeOscClient)
        let txEnable    = NSButton(checkboxWithTitle: "SEND", target: self, action: #selector(oscSendToggled(_:))); txEnable.state = osc.sendEnabled ? .on : .off
        txCtrlRow.addArrangedSubview(openClient); txCtrlRow.addArrangedSubview(closeClient); txCtrlRow.addArrangedSubview(txEnable)
        stack.addArrangedSubview(txCtrlRow)

        oscStatusLabel = makeLabel("OSC inactive")
        stack.addArrangedSubview(oscStatusLabel)

        // Address reference
        let ref = makeLabel("/textgrid/play|stop|tick|reset|bpm|preset|grid|pointer|speed|blank|unblank|clear_blanks")
        ref.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        ref.textColor = NSColor(white: 0.25, alpha: 1)
        ref.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(ref)

        stack.addArrangedSubview(NSView())
        return stack
    }

    // MARK: - FILES tab

    private var filePathLabel: NSTextField!
    private var fileStatusLabel: NSTextField!

    private func buildFilesTab() -> NSView {
        let stack = vStack(spacing: 10, margins: 12)

        stack.addArrangedSubview(sectionLabel("HOT-RELOAD TEXT FILE"))
        filePathLabel = makeLabel("No file selected")
        filePathLabel.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(filePathLabel)

        let fileRow = hStack()
        let browseBtn = actionButton("BROWSE…", tag: 5000); browseBtn.target = self; browseBtn.action = #selector(browseFile)
        let reloadBtn = actionButton("RELOAD",  tag: 5001); reloadBtn.target = self; reloadBtn.action = #selector(reloadFile)
        let stopWatch = actionButton("STOP",    tag: 5002); stopWatch.target = self; stopWatch.action = #selector(stopWatching)
        fileRow.addArrangedSubview(browseBtn); fileRow.addArrangedSubview(reloadBtn); fileRow.addArrangedSubview(stopWatch)
        stack.addArrangedSubview(fileRow)

        let enableCb = NSButton(checkboxWithTitle: "WATCH ENABLED", target: self, action: #selector(watchEnableToggled(_:)))
        enableCb.state = watcher.enabled ? .on : .off
        stack.addArrangedSubview(enableCb)

        fileStatusLabel = makeLabel("Watcher inactive")
        stack.addArrangedSubview(fileStatusLabel)

        stack.addArrangedSubview(NSView())
        return stack
    }

    // MARK: - Transport bar

    private var playBtn: NSButton!
    private var pointerLabel: NSTextField!

    private func buildTransportBar() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.04, alpha: 1).cgColor

        playBtn = NSButton(title: "▶  PLAY", target: self, action: #selector(playPressed))
        playBtn.bezelStyle = .rounded

        let stepBack = NSButton(title: "◀", target: self, action: #selector(stepBack))
        stepBack.bezelStyle = .rounded

        let stepFwd = NSButton(title: "▶", target: self, action: #selector(stepForward))
        stepFwd.bezelStyle = .rounded

        let resetBtn = NSButton(title: "⟲", target: self, action: #selector(resetPressed))
        resetBtn.bezelStyle = .rounded

        pointerLabel = makeLabel("0 / 0")
        pointerLabel.alignment = .center

        let stack = NSStackView(views: [playBtn, stepBack, stepFwd, resetBtn, pointerLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    // MARK: - Engine bindings

    private func bindEngine() {
        engine.ticked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ptr in
                guard let self else { return }
                self.pointerLabel.stringValue = "\(ptr) / \(self.engine.tokens.count)"
                self.updatePlayButton()
            }
            .store(in: &cancellables)

        engine.playingChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePlayButton() }
            .store(in: &cancellables)

        engine.tokensUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.tokenLabel?.stringValue = "\(count) tokens"
                self?.pointerLabel?.stringValue = "0 / \(count)"
            }
            .store(in: &cancellables)

        engine.presetChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncPresetButtons() }
            .store(in: &cancellables)

        auto.onAutoChanged = { [weak self] _ in
            DispatchQueue.main.async { self?.syncAutoControls() }
        }

        auto.onCountdownChanged = { [weak self] ms in
            DispatchQueue.main.async {
                if let lbl = self?.window?.contentView?.viewWithTag(311) as? NSTextField {
                    lbl.stringValue = ms > 0 ? "Next: \(ms)ms" : ""
                }
            }
        }

        auto.onStatusMessage = { [weak self] msg in
            DispatchQueue.main.async { self?.setStatus(msg) }
        }
    }

    private func bindHandlers() {
        midi.onBpmDetected = { [weak self] bpm in
            DispatchQueue.main.async {
                self?.bpmField?.stringValue = String(format: "%.1f", bpm)
                self?.engine.bpm = bpm
                self?.updateIntervalLabel()
            }
        }

        midi.onPortError = { [weak self] msg in
            DispatchQueue.main.async { self?.midiStatusLabel?.stringValue = msg }
        }

        audio.onBpmDetected = { [weak self] bpm in
            DispatchQueue.main.async { self?.audioBpmLabel?.stringValue = "BPM: \(bpm)" }
        }

        audio.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.vuBar?.doubleValue = level }
        }

        audio.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.audioStatusLabel?.stringValue = msg }
        }

        osc.onStatusChanged = { [weak self] msg in
            DispatchQueue.main.async { self?.oscStatusLabel?.stringValue = msg }
        }

        watcher.onStatus = { [weak self] msg in
            DispatchQueue.main.async { self?.fileStatusLabel?.stringValue = msg }
        }

        watcher.onFileError = { [weak self] msg in
            DispatchQueue.main.async { self?.fileStatusLabel?.stringValue = msg }
        }

        // Wire engine ticks to OSC beat send
        engine.ticked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ptr in self?.osc.sendBeat(ptr) }
            .store(in: &cancellables)

        engine.playingChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in self?.osc.sendState(playing) }
            .store(in: &cancellables)
    }

    // MARK: - Actions: Layout

    @objc private func gridProfileChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        engine.setGridProfile(title)
        // Reset to All so the full new grid is immediately visible,
        // regardless of whatever preset was active on the previous profile.
        auto.applyManualPreset("All", source: "ui")
        syncPresetButtons()
    }

    @objc private func presetButtonPressed(_ sender: NSButton) {
        let idx = sender.tag - 200
        guard idx >= 0, idx < presetNames.count else { return }
        auto.applyManualPreset(presetNames[idx], source: "ui")
        syncPresetButtons()
    }

    @objc private func autoToggled(_ sender: NSButton) {
        auto.toggleEnabled()
    }

    @objc private func autoModeChanged(_ sender: NSButton) {
        let mode = sender.tag == 301 ? "sequential" : "random"
        auto.setMode(mode)
        syncAutoControls()
    }

    @objc private func autoIntervalEdited(_ sender: NSTextField) {
        if let v = Int(sender.stringValue) { auto.setIntervalMs(v) }
    }

    @objc private func quickInterval(_ sender: NSButton) {
        let msMap: [Int: Int] = [324: 250, 330: 500, 340: 1000, 360: 2000]
        if let ms = msMap[sender.tag] {
            auto.setIntervalMs(ms)
            if let field = window?.contentView?.viewWithTag(310) as? NSTextField {
                field.stringValue = "\(ms)"
            }
        }
    }

    @objc private func autoPoolToggled(_ sender: NSButton) {
        let idx = sender.tag - 400
        guard idx >= 0, idx < autoSwitchablePresets.count else { return }
        let name = autoSwitchablePresets[idx]
        var pool = auto.enabledPresets
        if sender.state == .on { if !pool.contains(name) { pool.append(name) } }
        else { pool.removeAll { $0 == name } }
        auto.setEnabledPresets(pool)
    }

    @objc private func boxesToggled(_ sender: NSButton) {
        engine.showBoxes = sender.tag == 500
        engine.displayChanged.send()
        syncBoxButtons()
    }

    @objc private func glowToggled(_ sender: NSButton)       { engine.glowEnabled         = sender.state == .on; engine.displayChanged.send() }
    @objc private func flashToggled(_ sender: NSButton)      { engine.flashEnabled        = sender.state == .on }
    @objc private func scanLinesToggled(_ sender: NSButton)  { engine.scanLinesEnabled    = sender.state == .on; engine.displayChanged.send() }
    @objc private func chromaToggled(_ sender: NSButton)     { engine.chromaticAberration = sender.state == .on; engine.displayChanged.send() }
    @objc private func strobeToggled(_ sender: NSButton)     { engine.strobeEnabled       = sender.state == .on }
    @objc private func trailToggled(_ sender: NSButton)      { engine.trailEnabled        = sender.state == .on; engine.displayChanged.send() }
    @objc private func trailDecayChanged(_ sender: NSSlider) {
        engine.trailDecay = Float(sender.doubleValue)
        trailDecayLabel.stringValue = String(format: "%.2f", engine.trailDecay)
    }
    @objc private func brightnessChanged(_ sender: NSSlider) {
        engine.brightness = Float(sender.doubleValue)
        brightnessLabel.stringValue = String(format: "%.1f×", engine.brightness)
        engine.displayChanged.send()
    }

    // MARK: - Actions: Text

    @objc private func textModePressed(_ sender: NSButton) {
        let idx = sender.tag - 600
        guard idx >= 0, idx < TextMode.allCases.count else { return }
        engine.setTextMode(TextMode.allCases[idx])
        syncTextModeButtons()
    }

    @objc private func chunkEdited(_ sender: NSTextField) {
        if let v = Int(sender.stringValue) {
            engine.setChunkSize(v)
            chunkLabel?.stringValue = "\(v) chars/tile"
        }
    }

    @objc private func distPressed(_ sender: NSButton) {
        let idx = sender.tag - 700
        guard idx >= 0, idx < Distribution.allCases.count else { return }
        engine.distribution = Distribution.allCases[idx]
        syncDistButtons()
    }

    @objc private func transformPressed(_ sender: NSButton) {
        let idx = sender.tag - 800
        guard idx >= 0, idx < TextTransform.allCases.count else { return }
        engine.textTransform = TextTransform.allCases[idx]
        syncTransformButtons()
    }

    // MARK: - Actions: Style

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        engine.fontFamily = title
        engine.displayChanged.send()
    }

    @objc private func fontSizeChanged(_ sender: NSSlider) {
        engine.fontSizePct = Int(sender.doubleValue)
        fontSizeLabel?.stringValue = "\(engine.fontSizePct)%"
        engine.displayChanged.send()
    }

    @objc private func colorModePressed(_ sender: NSButton) {
        let idx = sender.tag - 1000
        guard idx >= 0, idx < ColorMode.allCases.count else { return }
        engine.colorMode = ColorMode.allCases[idx]
        syncColorModeButtons()
    }

    @objc private func swatchPressed(_ sender: NSButton) {
        let idx = sender.tag - 1100
        guard idx >= 0, idx < neonPalette.count else { return }
        let colorHex = neonPalette[idx]
        engine.globalColor = colorHex
        engine.displayChanged.send()
        syncSwatchButtons()
    }

    @objc private func bgSwatchPressed(_ sender: NSButton) {
        let bgs = ["#000000", "#050505", "#0a0000", "#000a00", "#00000a", "#080808"]
        let idx = sender.tag - 1200
        guard idx >= 0, idx < bgs.count else { return }
        engine.bgColor = bgs[idx]
        engine.displayChanged.send()
    }

    @objc private func colorWellChanged(_ sender: NSColorWell) {
        guard let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        let r = Int((rgb.redComponent   * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent  * 255).rounded())
        engine.globalColor = String(format: "#%02x%02x%02x", r, g, b)
        engine.displayChanged.send()
        syncSwatchButtons()  // deselect palette swatches (custom color active)
    }

    // MARK: - Actions: Play

    @objc private func timingModePressed(_ sender: NSButton) {
        engine.bpmSync = sender.tag == 1301
        engine.updateSpeed()
        syncTimingButtons()
        updateIntervalLabel()
    }

    @objc private func speedChanged(_ sender: NSSlider) {
        engine.speedMs = Int(sender.doubleValue)
        speedLabel?.stringValue = "\(engine.speedMs) ms"
        engine.updateSpeed()
        updateIntervalLabel()
    }

    @objc private func quickSpeed(_ sender: NSButton) {
        let ms = sender.tag - 1320
        if ms > 0 {
            engine.speedMs = ms
            engine.updateSpeed()
            speedLabel?.stringValue = "\(ms) ms"
            if let slider = window?.contentView?.firstDescendant(withTag: 1310) as? NSSlider {
                slider.doubleValue = Double(ms)
            }
        }
    }

    @objc private func bpmEdited(_ sender: NSTextField) {
        if let v = Double(sender.stringValue) {
            engine.bpm = max(40, min(300, v))
            engine.updateSpeed()
            updateIntervalLabel()
        }
    }

    @objc private func tapTempo() {
        let now = CACurrentMediaTime()
        tapTimes.append(now)
        tapTimes = tapTimes.filter { now - $0 < 4.0 }
        if tapTimes.count >= 2 {
            let intervals = zip(tapTimes, tapTimes.dropFirst()).map { $1 - $0 }
            let avg = intervals.reduce(0, +) / Double(intervals.count)
            let bpm = (60.0 / avg * 10).rounded() / 10
            engine.bpm = max(40, min(300, bpm))
            engine.bpmSync = true
            engine.updateSpeed()
            bpmField?.stringValue = String(format: "%.1f", engine.bpm)
            updateIntervalLabel()
        }
    }

    @objc private func divisionPressed(_ sender: NSButton) {
        let vals: [Double] = [2.0, 1.0, 0.5, 0.25]
        let idx = sender.tag - 1500
        guard idx >= 0, idx < vals.count else { return }
        engine.beatDivision = vals[idx]
        midi.setBeatDivision(vals[idx])
        engine.updateSpeed()
        updateIntervalLabel()
        syncDivisionButtons()
    }

    @objc private func moveToScreen(_ sender: NSButton) {
        let idx = sender.tag - 1600
        displayWC.moveToScreen(idx)
    }

    @objc private func toggleFullscreen() {
        displayWC.toggleFullscreen()
    }

    // MARK: - Actions: MIDI

    @objc private func openMidiIn() {
        guard let title = midiInPop?.titleOfSelectedItem, title != "— select port —" else { return }
        midi.openInput(portName: title)
        midiStatusLabel?.stringValue = "MIDI in: \(title)"
    }

    @objc private func closeMidiIn() {
        midi.closeInput()
        midiStatusLabel?.stringValue = "MIDI input closed"
    }

    @objc private func openMidiOut() {
        guard let title = midiOutPop?.titleOfSelectedItem, title != "— select port —" else { return }
        midi.openOutput(portName: title)
        midiStatusLabel?.stringValue = "MIDI out: \(title)"
    }

    @objc private func closeMidiOut() {
        midi.closeOutput()
        midiStatusLabel?.stringValue = "MIDI output closed"
    }

    @objc private func midiEnableToggled(_ sender: NSButton) { midi.enabled = sender.state == .on }
    @objc private func midiSendToggled(_ sender: NSButton)   { midi.sendEnabled = sender.state == .on }

    // MARK: - Actions: Audio

    @objc private func startAudio() {
        let idx = audioDevicePop?.indexOfSelectedItem ?? 0
        let deviceID = idx > 0 ? AudioHandler.availableDevices()[idx - 1].id : nil
        audio.start(deviceID: deviceID)
        audioStatusLabel?.stringValue = "Audio running"
    }

    @objc private func stopAudio() {
        audio.stop()
        audioStatusLabel?.stringValue = "Audio stopped"
    }

    @objc private func audioEnableToggled(_ sender: NSButton) { audio.enabled = sender.state == .on }

    // MARK: - Actions: OSC

    @objc private func startOscServer() {
        let ip   = oscRxIPField?.stringValue   ?? "0.0.0.0"
        let port = Int(oscRxPortField?.stringValue ?? "8000") ?? 8000
        osc.startServer(ip: ip, port: port)
    }

    @objc private func stopOscServer()     { osc.stopServer() }
    @objc private func connectOscClient() {
        let ip   = oscTxIPField?.stringValue   ?? "192.168.1.1"
        let port = Int(oscTxPortField?.stringValue ?? "8001") ?? 8001
        osc.openClient(ip: ip, port: port)
    }
    @objc private func closeOscClient()   { osc.closeClient() }
    @objc private func oscReceiveToggled(_ sender: NSButton) { osc.receiveEnabled = sender.state == .on }
    @objc private func oscSendToggled(_ sender: NSButton)    { osc.sendEnabled    = sender.state == .on }

    // MARK: - Actions: Files

    @objc private func browseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.filePathLabel?.stringValue = url.path
            self?.watcher.watch(path: url.path)
        }
    }

    @objc private func reloadFile()    { watcher.reload() }
    @objc private func stopWatching()  { watcher.stop(); fileStatusLabel?.stringValue = "Watcher stopped" }
    @objc private func watchEnableToggled(_ sender: NSButton) { watcher.enabled = sender.state == .on }

    // MARK: - Actions: Transport

    @objc private func playPressed()    { engine.togglePlay(); updatePlayButton() }
    @objc private func stepBack()       { engine.step(-1) }
    @objc private func stepForward()    { engine.step(1) }
    @objc private func resetPressed()   { engine.reset() }

    // MARK: - Key shortcuts

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:  engine.togglePlay()
        case 124: engine.step(1)
        case 123: engine.step(-1)
        case 15:  engine.reset()
        case 3:   displayWC.toggleFullscreen()
        case 0:   auto.toggleEnabled()           // A
        case 30:  auto.switchNext()              // ]
        case 33:  auto.switchPrevious()          // [
        default:  super.keyDown(with: event)
        }
    }

    // MARK: - Sync helpers

    private func updatePlayButton() {
        playBtn?.title = engine.isPlaying ? "⏸  PAUSE" : "▶  PLAY"
    }

    private func updateIntervalLabel() {
        let ms = engine.effectiveMs
        intervalLabel?.stringValue = "\(ms) ms  (\(String(format: "%.1f", 60_000.0 / Double(ms))) bpm-equiv)"
    }

    private func syncPresetButtons() {
        for (i, name) in presetNames.enumerated() {
            if let btn = window?.contentView?.firstDescendant(withTag: 200 + i) as? NSButton {
                btn.state = name == engine.presetName ? .on : .off
            }
        }
    }

    private func syncAutoControls() {
        if let btn = window?.contentView?.firstDescendant(withTag: 300) as? NSButton { btn.state = auto.enabled ? .on : .off }
        if let seq = window?.contentView?.firstDescendant(withTag: 301) as? NSButton { seq.state = auto.mode == "sequential" ? .on : .off }
        if let rnd = window?.contentView?.firstDescendant(withTag: 302) as? NSButton { rnd.state = auto.mode == "random" ? .on : .off }
    }

    private func syncBoxButtons() {
        if let on  = window?.contentView?.firstDescendant(withTag: 500) as? NSButton { on.state  = engine.showBoxes ? .on : .off }
        if let off = window?.contentView?.firstDescendant(withTag: 501) as? NSButton { off.state = engine.showBoxes ? .off : .on }
    }

    private func syncTextModeButtons() {
        for (i, mode) in TextMode.allCases.enumerated() {
            if let btn = window?.contentView?.firstDescendant(withTag: 600 + i) as? NSButton {
                btn.state = engine.textMode == mode ? .on : .off
            }
        }
    }

    private func syncDistButtons() {
        for (i, dist) in Distribution.allCases.enumerated() {
            if let btn = window?.contentView?.firstDescendant(withTag: 700 + i) as? NSButton {
                btn.state = engine.distribution == dist ? .on : .off
            }
        }
    }

    private func syncTransformButtons() {
        for (i, tt) in TextTransform.allCases.enumerated() {
            if let btn = window?.contentView?.firstDescendant(withTag: 800 + i) as? NSButton {
                btn.state = engine.textTransform == tt ? .on : .off
            }
        }
    }

    private func syncColorModeButtons() {
        for (i, mode) in ColorMode.allCases.enumerated() {
            if let btn = window?.contentView?.firstDescendant(withTag: 1000 + i) as? NSButton {
                btn.state = engine.colorMode == mode ? .on : .off
            }
        }
    }

    private func syncSwatchButtons() {
        for (btn, colorHex) in swatchButtons {
            btn.layer?.borderWidth = colorHex == engine.globalColor ? 2 : 0
            btn.layer?.borderColor = NSColor.white.cgColor
        }
        // Keep the color well showing the current global color
        customColorWell?.color = NSColor(hex: engine.globalColor) ?? .orange
    }

    private func syncTimingButtons() {
        if let m = window?.contentView?.firstDescendant(withTag: 1300) as? NSButton { m.state = !engine.bpmSync ? .on : .off }
        if let b = window?.contentView?.firstDescendant(withTag: 1301) as? NSButton { b.state =  engine.bpmSync ? .on : .off }
    }

    private func syncDivisionButtons() {
        let vals: [Double] = [2.0, 1.0, 0.5, 0.25]
        for (i, v) in vals.enumerated() {
            if let btn = window?.contentView?.firstDescendant(withTag: 1500 + i) as? NSButton {
                btn.state = engine.beatDivision == v ? .on : .off
            }
        }
    }

    private func setStatus(_ msg: String) {
        if let lbl = window?.contentView?.firstDescendant(withTag: 9999) as? NSTextField {
            lbl.stringValue = msg
        }
    }

    // MARK: - Window delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApplication.shared.terminate(nil)
        return true
    }
}

// MARK: - NSTextView delegate (text input)

extension ControlWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView, tv === textView else { return }
        engine.setText(tv.string)
    }
}

// MARK: - UI builder helpers

private func vStack(spacing: CGFloat = 8, margins: CGFloat = 12) -> NSStackView {
    let s = NSStackView()
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = spacing
    s.edgeInsets = NSEdgeInsets(top: margins, left: margins, bottom: margins, right: margins)
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

private func hStack(spacing: CGFloat = 6) -> NSStackView {
    let s = NSStackView()
    s.orientation = .horizontal
    s.spacing = spacing
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

private func makeLabel(_ text: String) -> NSTextField {
    let lbl = NSTextField(labelWithString: text)
    lbl.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    lbl.textColor = NSColor(white: 0.55, alpha: 1)
    return lbl
}

private func sectionLabel(_ text: String) -> NSTextField {
    let lbl = NSTextField(labelWithString: text)
    lbl.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
    lbl.textColor = NSColor(white: 0.35, alpha: 1)
    return lbl
}

private func divider() -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
    v.heightAnchor.constraint(equalToConstant: 1).isActive = true
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
}

private func toggleButton(_ title: String, tag: Int, action: Selector) -> NSButton {
    let btn = NSButton(title: title, target: nil, action: action)
    btn.setButtonType(.pushOnPushOff)
    btn.bezelStyle = .rounded
    btn.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    btn.tag = tag
    return btn
}

private func actionButton(_ title: String, tag: Int) -> NSButton {
    let btn = NSButton(title: title, target: nil, action: nil)
    btn.bezelStyle = .rounded
    btn.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    btn.tag = tag
    return btn
}

private func scrollWrap(_ view: NSView) -> NSView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = view
    scroll.drawsBackground = false
    // Pin the document view width to the scroll view width
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalTo: scroll.widthAnchor),
    ])
    return scroll
}

private extension ControlWindowController {
    func makeColorSwatch(_ hex: String, selected: Bool, tag: Int) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        btn.title = ""            // no text — pure color block
        btn.bezelStyle = .rounded
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor(hex: hex)?.cgColor ?? NSColor.black.cgColor
        btn.layer?.borderWidth = selected ? 2 : 0
        btn.layer?.borderColor = NSColor.white.cgColor
        btn.layer?.cornerRadius = 2
        btn.widthAnchor.constraint(equalToConstant: 26).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        btn.tag = tag
        if tag >= 1200 {
            btn.target = self; btn.action = #selector(bgSwatchPressed(_:))
        } else {
            btn.target = self; btn.action = #selector(swatchPressed(_:))
        }
        return btn
    }
}

// MARK: - NSView tag search helper

private extension NSView {
    func firstDescendant(withTag tag: Int) -> NSView? {
        if self.tag == tag { return self }
        for sub in subviews {
            if let found = sub.firstDescendant(withTag: tag) { return found }
        }
        return nil
    }
}
