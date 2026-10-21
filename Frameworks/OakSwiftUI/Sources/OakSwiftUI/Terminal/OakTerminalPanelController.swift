import AppKit
import Darwin
import SwiftTerm

// Keep the terminal's grid valid even when the outer panel is temporarily compressed to zero.
@MainActor
private final class TerminalContainer: NSView {
    weak var terminal: NSView?
    override func layout() {
        super.layout()
        terminal?.frame = NSRect(x: 0, y: 0, width: max(32, bounds.width), height: max(32, bounds.height))
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}

@MainActor
@objc public final class OakTerminalPanelController: NSViewController, LocalProcessTerminalViewDelegate {
    private(set) var terminal: LocalProcessTerminalView?
    private var directory = NSHomeDirectory()
    private var started = false
    private let restartButton = NSButton(title: "Restart Shell", target: nil, action: nil)

    public override func loadView() {
        let container = TerminalContainer(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        view = container
        restartButton.target = self
        restartButton.action = #selector(restartShell)
        restartButton.isHidden = true
        restartButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(restartButton)
        NSLayoutConstraint.activate([
            restartButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            restartButton.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(stopSession), name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc public func startSession(inDirectory path: String) {
        guard !started else { return }
        started = true
        var isDirectory: ObjCBool = false
        directory = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : NSHomeDirectory()
        launchShell()
    }

    private func launchShell() {
        _ = view
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: max(32, view.bounds.width), height: max(32, view.bounds.height)))
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.processDelegate = self
        terminal.setAccessibilityLabel("Terminal")
        self.terminal = terminal
        (view as? TerminalContainer)?.terminal = terminal
        view.addSubview(terminal, positioned: .below, relativeTo: restartButton)
        restartButton.isHidden = true
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        let configuredShell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
        let shell = FileManager.default.isExecutableFile(atPath: configuredShell) ? configuredShell : "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "TextMate"
        environment["SHELL"] = shell
        environment["PWD"] = directory
        // Do not propagate the debug app's injected runtime into shell commands.
        for key in Array(environment.keys) where key.hasPrefix("DYLD_") || key == "ASAN_OPTIONS" {
            environment.removeValue(forKey: key)
        }
        terminal.startProcess(executable: shell, args: ["-l"], environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: directory)
    }

    @objc public func focusTerminal() {
        view.window?.makeFirstResponder(terminal ?? restartButton)
    }

    @objc public var hasRunningWork: Bool {
        guard let process = terminal?.process, process.running, process.shellPid > 0 else { return false }
        let foreground = tcgetpgrp(process.childfd)
        if foreground < 0 || foreground != process.shellPid { return true }
        // A nil buffer asks for capacity, which includes spare slots even for an idle shell.
        var children = [pid_t](repeating: 0, count: 256)
        let bytes = children.withUnsafeMutableBytes {
            proc_listchildpids(process.shellPid, $0.baseAddress, Int32($0.count))
        }
        return bytes < 0 || children.contains { $0 > 0 }
    }

    @objc public func confirmClose() -> Bool {
        guard hasRunningWork else { return true }
        let alert = NSAlert()
        alert.messageText = "Close the terminal session?"
        alert.informativeText = "Programs are still running in this window’s terminal. Closing it will end the session."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close Session")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc public func stopSession() {
        guard let terminal else { return }
        terminal.processDelegate = nil
        if let process = terminal.process, process.running, process.shellPid > 0 {
            let foreground = tcgetpgrp(process.childfd)
            if foreground > 0 && foreground != getpgrp() { kill(-foreground, SIGHUP) }
            kill(process.shellPid, SIGHUP)
            terminal.terminate()
        }
        terminal.removeFromSuperview()
        (view as? TerminalContainer)?.terminal = nil
        self.terminal = nil
    }

    @objc private func restartShell() {
        stopSession()
        launchShell()
        focusTerminal()
    }

    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        restartButton.isHidden = false
        restartButton.toolTip = exitCode.map { "Shell exited with status \($0)" } ?? "Shell terminated"
    }
    public func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        restartButton.isHidden = false
        restartButton.toolTip = "Shell could not start: \(error)"
    }
}
