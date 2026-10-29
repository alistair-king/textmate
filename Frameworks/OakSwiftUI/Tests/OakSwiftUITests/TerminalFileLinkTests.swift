import AppKit
import Testing
@testable import OakSwiftUI

@Test func terminalFileReferenceParsing() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["main.swift", "file with spaces.swift", "日本語.swift", ".hidden"] {
        try "test".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let reference = try #require(TerminalFileReference.resolve("main.swift:42:7:", directory: folder.path))
    #expect(reference.url.path == folder.appendingPathComponent("main.swift").path)
    #expect(reference.line == 42)
    #expect(reference.column == 7)
    #expect(TerminalFileReference.resolve(folder.appendingPathComponent("file with spaces.swift").absoluteString, directory: "/") != nil)
    #expect(TerminalFileReference.resolve("file://remote.invalid" + folder.appendingPathComponent("main.swift").path, directory: folder.path) == nil)
    #expect(TerminalFileReference.resolve("missing.swift:9", directory: folder.path) == nil)
    #expect(TerminalFileReference.resolve(folder.path, directory: folder.path) == nil)
    #expect(TerminalFileReference.resolve("https://example.com/main.swift", directory: folder.path) == nil)
    let matches = TerminalFileReference.matches(in: "error: \"file with spaces.swift\":12:3 and 日本語.swift:8, .hidden", directory: folder.path)
    #expect(matches.count == 3)
    #expect(matches.first?.1.line == 12)
    #expect(matches.first?.1.column == 3)
}

@MainActor
@Test func terminalFileClicksAndDirectoryHistory() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let other = folder.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for parent in [folder, other] {
        try "test".write(to: parent.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    }
    let owner = makeTerminalController()
    let terminal = FileLinkTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    terminal.owner = owner
    terminal.launchDirectory = folder.path
    let window = NSWindow(contentRect: terminal.frame, styleMask: .titled, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = terminal
    defer { window.contentView = nil }
    terminal.feed(text: "main.swift:42:7\r\n")
    for _ in 0..<100 {
        if terminal.terminalContentSnapshot(region: .viewport)?.rows.first?.text.contains("main.swift") == true { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    terminal.noteDirectoryIfChanged()
    terminal.reportedDirectory = other.path
    terminal.noteDirectoryIfChanged()
    let size = terminal.getWindowSize()
    let scale = window.backingScaleFactor
    let cellWidth = CGFloat(size.ws_xpixel) / CGFloat(size.ws_col) / scale
    let cellHeight = CGFloat(size.ws_ypixel) / CGFloat(size.ws_row) / scale
    let point = NSPoint(x: cellWidth * 2.5, y: terminal.bounds.maxY - cellHeight / 2)
    let hit = try #require(terminal.fileHit(at: point))
    #expect(hit.reference.url.path == folder.appendingPathComponent("main.swift").path)
    #expect(hit.reference.line == 42)
    #expect(hit.reference.column == 7)
    let delegate = TerminalTestDelegate()
    owner.delegate = delegate
    func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: terminal.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    terminal.mouseDown(with: try event(.leftMouseDown, modifiers: []))
    terminal.mouseUp(with: try event(.leftMouseUp, modifiers: []))
    #expect(delegate.opened == nil)
    terminal.mouseDown(with: try event(.leftMouseDown, modifiers: [.command]))
    terminal.mouseUp(with: try event(.leftMouseUp, modifiers: [.command]))
    #expect(delegate.opened?.0 == hit.reference.url)
    #expect(delegate.opened?.1 == 42)
    #expect(delegate.opened?.2 == 7)
    terminal.requestOpenLink(source: terminal, link: other.appendingPathComponent("main.swift").absoluteString, params: [:])
    #expect(delegate.opened?.0.path == other.appendingPathComponent("main.swift").path)
    delegate.opened = nil
    terminal.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}]8;;\(other.appendingPathComponent("main.swift").absoluteString)\u{1b}\\main.swift\u{1b}]8;;\u{1b}\\")
    try await Task.sleep(for: .milliseconds(100))
    terminal.mouseDown(with: try event(.leftMouseDown, modifiers: [.command]))
    terminal.mouseUp(with: try event(.leftMouseUp, modifiers: [.command]))
    #expect(delegate.opened?.0.path == other.appendingPathComponent("main.swift").path)
}

