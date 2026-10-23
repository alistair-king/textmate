# Embedded terminal

Show the panel using View → Show Terminal Panel or Command–`. Choose its edge under View → Terminal Panel Position. The panel now contains a SwiftTerm terminal. The edge and size last chosen are shared by all windows, and restored windows reopen with their own saved state.

Each window starts one login shell on first use, using the account's configured shell. It starts in the project folder, the file browser's root, the current document's folder, or the home folder when none is available. Opening another document does not change an existing shell's directory.

Hiding or repositioning the panel preserves the running session and scrollback. Showing it focuses the terminal; hiding it returns focus to the editor. Normal terminal controls and copy/paste are provided by SwiftTerm, and ⌘K clears the display and scrollback and redraws the shell prompt while the terminal has focus. Use the + button in the tab bar to start additional shells in the current project directory, click a tab or press ⌘⌥← / ⌘⌥→ while the terminal pane has focus to switch sessions (wrapping at either end), and use its × button to close it. Other tabs keep running while inactive. When a shell exits, its tab closes automatically. Closing the last tab leaves the pane open so you can start another with +.

Terminal tabs use the same OakTabBarView as editor tabs, including sizing, overflow, hover close buttons, and drag reordering. Drag a session to another terminal pane to move it without restarting the shell. Double-click empty tab-bar space to create a session; double-click a tab (when more than one exists), or choose Move Tab to New Window, to detach it. The context menu supports closing a tab, other tabs, or tabs on either side. Option-clicking a close button closes the other tabs.

Closing a window or quitting checks for foreground or background child processes and asks before ending active work. Sessions end when TextMate exits; reopening a saved window starts a new shell, not the previous processes or scrollback.

## Building

SwiftTerm 1.99.1 is pinned in Frameworks/OakSwiftUI/Package.swift and Package.resolved. It requires Swift 6.2 or later. `make debug` and `make release` build the Swift component before the application. The first build downloads Swift package dependencies. TerminalThirdPartyLicenses.txt is included in the application resources.

The terminal bridge is OakTerminalPanelController. TerminalPanelViewController owns the bridge independently of its position/visibility, and DocumentWindowController supplies the initial directory and handles close/quit checks.

Terminal sessions follow the active editor’s font family, size, and zoom level. Font changes update all tabs, including hidden sessions; new and transferred sessions use the destination editor’s font.

## Opening files from terminal output

Hold Command to underline a detected local file, then Command-click to open it in the same TextMate window. Existing editor tabs are reused. References such as `src/main.swift:42:7` jump to the indicated line and column. Absolute paths, `~/` paths, quoted paths with spaces, and explicit `file://` terminal hyperlinks are supported. Ordinary clicks still select terminal text, and web hyperlinks retain their normal behaviour.

Relative paths use the session's shell working directory (queried from macOS, with OSC 7 directory reports as a fallback). Recent output retains its observed directory when the shell changes directories. This is best-effort for old output: resizing/reflow, cleared history, or multiple directory changes within a single output batch can lose that context. Explicit absolute file hyperlinks are unambiguous. Remote files are not downloaded, and plain-path detection is disabled in alternate-screen applications.

## Editor context for terminal agents

The bundled read-only MCP server lets an agent query the current file, selected text, open documents, and unsaved buffer contents in its terminal's window. In a new terminal tab, run `tm-codex` to start Codex with editor context, or `tm-codex --check` to test the connection. Other MCP clients can obtain configuration with `"$TM_MCP_SERVER" --print-config`. See [Editor context MCP](editor-context-mcp.md) for setup and tool details.
