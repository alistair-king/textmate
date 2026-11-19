import AppKit
import Testing
@testable import OakSwiftUI

@Test func terminalFileDropQuoting() {
    #expect(TerminalFileDrop.quote("/usr/bin/env") == "/usr/bin/env")
    #expect(TerminalFileDrop.quote("/tmp/a file (1).txt") == "/tmp/a\\ file\\ \\(1\\).txt")
    #expect(TerminalFileDrop.quote("/tmp/it's$HOME&;~*") == "/tmp/it\\'s\\$HOME\\&\\;\\~\\*")
    #expect(TerminalFileDrop.quote("/tmp/日本語 ファイル") == "/tmp/日本語\\ ファイル")
    #expect(TerminalFileDrop.quote("/tmp/a\nb's\\c\u{1B}") == "$'/tmp/a\\x0Ab\\'s\\\\c\\x1B'")
    let urls = [URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two words")]
    #expect(TerminalFileDrop.text(for: urls) == "/tmp/one /tmp/two\\ words ")
    #expect(TerminalFileDrop.text(for: []) == nil)
}

@MainActor
@Test func terminalFileDropReadsOnlyFileURLs() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("TextMate terminal drop \(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects([URL(string: "https://example.com/file")! as NSURL])
    #expect(!TerminalFileDrop.canAccept(pasteboard))
    pasteboard.clearContents()
    pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/dropped file") as NSURL])
    #expect(TerminalFileDrop.canAccept(pasteboard))
    #expect(TerminalFileDrop.text(for: TerminalFileDrop.fileURLs(from: pasteboard)) == "/tmp/dropped\\ file ")
}

@MainActor
@Test func terminalTabRenameOverridesShellTitle() async throws {
    _ = NSApplication.shared
    let controller = makeTerminalController()
    controller.startSession()
    defer { controller.stopSession() }
    let terminal = try #require(controller.terminal)
    controller.setTerminalTitle(source: terminal, title: "shell title")
    #expect(controller.sessionTitles == ["shell title"])
    controller.renameSession(at: 0, title: "  Build\u{07} server  ")
    #expect(controller.sessionTitles == ["Build server"])
    controller.setTerminalTitle(source: terminal, title: "later shell title")
    #expect(controller.sessionTitles == ["Build server"])
    controller.renameSession(at: 0, title: "   ")
    #expect(controller.sessionTitles == ["later shell title"])
    controller.renameSession(at: 5, title: "out of range")
    #expect(controller.sessionTitles == ["later shell title"])
}
