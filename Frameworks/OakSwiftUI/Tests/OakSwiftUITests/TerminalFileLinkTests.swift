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
    let owner = OakTerminalPanelController()
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
    terminal.recordOutputDirectories()
    terminal.reportedDirectory = other.path
    let size = terminal.getWindowSize()
    let scale = window.backingScaleFactor
    let cellWidth = CGFloat(size.ws_xpixel) / CGFloat(size.ws_col) / scale
    let cellHeight = CGFloat(size.ws_ypixel) / CGFloat(size.ws_row) / scale
    let point = NSPoint(x: cellWidth * 2.5, y: terminal.bounds.maxY - cellHeight / 2)
    let hit = try #require(terminal.fileHit(at: point))
    #expect(hit.reference.url.path == folder.appendingPathComponent("main.swift").path)
    #expect(hit.reference.line == 42)
    #expect(hit.reference.column == 7)
    var opened: (URL, Int, Int)?
    owner.openFile = { opened = ($0, $1, $2) }
    func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: terminal.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    terminal.mouseDown(with: try event(.leftMouseDown, modifiers: []))
    terminal.mouseUp(with: try event(.leftMouseUp, modifiers: []))
    #expect(opened == nil)
    terminal.mouseDown(with: try event(.leftMouseDown, modifiers: [.command]))
    terminal.mouseUp(with: try event(.leftMouseUp, modifiers: [.command]))
    #expect(opened?.0 == hit.reference.url)
    #expect(opened?.1 == 42)
    #expect(opened?.2 == 7)
    terminal.requestOpenLink(source: terminal, link: other.appendingPathComponent("main.swift").absoluteString, params: [:])
    #expect(opened?.0.path == other.appendingPathComponent("main.swift").path)
    opened = nil
    terminal.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}]8;;\(other.appendingPathComponent("main.swift").absoluteString)\u{1b}\\main.swift\u{1b}]8;;\u{1b}\\")
    try await Task.sleep(for: .milliseconds(100))
    terminal.mouseDown(with: try event(.leftMouseDown, modifiers: [.command]))
    terminal.mouseUp(with: try event(.leftMouseUp, modifiers: [.command]))
    #expect(opened?.0.path == other.appendingPathComponent("main.swift").path)
}

@MainActor
@Test func terminalTracksShellDirectoryAfterCD() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let controller = OakTerminalPanelController()
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
