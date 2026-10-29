import AppKit
import Darwin
import SwiftTerm

enum LocalHost {
    // ProcessInfo.hostName does a reverse-DNS lookup that can block for seconds, and this runs on every OSC 7 report.
    private static let shortNames: Set<String> = {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count - 1)
        return [shortName(String(cString: buffer))]
    }()

    private static func shortName(_ host: String) -> String {
        host.lowercased().split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
    }

    static func isLocal(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true }
        return host.lowercased() == "localhost" || shortNames.contains(shortName(host))
    }
}

struct TerminalFileReference: Equatable {
    // Quoted paths may contain spaces; unquoted paths terminate at shell/output delimiters.
    private static let tokenRegex = try! NSRegularExpression(pattern: #"(?:"[^"\r\n]+"|'[^'\r\n]+')(?::[1-9][0-9]*(?::[1-9][0-9]*)?)?|[^\s<>\[\](){}"'`,;]+"#)

    let url: URL
    let line: Int?
    let column: Int?

    static func resolve(_ text: String, directory: String) -> TerminalFileReference? {
        var path = text
        var line: Int?
        var column: Int?
        if let match = path.range(of: #":([1-9][0-9]*)(?::([1-9][0-9]*))?:?$"#, options: .regularExpression) {
            let numbers = path[match].split(separator: ":").compactMap { Int($0) }
            line = numbers.first
            column = numbers.count > 1 ? numbers[1] : nil
            path.removeSubrange(match)
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let url: URL
        if path.hasPrefix("file:") {
            guard let parsed = URL(string: path), parsed.isFileURL,
                  LocalHost.isLocal(parsed.host) else { return nil }
            url = parsed
        } else {
            guard !path.contains("://"), !path.isEmpty else { return nil }
            let expanded = (path as NSString).expandingTildeInPath
            url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: directory).appendingPathComponent(expanded)
        }
        let normalized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return TerminalFileReference(url: normalized, line: line, column: column)
    }

    static func matches(in text: String, directory: String) -> [(NSRange, TerminalFileReference)] {
        tokenRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let token = (text as NSString).substring(with: match.range)
            if let reference = resolve(token, directory: directory) { return (match.range, reference) }
            // Sentence punctuation is not part of a compiler's path.
            var trimmed = token
            while trimmed.last == "." || trimmed.last == ":" { trimmed.removeLast() }
            guard let reference = resolve(trimmed, directory: directory) else { return nil }
            return (NSRange(location: match.range.location, length: (trimmed as NSString).length), reference)
        }
    }
}

@MainActor
final class FileLinkTerminalView: LocalProcessTerminalView {
    weak var owner: OakTerminalPanelController?
    var launchDirectory = NSHomeDirectory()
    var reportedDirectory: String?
    // Where the shell changed directory, by scroll-invariant row. Relative paths in older output resolve against
    // the directory that was current when they were printed, which only changes at these points.
    private var directoryMarkers: [(row: Int, directory: String)] = []
    private var markerColumns = 0
    private var directoryCheckPending = false
    private var lastDirectoryCheck: TimeInterval = 0

