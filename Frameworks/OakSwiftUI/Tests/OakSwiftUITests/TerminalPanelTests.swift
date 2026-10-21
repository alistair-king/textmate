import Testing
import AppKit
import SwiftTerm
import Darwin
@testable import OakSwiftUI

@MainActor
@Test func terminalSessionLifecycleAndResize() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TextMate terminal test \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let controller = OakTerminalPanelController()
    controller.startSession(inDirectory: folder.path)
    defer { controller.stopSession() }
    let terminal = try #require(controller.terminal)
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
    let restart = try #require(controller.view.subviews.compactMap { $0 as? NSButton }.first)
    for _ in 0..<100 {
        if !restart.isHidden { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!restart.isHidden)
    #expect(!controller.hasRunningWork)
    restart.performClick(nil)
    let restartedTerminal = try #require(controller.terminal)
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
