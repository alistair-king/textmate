# Embedded terminal

Show the panel using View → Show Terminal Panel or Control–`. Choose its edge under View → Terminal Panel Position. The panel now contains a SwiftTerm terminal. The edge and size last chosen seed new windows. A restored window reopens with its own saved edge and size, which take precedence over those defaults, and a window created by detaching a tab copies the placement of the window it came from.

Each window starts one login shell on first use, using the account's configured shell. It starts in the project folder, the file browser's root, the current document's folder, or the home folder when none is available. Opening another document does not change an existing shell's directory.

Hiding or repositioning the panel preserves the running session and scrollback. Showing it focuses the terminal; hiding it returns focus to the editor. Normal terminal controls and copy/paste are provided by SwiftTerm, and ⌘K clears the display and scrollback and redraws the shell prompt while the terminal has focus. Use the + button in the tab bar to start additional shells in the current project directory, click a tab or press ⌘⌥← / ⌘⌥→ while the terminal pane has focus to switch sessions (wrapping at either end), and use its × button to close it. Other tabs keep running while inactive. When a shell exits, its tab closes automatically. Closing the last tab leaves the pane open so you can start another with +.

Terminal tabs use the same OakTabBarView as editor tabs, including sizing, overflow, hover close buttons, and drag reordering. Drag a session to another terminal pane to move it without restarting the shell. Double-click empty tab-bar space to create a session; double-click a tab (when more than one exists), or choose Move Tab to New Window, to detach it. A detached session opens in a new window whose editor holds only an untitled placeholder document; that window closes when its last session ends, unless the placeholder has been edited or other files were opened in it. The context menu supports closing a tab, other tabs, or tabs on either side. Option-clicking a close button closes the other tabs.

Closing a window or quitting asks before ending a session that is running a foreground program. Background jobs and helper processes started by the shell or its prompt do not trigger the question. Sessions end when TextMate exits; reopening a saved window starts a new shell, not the previous processes or scrollback.

## Building

SwiftTerm 1.99.1 is pinned in Frameworks/OakSwiftUI/Package.swift and Package.resolved. It requires Swift 6.2 or later. `make debug` (or `make release`) builds the Swift component before compiling the terminal bridge, and embeds and signs `libOakSwiftUI.dylib` in the application’s `Contents/Frameworks` directory. SwiftTerm is linked into that library. The application requires macOS 14 or later, matching the Swift package’s deployment target. The first build downloads Swift package dependencies. SwiftTerm ships a build-tool plugin, and `build.sh` passes `--disable-sandbox`, so that plugin runs unsandboxed at build time; the exact version pin in Package.swift and Package.resolved is what limits that exposure, so review the plugin before bumping it. TerminalThirdPartyLicenses.txt is included in the application resources.

The terminal bridge is OakTerminalPanelController. TerminalPanelViewController owns the bridge independently of its position/visibility, and DocumentWindowController supplies the initial directory and handles close/quit checks.

Terminal sessions follow the active editor’s font family, size, and zoom level. Font changes update all tabs, including hidden sessions; new and transferred sessions use the destination editor’s font.

## Opening files from terminal output

Hold Command to underline a detected local file, then Command-click to open it in the same TextMate window. Existing editor tabs are reused. References such as `src/main.swift:42:7` jump to the indicated line and column. Absolute paths, `~/` paths, quoted paths with spaces, and explicit `file://` terminal hyperlinks are supported. Ordinary clicks still select terminal text, and web hyperlinks retain their normal behaviour.

Relative paths use the session's shell working directory (queried from macOS, with OSC 7 directory reports as a fallback). Recent output retains its observed directory when the shell changes directories. This is best-effort for old output: resizing/reflow, cleared history, or multiple directory changes within a single output batch can lose that context. Explicit absolute file hyperlinks are unambiguous. Remote files are not downloaded, and plain-path detection is disabled in alternate-screen applications.

## Editor context for terminal agents

The bundled read-only MCP server lets an agent query the current file, selected text, open documents, and unsaved buffer contents in its terminal's window. In a new terminal tab, run `tm-codex`, `tm-claude`, or `tm-opencode` to start the corresponding agent with editor context. Each launcher accepts `--check` to test the connection. Other MCP clients can obtain configuration with `"$TM_MCP_SERVER" --print-config`. See [Editor context MCP](editor-context-mcp.md) for setup and tool details.