    func scheduleOutputCapture() {
        hoverCache = nil
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDirectoryCheck >= 0.05 {
            lastDirectoryCheck = now
            noteDirectoryIfChanged()
        } else if !directoryCheckPending {
            directoryCheckPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.directoryCheckPending = false
                self.lastDirectoryCheck = ProcessInfo.processInfo.systemUptime
                self.noteDirectoryIfChanged()
            }
        }
    }
    private var eventMonitor: Any?
    private var underlineLayers: [CALayer] = []
    private var pressedLink: TerminalFileReference?
    private var pressedPoint = NSPoint.zero
    private var handledNativeLink = false
    private var hoverCache: (cell: [Int], time: TimeInterval, hit: (reference: TerminalFileReference, rects: [NSRect])?)?

    func clearFileLinkHistory() { directoryMarkers.removeAll(); hoverCache = nil; clearHighlight() }

    /// Looked up by selector in OakTextView.performKeyEquivalent: so editor bundle bindings skip the document while the terminal has focus.
    @objc func oak_ownsKeyEquivalents() -> Bool { true }

    static func processDirectory(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            let path = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            return path.isEmpty ? nil : path
        }
    }

    var currentDirectory: String {
        Self.processDirectory(pid: process.shellPid) ?? reportedDirectory ?? launchDirectory
    }

    /// Cheap on every call: reading the shell directory is one syscall, and the screen is only touched when it changed.
    func noteDirectoryIfChanged() {
        if directoryMarkers.isEmpty {
            directoryMarkers = [(Int.min, launchDirectory)]
            markerColumns = terminalDimensions.cols
        }
        let directory = currentDirectory
        guard directory != directoryMarkers.last?.directory,
              let snapshot = terminalContentSnapshot(region: .history(maximumScrollbackRows: -1)),
              !snapshot.inputState.isAlternateBuffer else { return }
        if markerColumns != snapshot.inputState.dimensions.cols {
            // Reflow changed which rows hold which output, so older markers no longer apply.
            directoryMarkers = [(Int.min, directory)]
            markerColumns = snapshot.inputState.dimensions.cols
            return
        }
        directoryMarkers.append((snapshot.cursorRow, directory))
        if directoryMarkers.count > 500 { directoryMarkers.removeFirst(250) }
    }

    /// The directory current when `row` was printed, or nil when that is unknown (no change recorded, or the terminal was resized since).
    func recordedDirectory(forRow row: Int, columns: Int) -> String? {
        guard columns == markerColumns else { return nil }
        return directoryMarkers.last { $0.row <= row }?.directory
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        clearHighlight()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .flagsChanged, .scrollWheel, .leftMouseDragged]) { [weak self] event in
            self?.updateHighlight(event)
            return event
        }
    }

    private func clearHighlight() {
        if !underlineLayers.isEmpty { NSCursor.iBeam.set() }
        for layer in underlineLayers { layer.removeFromSuperlayer() }
        underlineLayers.removeAll()
    }

    private func updateHighlight(_ event: NSEvent) {
        clearHighlight()
        guard event.window === window, event.modifierFlags.contains(.command),
              event.type != .scrollWheel, event.type != .leftMouseDragged,
              let window, let hit = cachedFileHit(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        NSCursor.pointingHand.set()
        for rect in hit.rects {
            let underline = CALayer()
            underline.backgroundColor = nativeForegroundColor.cgColor
            underline.frame = NSRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: 1)
            layer?.addSublayer(underline)
            underlineLayers.append(underline)
        }
    }

    // Mouse moves arrive per pixel; the hit (regex plus a stat per token) only changes per cell or when output arrives.
    private func cachedFileHit(at point: NSPoint) -> (reference: TerminalFileReference, rects: [NSRect])? {
        let cell = cellSize()
        guard cell.width > 0, cell.height > 0 else { return fileHit(at: point) }
        let key = [Int((bounds.maxY - point.y) / cell.height), Int((point.x - bounds.minX) / cell.width)]
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = hoverCache, cache.cell == key, now - cache.time < 0.5 { return cache.hit }
        let hit = fileHit(at: point)
        hoverCache = (key, now, hit)
        return hit
    }

    private func cellSize() -> CGSize {
        let size = getWindowSize()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return CGSize(width: CGFloat(size.ws_xpixel) / CGFloat(max(1, size.ws_col)) / scale,
                      height: CGFloat(size.ws_ypixel) / CGFloat(max(1, size.ws_row)) / scale)
    }

    // Snapshot cells preserve wide Unicode glyphs and soft wraps without reading mutable terminal state.
    func fileHit(at point: NSPoint) -> (reference: TerminalFileReference, rects: [NSRect])? {
        guard bounds.contains(point), let snapshot = terminalContentSnapshot(region: .viewport), !snapshot.inputState.isAlternateBuffer else { return nil }
        let cell = cellSize()
        let (cellWidth, cellHeight) = (cell.width, cell.height)
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let rowIndex = Int((bounds.maxY - point.y) / cellHeight)
        let column = Int((point.x - bounds.minX) / cellWidth)
        guard snapshot.rows.indices.contains(rowIndex), column < snapshot.inputState.dimensions.cols else { return nil }
        var first = rowIndex
        while first > 0 && snapshot.rows[first].isWrapped { first -= 1 }
        var last = rowIndex
        while last + 1 < snapshot.rows.count && snapshot.rows[last + 1].isWrapped { last += 1 }
        var text = ""
        var cells: [(range: NSRange, rect: NSRect)] = []
        var clickedOffset: Int?
        for r in first...last {
            for (c, cell) in snapshot.rows[r].cells.enumerated() where cell.width > 0 {
                let value = cell.text.isEmpty || cell.text == "\0" ? " " : cell.text
                let offset = (text as NSString).length
                let range = NSRange(location: offset, length: (value as NSString).length)
                if r == rowIndex && (c..<c + cell.width).contains(column) { clickedOffset = offset }
                text += value
                cells.append((range, NSRect(x: CGFloat(c) * cellWidth, y: bounds.maxY - CGFloat(r + 1) * cellHeight, width: CGFloat(cell.width) * cellWidth, height: cellHeight)))
            }
        }
        guard let clickedOffset else { return nil }
        let row = snapshot.rows[first]
        let directory = recordedDirectory(forRow: row.absoluteRow, columns: snapshot.inputState.dimensions.cols) ?? currentDirectory
        guard let match = TerminalFileReference.matches(in: text, directory: directory).first(where: { NSLocationInRange(clickedOffset, $0.0) }) else { return nil }
        return (match.1, cells.filter { NSIntersectionRange($0.range, match.0).length > 0 }.map(\.rect))
    }

    override func mouseDown(with event: NSEvent) {
        pressedLink = nil
        if event.modifierFlags.contains(.command), let hit = fileHit(at: convert(event.locationInWindow, from: nil)) {
            pressedLink = hit.reference
            pressedPoint = event.locationInWindow
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        handledNativeLink = false
        // Explicit OSC 8 hyperlinks take precedence over a filename in their caption.
        super.mouseUp(with: event)
        defer { pressedLink = nil; clearHighlight() }
        if !handledNativeLink, let pressedLink,
           event.modifierFlags.contains(.command),
           hypot(event.locationInWindow.x - pressedPoint.x, event.locationInWindow.y - pressedPoint.y) < 4,
           fileHit(at: convert(event.locationInWindow, from: nil))?.reference == pressedLink {
            openFile(pressedLink)
        }
    }

    private func openFile(_ reference: TerminalFileReference) {
        owner?.requestOpenFile(reference.url, line: reference.line ?? 0, column: reference.column ?? 0)
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        handledNativeLink = true
        if let file = TerminalFileReference.resolve(link, directory: currentDirectory) {
            openFile(file)
        } else if let scheme = URL(string: link)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            super.requestOpenLink(source: source, link: link, params: params)
        }
    }
}
