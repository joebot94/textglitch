// FileWatcher.swift — Hot-reload text file on disk changes (port of file_watcher.py)

import Foundation

final class FileWatcher {
    weak var engine: GridEngine?

    var enabled: Bool = true

    // Callbacks
    var onFileLoaded: ((String) -> Void)?
    var onFileError: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    private var watchedPath: String = ""
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var lastSize: Int = -1
    private let queue = DispatchQueue(label: "filewatch", qos: .utility)

    // MARK: - Watch

    func watch(path: String) {
        stop()
        guard !path.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            onFileError?("File not found: \(path)")
            return
        }
        watchedPath = path
        load(path: path)

        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            onFileError?("Cannot open for watching: \(path)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: queue
        )

        source?.setEventHandler { [weak self] in
            guard let self, self.enabled else { return }
            // Debounce by size
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1
            guard size != self.lastSize else { return }
            self.lastSize = size
            self.load(path: path)
        }

        source?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 { close(fd) }
            self?.fileDescriptor = -1
        }

        source?.resume()
        onStatus?("Watching: \((path as NSString).lastPathComponent)")
    }

    func stop() {
        source?.cancel()
        source = nil
        watchedPath = ""
        lastSize = -1
    }

    func reload() {
        guard !watchedPath.isEmpty else { return }
        load(path: watchedPath)
    }

    // MARK: - File I/O

    private func load(path: String) {
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let lines = text.components(separatedBy: "\n").count
            DispatchQueue.main.async { [weak self] in
                self?.onFileLoaded?(text)
                self?.engine?.setText(text)
                self?.onStatus?("Loaded: \((path as NSString).lastPathComponent)  (\(lines) lines)")
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onFileError?("Read error: \(error.localizedDescription)")
            }
        }
    }

    func shutdown() { stop() }
}
