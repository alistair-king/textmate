import AppKit
import Darwin
import SwiftTerm

// Keep the terminal's grid valid even when the outer panel is temporarily compressed to zero.
@MainActor
private final class TerminalContainer: NSView {
    weak var terminal: NSView?
    var tabBar: NSView?
    override var acceptsFirstResponder: Bool { true }
    let emptyLabel = NSTextField(labelWithString: "No terminal sessions. Click + to open one.")
    weak var controller: OakTerminalPanelController?
    override func layout() {
        super.layout()
        let barHeight: CGFloat = min(23, bounds.height)
        tabBar?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        emptyLabel.frame = NSRect(x: 8, y: barHeight + max(0, (bounds.height - barHeight) / 2 - 10), width: max(0, bounds.width - 16), height: 20)
        let padding: CGFloat = 6
        terminal?.frame = NSRect(x: padding, y: barHeight + padding, width: max(32, bounds.width - 2 * padding), height: max(32, bounds.height - barHeight - 2 * padding))
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Leave the editor's tab shortcuts alone unless this pane owns the focus.
        guard event.type == .keyDown,
              let window,
              let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: self),
              let controller else {
            return super.performKeyEquivalent(with: event)
        }
        // Arrow events also carry function/numeric-pad flags; those are not modifiers.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == [.command, .option] && (event.keyCode == 123 || event.keyCode == 124) {
            controller.selectAdjacentSession(forward: event.keyCode == 124)
            return true
        }
        if modifiers == [.command] && event.charactersIgnoringModifiers == "k" && controller.terminal != nil {
            controller.clearTerminal()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
@objc public final class OakTerminalPanelController: NSViewController, LocalProcessTerminalViewDelegate {
    private struct Session {
        let id: Int
        let uuid: UUID
        let terminal: LocalProcessTerminalView
        var title: String
    }
    private var sessions: [Session] = []
    private var selectedID: Int?
    private var nextID = 1
    var terminal: LocalProcessTerminalView? { sessions.first { $0.id == selectedID }?.terminal }
    var sessionCount: Int { sessions.count }
    @objc public var sessionIdentifiers: [UUID] { sessions.map(\.uuid) }
    @objc public var sessionTitles: [String] { sessions.map(\.title) }
    @objc public var selectedSessionIndex: Int { sessions.firstIndex { $0.id == selectedID } ?? NSNotFound }
    @objc public var tabsDidChange: (() -> Void)?

    @objc public func installTabBar(_ tabBar: NSView) {
        guard let container = view as? TerminalContainer else { return }
        container.tabBar?.removeFromSuperview()
        container.tabBar = tabBar
        container.addSubview(tabBar)
        container.needsLayout = true
        rebuildTabs()
    }

    @objc public func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectSession(id: sessions[index].id)
        focusTerminal()
    }

    @objc public func moveSession(from source: Int, to destination: Int) {
        guard sessions.indices.contains(source), (0...sessions.count).contains(destination) else { return }
        let session = sessions.remove(at: source)
        sessions.insert(session, at: destination > source ? destination - 1 : destination)
        rebuildTabs()
    }

    @objc public func transferSession(identifier: UUID, to destination: OakTerminalPanelController, at insertionIndex: Int) {
        guard destination !== self,
              let index = sessions.firstIndex(where: { $0.uuid == identifier }) else { return }
        let session = sessions.remove(at: index)
        session.terminal.removeFromSuperview()
        if selectedID == session.id {
            selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
        showSelectedSession()
        let newID = destination.nextID
        destination.nextID += 1
        destination.started = true
        session.terminal.processDelegate = destination
        (session.terminal as? FileLinkTerminalView)?.owner = destination
        destination.sessions.insert(Session(id: newID, uuid: session.uuid, terminal: session.terminal, title: session.title), at: min(max(0, insertionIndex), destination.sessions.count))
        destination.applyFont(destination.terminalFont)
        destination.updateTerminalColors()
        destination.selectSession(id: newID)
        destination.focusTerminal()
    }

    @objc public func closeSessions(withIdentifiers identifiers: [UUID]) {
        let closing = sessions.filter { identifiers.contains($0.uuid) }
        guard confirmClose(terminals: closing.map(\.terminal)) else { return }
        for session in closing { removeSession(id: session.id) }
    }
    @objc public var openFile: ((URL, Int, Int) -> Void)?
    @objc public var workingDirectoryProvider: (() -> String)?
    private var directory = NSHomeDirectory()
    private var terminalFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    @objc public func applyFont(_ font: NSFont) {
        terminalFont = font
        for session in sessions where session.terminal.font != font {
            session.terminal.font = font
        }
    }

    private var started = false
    private var themeColors: (background: NSColor, foreground: NSColor, caret: NSColor, selection: NSColor)?

    @objc public func applyTheme(background: NSColor, foreground: NSColor, caret: NSColor, selection: NSColor) {
        themeColors = (background, foreground, caret, selection)
        updateTerminalColors()
    }

    private func updateTerminalColors() {
        guard let colors = themeColors else { return }
        if isViewLoaded {
            view.layer?.backgroundColor = colors.background.cgColor
            (view as? TerminalContainer)?.emptyLabel.textColor = colors.foreground
        }
        for session in sessions {
            let terminal = session.terminal
            terminal.nativeBackgroundColor = colors.background
            terminal.nativeForegroundColor = colors.foreground
            terminal.caretColor = colors.caret
            terminal.caretTextColor = colors.background
            terminal.selectedTextBackgroundColor = colors.selection
            terminal.selectedTextForegroundColor = colors.foreground
            terminal.needsDisplay = true
        }
    }

    public override func loadView() {
        let container = TerminalContainer(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.controller = self
        view = container
        container.emptyLabel.alignment = .center
        container.emptyLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(container.emptyLabel)
        NotificationCenter.default.addObserver(self, selector: #selector(stopSession), name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc public func startSession(inDirectory path: String) {
        guard !started else { return }
        started = true
        var isDirectory: ObjCBool = false
        directory = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : NSHomeDirectory()
        launchShell()
    }

    @objc public func newTerminal() {
        launchShell()
        focusTerminal()
    }

    private func launchShell() {
        _ = view
        let requestedDirectory = workingDirectoryProvider?() ?? directory
        var isDirectory: ObjCBool = false
        let launchDirectory = FileManager.default.fileExists(atPath: requestedDirectory, isDirectory: &isDirectory) && isDirectory.boolValue ? requestedDirectory : NSHomeDirectory()
        let terminal = FileLinkTerminalView(frame: NSRect(x: 0, y: 0, width: max(32, view.bounds.width), height: max(32, view.bounds.height)))
        terminal.owner = self
        terminal.launchDirectory = launchDirectory
        terminal.setProcessOutputHandler { [weak terminal] in
            DispatchQueue.main.async { terminal?.scheduleOutputCapture() }
        }
        terminal.font = terminalFont
        terminal.processDelegate = self
        terminal.setAccessibilityLabel("Terminal")
        let id = nextID
        nextID += 1
        sessions.append(Session(id: id, uuid: UUID(), terminal: terminal, title: "Terminal \(id)"))
        updateTerminalColors()
        selectSession(id: id)

        let configuredShell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
        let shell = FileManager.default.isExecutableFile(atPath: configuredShell) ? configuredShell : "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "TextMate"
        environment["SHELL"] = shell
        environment["PWD"] = launchDirectory
        // Do not propagate the debug app's injected runtime into shell commands.
        for key in Array(environment.keys) where key.hasPrefix("DYLD_") || key == "ASAN_OPTIONS" {
            environment.removeValue(forKey: key)
        }
        terminal.startProcess(executable: shell, args: ["-l"], environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: launchDirectory)
    }

    // Run before AppKit's key-equivalent search: the editor and global bundle menu
    // can otherwise claim a terminal shortcut before the focused view sees it.
    func handleTerminalKeyEvent(_ event: NSEvent, source: LocalProcessTerminalView) -> Bool {
        guard event.type == .keyDown, let window = source.window,
              event.window === window, window.firstResponder === source,
              terminal === source else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.contains(.control) && !modifiers.contains(.command) {
            source.keyDown(with: event)
            return true
        }
        if modifiers == [.command] && event.charactersIgnoringModifiers == "k" {
            clearTerminal()
            return true
        }
        if modifiers == [.command, .option] && (event.keyCode == 123 || event.keyCode == 124) {
            selectAdjacentSession(forward: event.keyCode == 124)
            return true
        }
        return false
    }

    @objc public func focusTerminal() {
        view.window?.makeFirstResponder(terminal ?? view)
    }

    /// Clears the display and scrollback, then has the shell redraw its prompt.
    @objc public func clearTerminal() {
        guard let terminal else { return }
        (terminal as? FileLinkTerminalView)?.clearFileLinkHistory()
        terminal.feed(text: "\u{1b}[2J\u{1b}[3J")
        // Only the shell can reprint its prompt; Ctrl+L asks it to redraw at the top.
        terminal.send(txt: "\u{0c}")
    }

    @objc public var hasRunningWork: Bool { sessions.contains { hasRunningWork(in: $0.terminal) } }

    private func hasRunningWork(in terminal: LocalProcessTerminalView) -> Bool {
        guard let process = terminal.process, process.running, process.shellPid > 0 else { return false }
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
        confirmClose(terminals: sessions.map(\.terminal))
    }

    private func confirmClose(terminals: [LocalProcessTerminalView]) -> Bool {
        guard terminals.contains(where: { hasRunningWork(in: $0) }) else { return true }
        let alert = NSAlert()
        alert.messageText = "Close terminal sessions?"
        alert.informativeText = "Programs are still running in the terminal sessions being closed. Closing them will end those sessions."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc public func stopSession() {
        for session in sessions { stop(terminal: session.terminal) }
        sessions.removeAll()
        selectedID = nil
        if isViewLoaded { showSelectedSession() }
    }

    private func stop(terminal: LocalProcessTerminalView) {
        terminal.processDelegate = nil
        if let process = terminal.process, process.running, process.shellPid > 0 {
            let foreground = tcgetpgrp(process.childfd)
            if foreground > 0 && foreground != getpgrp() { kill(-foreground, SIGHUP) }
            kill(process.shellPid, SIGHUP)
            terminal.terminate()
        }
        terminal.removeFromSuperview()
    }

    func selectAdjacentSession(forward: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == selectedID }), !sessions.isEmpty else { return }
        let next = (index + (forward ? 1 : sessions.count - 1)) % sessions.count
        selectSession(id: sessions[next].id)
        focusTerminal()
    }

    func selectSession(id: Int) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
        showSelectedSession()
    }

    private func showSelectedSession() {
        guard let container = view as? TerminalContainer else { return }
        let hadFocus = (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
        container.terminal?.removeFromSuperview()
        container.terminal = terminal
        if let terminal { container.addSubview(terminal, positioned: .below, relativeTo: container.tabBar) }
        container.emptyLabel.isHidden = terminal != nil
        rebuildTabs()
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        if hadFocus { focusTerminal() }
    }

    private func rebuildTabs() { tabsDidChange?() }

    private func removeSession(id: Int) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedID == id
        let hadFocus = (view.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
        stop(terminal: sessions[index].terminal)
        sessions.remove(at: index)
        if wasSelected { selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id }
        showSelectedSession()
        if wasSelected && hadFocus { focusTerminal() }
    }

    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let index = sessions.firstIndex(where: { $0.terminal === source }) else { return }
        let title = title.components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[index].title = title.isEmpty ? "Terminal \(sessions[index].id)" : String(title.prefix(120))
        rebuildTabs()
    }
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let terminal = source as? FileLinkTerminalView, let directory else { return }
        if let url = URL(string: directory), url.isFileURL,
           url.host == nil || url.host == "" || url.host == "localhost" || url.host == ProcessInfo.processInfo.hostName {
            terminal.reportedDirectory = url.path
        } else if directory.hasPrefix("/") {
            terminal.reportedDirectory = directory
        }
    }
    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let session = sessions.first(where: { $0.terminal === source }) else { return }
        removeSession(id: session.id)
    }
    public func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        // Keep the failed tab so SwiftTerm's launch error remains visible; it can be closed with ×.
        guard let index = sessions.firstIndex(where: { $0.terminal === source }) else { return }
        sessions[index].title = "Shell failed to start"
        rebuildTabs()
    }
}
