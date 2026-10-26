import Testing
import AppKit
import SwiftTerm
import Darwin
@testable import OakSwiftUI

@MainActor
@Test func customTerminalTitleSurvivesShellUpdatesAndTransfer() async throws {
    _ = NSApplication.shared
    let source = OakTerminalPanelController()
    let destination = OakTerminalPanelController()
    source.startSession(inDirectory: NSTemporaryDirectory())
    defer {
        source.stopSession()
        destination.stopSession()
    }
    let terminal = try #require(source.terminal)
    let identifier = try #require(source.sessionIdentifiers.first)
    source.renameSession(at: 0, title: "  Build 😀  ")
    source.setTerminalTitle(source: terminal, title: "shell title")
    #expect(source.sessionTitles == ["Build 😀"])

    source.transferSession(identifier: identifier, to: destination, at: 0)
    #expect(destination.sessionTitles == ["Build 😀"])
    #expect(destination.terminal === terminal)
    destination.setTerminalTitle(source: terminal, title: "new shell title")
    #expect(destination.sessionTitles == ["Build 😀"])
    destination.renameSession(at: 0, title: " ")
    #expect(destination.sessionTitles == ["new shell title"])
    destination.renameSession(at: -1, title: "invalid")
    destination.renameSession(at: 1, title: "invalid")
    #expect(destination.sessionTitles == ["new shell title"])
}

@MainActor
@Test func clearShortcutRequiresTerminalFocus() async throws {
    _ = NSApplication.shared
    let controller = OakTerminalPanelController()
    controller.startSession(inDirectory: NSTemporaryDirectory())
    defer { controller.stopSession() }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(controller.view)
    controller.view.frame = window.contentView!.bounds
    let terminal = try #require(controller.terminal)

    func commandK() throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        return controller.view.performKeyEquivalent(with: event)
    }

    window.makeFirstResponder(terminal)
    #expect(try commandK())
    let otherView = NSView(frame: .zero)
    window.contentView?.addSubview(otherView)
    window.makeFirstResponder(otherView)
    #expect(try !commandK())
    controller.stopSession()
    #expect(try !commandK())
}