@MainActor
@Test func terminalTracksShellDirectoryAfterCD() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let controller = makeTerminalController()
    controller.startSession(inDirectory: NSHomeDirectory())
    defer { controller.stopSession() }
    let terminal = try #require(controller.terminal as? FileLinkTerminalView)
    terminal.send(txt: "cd '\(folder.path)'\n")
    for _ in 0..<100 {
        if URL(fileURLWithPath: terminal.currentDirectory).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Terminal did not follow the shell directory after cd")
}

@MainActor
@Test func terminalFileLinksAcrossWrappedRows() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let name = String(repeating: "a", count: 90) + ".swift"
    try "test".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    let terminal = FileLinkTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
    terminal.launchDirectory = folder.path
    terminal.feed(text: name + ":12:3\r\n")
    for _ in 0..<100 {
        if terminal.terminalContentSnapshot(region: .viewport)?.rows.contains(where: { $0.text.contains("swift") }) == true { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let size = terminal.getWindowSize()
    let scale = NSScreen.main?.backingScaleFactor ?? 1
    let height = CGFloat(size.ws_ypixel) / CGFloat(size.ws_row) / scale
    let hit = try #require(terminal.fileHit(at: NSPoint(x: 5, y: terminal.bounds.maxY - height * 1.5)))
    #expect(hit.reference.url.lastPathComponent == name)
    #expect(hit.reference.line == 12)
    #expect(hit.reference.column == 3)
    #expect(Set(hit.rects.map(\.minY)).count > 1)
}

@Test func localHostMatchesShortAndQualifiedNames() {
    var buffer = [CChar](repeating: 0, count: 256)
    gethostname(&buffer, buffer.count - 1)
    let short = String(cString: buffer).split(separator: ".").first.map(String.init) ?? ""
    #expect(LocalHost.isLocal(nil))
    #expect(LocalHost.isLocal(""))
    #expect(LocalHost.isLocal("LocalHost"))
    #expect(LocalHost.isLocal(short))
    #expect(LocalHost.isLocal("\(short.uppercased()).example.invalid"))
    #expect(!LocalHost.isLocal("remote.invalid"))
}

@MainActor
@Test func terminalOptsOutOfEditorKeyEquivalents() {
    let terminal = FileLinkTerminalView(frame: .zero)
    #expect(terminal.responds(to: NSSelectorFromString("oak_ownsKeyEquivalents")))
}

@MainActor
@Test func directoryMarkersRecordOnlyChanges() async throws {
    let terminal = FileLinkTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    terminal.launchDirectory = "/a"
    let columns = terminal.terminalDimensions.cols
    terminal.feed(text: "one\r\ntwo\r\n")
    terminal.noteDirectoryIfChanged()
    terminal.noteDirectoryIfChanged()
    #expect(terminal.recordedDirectory(forRow: 0, columns: columns) == "/a")

    terminal.reportedDirectory = "/b"
    terminal.feed(text: "three\r\n")
    terminal.noteDirectoryIfChanged()
    terminal.feed(text: "four\r\n")
    terminal.noteDirectoryIfChanged() // unchanged: must not add a marker that would move the boundary
    #expect(terminal.recordedDirectory(forRow: 1, columns: columns) == "/a")
    #expect(terminal.recordedDirectory(forRow: 2, columns: columns) == "/a")
    #expect(terminal.recordedDirectory(forRow: 3, columns: columns) == "/b")
    #expect(terminal.recordedDirectory(forRow: 4, columns: columns) == "/b")
    #expect(terminal.recordedDirectory(forRow: 0, columns: columns + 1) == nil) // resized since recording
}
