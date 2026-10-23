import AppKit
import Darwin
import SwiftTerm

struct TerminalFileReference: Equatable {
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
                  parsed.host == nil || parsed.host == "" || parsed.host == "localhost" || parsed.host == ProcessInfo.processInfo.hostName else { return nil }
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
        // Quoted paths may contain spaces; unquoted paths terminate at shell/output delimiters.
        let pattern = #"(?:"[^"\r\n]+"|'[^'\r\n]+')(?::[1-9][0-9]*(?::[1-9][0-9]*)?)?|[^\s<>\[\](){}"'`,;]+"#
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
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
    private var rowDirectories: [Int: (text: String, directory: String)] = [:]
    private var recordedColumns = 0
    private var outputCapturePending = false

    func scheduleOutputCapture() {
        guard !outputCapturePending else { return }
        outputCapturePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.outputCapturePending = false
            self.recordOutputDirectories()
        }
    }
    private var eventMonitor: Any?
    private var underlineLayers: [CALayer] = []
    private var pressedLink: TerminalFileReference?
    private var pressedPoint = NSPoint.zero
    private var handledNativeLink = false

    func clearFileLinkHistory() { rowDirectories.removeAll(); clearHighlight() }

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

    func recordOutputDirectories() {
        guard let snapshot = terminalContentSnapshot(region: .history(maximumScrollbackRows: 300)), !snapshot.inputState.isAlternateBuffer else { return }
        if recordedColumns != snapshot.inputState.dimensions.cols {
            rowDirectories.removeAll() // Reflow changes the relationship between rows and output.
            recordedColumns = snapshot.inputState.dimensions.cols
        }
        let directory = currentDirectory
        for row in snapshot.rows where !row.text.isEmpty {
            if rowDirectories[row.absoluteRow]?.text != row.text {
                rowDirectories[row.absoluteRow] = (row.text, directory)
            }
        }
        if rowDirectories.count > 10000 {
            let oldest = rowDirectories.keys.sorted().prefix(rowDirectories.count - 10000)
            for key in oldest { rowDirectories.removeValue(forKey: key) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        clearHighlight()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .flagsChanged, .scrollWheel, .leftMouseDragged]) { [weak self] event in
            if event.type == .keyDown {
                if let self, self.owner?.handleTerminalKeyEvent(event, source: self) == true { return nil }
            } else {
                self?.updateHighlight(event)
            }
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
              let window, let hit = fileHit(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        NSCursor.pointingHand.set()
        for rect in hit.rects {
            let underline = CALayer()
            underline.backgroundColor = nativeForegroundColor.cgColor
            underline.frame = NSRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: 1)
            layer?.addSublayer(underline)
            underlineLayers.append(underline)
        }
    }

    // Snapshot cells preserve wide Unicode glyphs and soft wraps without reading mutable terminal state.
    func fileHit(at point: NSPoint) -> (reference: TerminalFileReference, rects: [NSRect])? {
        guard bounds.contains(point), let snapshot = terminalContentSnapshot(region: .viewport), !snapshot.inputState.isAlternateBuffer else { return nil }
        let size = getWindowSize()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let cellWidth = CGFloat(size.ws_xpixel) / CGFloat(max(1, size.ws_col)) / scale
        let cellHeight = CGFloat(size.ws_ypixel) / CGFloat(max(1, size.ws_row)) / scale
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
        let recorded = rowDirectories[row.absoluteRow]
        let directory = recorded?.text == row.text ? recorded!.directory : currentDirectory
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
        owner?.openFile?(reference.url, reference.line ?? 0, reference.column ?? 0)
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