@MainActor
@Test func terminalSessionLifecycleAndResize() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TextMate terminal test \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let controller = OakTerminalPanelController()
    controller.applyTheme(background: .black, foreground: .white, caret: .green, selection: .blue)
    controller.startSession(inDirectory: folder.path)
    defer { controller.stopSession() }
    let terminal = try #require(controller.terminal)
    #expect(terminal.nativeBackgroundColor == .black)
    #expect(terminal.nativeForegroundColor == .white)
    #expect(terminal.caretColor == .green)
    #expect(terminal.selectedTextBackgroundColor == .blue)
    controller.applyTheme(background: .white, foreground: .black, caret: .red, selection: .yellow)
    #expect(terminal.nativeBackgroundColor == .white)
    #expect(terminal.nativeForegroundColor == .black)
    #expect(terminal.caretColor == .red)
    #expect(terminal.selectedTextBackgroundColor == .yellow)
    let pid = terminal.process.shellPid
    #expect(pid > 0)

    func waitForFile(_ name: String) async throws -> String {
        let file = folder.appendingPathComponent(name)
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty { return text }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("Shell did not create \(name)")
        return ""
    }
    terminal.send(txt: "pwd > cwd.txt\n")
    let cwd = try await waitForFile("cwd.txt")
    #expect(URL(fileURLWithPath: cwd.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    controller.startSession(inDirectory: NSHomeDirectory())
    #expect(terminal.process.shellPid == pid)

    for size in [NSSize(width: 700, height: 300), NSSize(width: 0, height: 0), NSSize(width: 400, height: 180)] {
        controller.view.frame.size = size
        controller.view.layoutSubtreeIfNeeded()
        #expect(terminal.terminalDimensions.cols > 0)
        #expect(terminal.terminalDimensions.rows > 0)
    }
    terminal.send(txt: "stty size > size.txt\n")
    let size = try await waitForFile("size.txt")
    #expect(size.split(whereSeparator: \.isWhitespace).compactMap { Int($0) } == [terminal.terminalDimensions.rows, terminal.terminalDimensions.cols])

    for _ in 0..<50 {
        if !controller.hasRunningWork { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(!controller.hasRunningWork)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
    host.addSubview(controller.view)
    controller.view.removeFromSuperview()
    host.addSubview(controller.view)
    #expect(terminal.process.shellPid == pid)

    terminal.send(txt: "exit\n")
    for _ in 0..<100 {
        if controller.sessionCount == 0 { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(controller.sessionCount == 0)
    #expect(controller.terminal == nil)
    #expect(!controller.hasRunningWork)
    controller.newTerminal()
    let restartedTerminal = try #require(controller.terminal)
    #expect(restartedTerminal.nativeBackgroundColor == .white)
    #expect(restartedTerminal.nativeForegroundColor == .black)
    #expect(restartedTerminal.caretColor == .red)
    #expect(restartedTerminal.selectedTextBackgroundColor == .yellow)
    let restartedPID = restartedTerminal.process.shellPid
    #expect(restartedPID > 0 && restartedPID != pid)
    restartedTerminal.send(txt: "sleep 30 & echo ready > work.txt\n")
    _ = try await waitForFile("work.txt")
    #expect(controller.hasRunningWork)
    controller.stopSession()
    for _ in 0..<100 {
        if kill(restartedPID, 0) != 0 { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(kill(restartedPID, 0) != 0)
    #expect(controller.terminal == nil)
}

@MainActor
@Test func explanationCommandKeepsArgumentsAndExistingSession() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TextMate explanation 'quoted' 😀 \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let command = folder.appendingPathComponent("mock agent")
    // The stub writes in its current directory, requiring no quoting of the path.
    try "#!/bin/sh\nprintf '%s\\000' \"$@\" > arguments.bin\nprintf '%s' \"$TM_CONTEXT_TOKEN\" > context.txt\npwd > directory.txt\n".write(to: command, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
    let controller = OakTerminalPanelController()
    var credentialsCreated = 0
    controller.contextEnvironmentProvider = { _ in
        credentialsCreated += 1
        return ["TM_CONTEXT_TOKEN": "explanation-test-token"]
    }
    controller.startSession(inDirectory: NSTemporaryDirectory())
    defer { controller.stopSession() }
    let original = try #require(controller.terminal)
    let originalPID = original.process.shellPid
    let prompt = "Explain this 😀\n'quoted' \"text\"; $(touch SHOULD_NOT_EXIST); `touch ALSO_NOT_CREATED`\n\u{1b}[31m"
    #expect(controller.startCommand(executable: command.path, arguments: ["--prompt", prompt], title: "Explain · Test", inDirectory: folder.path))
    let explanation = try #require(controller.terminal)
    #expect(explanation !== original)
    #expect(original.process.shellPid == originalPID && original.process.running)
    #expect(controller.sessionCount == 2)
    #expect(credentialsCreated == 2)
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("directory.txt").path) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let arguments = try Data(contentsOf: folder.appendingPathComponent("arguments.bin"))
    #expect(arguments == Data(("--prompt\0" + prompt + "\0").utf8))
    #expect(try String(contentsOf: folder.appendingPathComponent("context.txt"), encoding: .utf8) == "explanation-test-token")
    let directory = try String(contentsOf: folder.appendingPathComponent("directory.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(URL(fileURLWithPath: directory).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("SHOULD_NOT_EXIST").path))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("ALSO_NOT_CREATED").path))
    // The completed command leaves its tab and shell available for follow-ups.
    #expect(explanation.process.running)
    controller.startSession(inDirectory: NSHomeDirectory())
    #expect(controller.sessionCount == 2)
    #expect(!controller.startCommand(executable: "/no-such-agent", arguments: [], title: "Missing", inDirectory: folder.path))
    #expect(!controller.startCommand(executable: command.path, arguments: ["embedded\0NUL"], title: "Invalid", inDirectory: folder.path))
    #expect(controller.sessionCount == 2)
}

@MainActor
@Test func terminalTabsKeepIndependentSessions() async throws {
    _ = NSApplication.shared
    let controller = OakTerminalPanelController()
    controller.startSession(inDirectory: NSTemporaryDirectory())
    defer { controller.stopSession() }
    let first = try #require(controller.terminal)
    let firstPID = first.process.shellPid
    controller.newTerminal()
    let second = try #require(controller.terminal)
    #expect(first !== second)
    #expect(second.process.shellPid != firstPID)
    #expect(controller.sessionCount == 2)
    controller.selectSession(id: 1)
    #expect(controller.terminal === first)
    controller.selectSession(id: 2)
    #expect(controller.terminal === second)
    controller.applyTheme(background: .black, foreground: .green, caret: .white, selection: .blue)
    #expect(first.nativeForegroundColor == .green)
    #expect(second.nativeForegroundColor == .green)

    // Exit in an inactive tab must close only that tab, leaving the active shell untouched.
    first.send(txt: "exit\n")
    for _ in 0..<100 {
        if controller.sessionCount == 1 { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(controller.sessionCount == 1)
    #expect(controller.terminal === second)
    #expect(second.process.running)

    for _ in 0..<100 {
        if !controller.hasRunningWork { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!controller.hasRunningWork)
    controller.closeSessions(withIdentifiers: controller.sessionIdentifiers)
    #expect(controller.sessionCount == 0)
    #expect(controller.terminal == nil)
    controller.newTerminal()
    #expect(controller.sessionCount == 1)
    #expect(controller.terminal?.process.shellPid != second.process.shellPid)
}

@MainActor
@Test func terminalTabShortcutsRequirePaneFocus() throws {
    _ = NSApplication.shared
    let controller = OakTerminalPanelController()
    controller.startSession(inDirectory: NSTemporaryDirectory())
    defer { controller.stopSession() }
    let first = try #require(controller.terminal)
    controller.newTerminal()
    let second = try #require(controller.terminal)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: .titled, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(controller.view)
    controller.view.frame = window.contentView!.bounds
    window.makeFirstResponder(second)

    func arrow(right: Bool, extra: NSEvent.ModifierFlags = []) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: NSEvent.ModifierFlags([.command, .option, .function, .numericPad]).union(extra), timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: right ? "\u{f703}" : "\u{f702}", charactersIgnoringModifiers: right ? "\u{f703}" : "\u{f702}",
            isARepeat: false, keyCode: right ? 124 : 123))
        return controller.view.performKeyEquivalent(with: event)
    }
    #expect(try arrow(right: false))
    #expect(controller.terminal === first)
    #expect(window.firstResponder === first)
    #expect(try arrow(right: false)) // Wrap from the first to the last tab.
    #expect(controller.terminal === second)
    #expect(try arrow(right: true))
    #expect(controller.terminal === first)
    #expect(try !arrow(right: true, extra: .shift))
    #expect(controller.terminal === first)

    let editor = NSTextView(frame: .zero)
    window.contentView?.addSubview(editor)
    window.makeFirstResponder(editor)
    #expect(try !arrow(right: true))
    #expect(controller.terminal === first)
}

@MainActor
@Test func newTerminalUsesCurrentProjectDirectory() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TextMate projects \(UUID().uuidString)")
    let firstFolder = root.appendingPathComponent("first project")
    let secondFolder = root.appendingPathComponent("second 'project'")
    for folder in [firstFolder, secondFolder] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    var projectFolder = firstFolder
    let controller = OakTerminalPanelController()
    controller.workingDirectoryProvider = { projectFolder.path }
    // Simulate a panel initialized before its window acquired the project context.
    controller.startSession(inDirectory: FileManager.default.currentDirectoryPath)
    defer { controller.stopSession() }
    let first = try #require(controller.terminal)
    projectFolder = secondFolder
    controller.newTerminal()
    let second = try #require(controller.terminal)
    first.send(txt: "pwd > project-cwd.txt\n")
    second.send(txt: "pwd > project-cwd.txt\n")
    for folder in [firstFolder, secondFolder] {
        let output = folder.appendingPathComponent("project-cwd.txt")
        for _ in 0..<100 {
            if let text = try? String(contentsOf: output, encoding: .utf8), !text.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let path = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    }
}

@MainActor
@Test func nativeTabOrderAndTransferPreserveShells() throws {
    _ = NSApplication.shared
    let source = OakTerminalPanelController()
    let target = OakTerminalPanelController()
    source.startSession(inDirectory: NSTemporaryDirectory())
    target.startSession(inDirectory: NSTemporaryDirectory())
    defer { source.stopSession(); target.stopSession() }
    let first = try #require(source.terminal)
    let id = try #require(source.sessionIdentifiers.first)
    let pid = first.process.shellPid
    source.newTerminal()
    let second = try #require(source.terminal)
    source.moveSession(from: 0, to: 2)
    #expect(source.sessionIdentifiers.last == id)
    #expect(source.terminal === second)
    source.selectSession(at: 1)
    #expect(source.terminal === first)
    source.transferSession(identifier: id, to: target, at: 0)
    #expect(source.sessionCount == 1)
    #expect(source.terminal === second)
    #expect(target.sessionCount == 2)
    #expect(target.terminal === first)
    #expect(first.process.shellPid == pid)
    #expect(first.processDelegate === target)
    #expect(target.sessionIdentifiers.first == id)
}

@MainActor
@Test func terminalFontFollowsEditorAcrossSessions() throws {
    _ = NSApplication.shared
    let controller = OakTerminalPanelController()
    let destination = OakTerminalPanelController()
    defer { controller.stopSession(); destination.stopSession() }
    let initialFont = try #require(NSFont(name: "Menlo", size: 15))
    let updatedFont = try #require(NSFont(name: "Monaco", size: 18))
    controller.applyFont(initialFont)
    controller.startSession(inDirectory: NSTemporaryDirectory())
    let first = try #require(controller.terminal)
    let pid = first.process.shellPid
    #expect(first.font == initialFont)
    controller.newTerminal()
    let second = try #require(controller.terminal)
    controller.applyFont(updatedFont)
    #expect(first.font == updatedFont)
    #expect(second.font == updatedFont)
    #expect(first.process.shellPid == pid)
    controller.newTerminal()
    #expect(controller.terminal?.font == updatedFont)
    destination.applyFont(initialFont)
    controller.transferSession(identifier: controller.sessionIdentifiers[0], to: destination, at: 0)
    #expect(destination.terminal === first)
    #expect(first.font == initialFont)
    #expect(first.process.shellPid == pid)
}

@MainActor
@Test func terminalControlKeysStayWithFocusedSession() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let controller = OakTerminalPanelController()
    controller.startSession(inDirectory: folder.path)
    defer { controller.stopSession() }
    let terminal = try #require(controller.terminal)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: .titled, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = controller.view
    defer { window.contentView = nil }
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{0b}", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
    window.makeFirstResponder(controller.view)
    #expect(!controller.handleTerminalKeyEvent(event, source: terminal))
    window.makeFirstResponder(terminal)
    terminal.send(txt: "stty -icanon -echo; printf ready > ready; dd bs=1 count=1 of=key 2>/dev/null; stty sane\n")
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path))
    #expect(controller.handleTerminalKeyEvent(event, source: terminal))
    for _ in 0..<100 {
        if let bytes = try? Data(contentsOf: folder.appendingPathComponent("key")), bytes == Data([11]) { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Ctrl+K did not reach the focused terminal process")
}

@MainActor
@Test func contextRegistrationFollowsTerminalLifetimeAndTransfers() throws {
    _ = NSApplication.shared
    let source = OakTerminalPanelController()
    let destination = OakTerminalPanelController()
    var owners: [UUID: String] = [:]
    var closed: [UUID] = []
    source.contextEnvironmentProvider = { owners[$0] = "source"; return [:] }
    destination.contextEnvironmentProvider = { owners[$0] = "destination"; return [:] }
    source.contextSessionClosed = { closed.append($0); owners.removeValue(forKey: $0) }
    destination.contextSessionClosed = { closed.append($0); owners.removeValue(forKey: $0) }
    source.startSession(inDirectory: NSTemporaryDirectory())
    let identifier = try #require(source.sessionIdentifiers.first)
    #expect(owners[identifier] == "source")
    source.transferSession(identifier: identifier, to: destination, at: 0)
    #expect(owners[identifier] == "destination")
    source.stopSession()
    #expect(closed.isEmpty)
    destination.stopSession()
    #expect(closed == [identifier])
    #expect(owners.isEmpty)
}
