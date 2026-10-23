# Embedded terminal

Show the panel using View → Show Terminal Panel or Control–`. Choose its edge under View → Terminal Panel Position. The panel now contains a SwiftTerm terminal. The edge and size last chosen are shared by all windows, and restored windows reopen with their own saved state.

Each window starts one login shell on first use, using the account's configured shell. It starts in the project folder, the file browser's root, the current document's folder, or the home folder when none is available. Opening another document does not change an existing shell's directory.

Hiding or repositioning the panel preserves the running session and scrollback. Showing it focuses the terminal; hiding it returns focus to the editor. Normal terminal controls and copy/paste are provided by SwiftTerm, and ⌘K clears the display and scrollback and redraws the shell prompt while the terminal has focus. Use the + button in the tab bar to start additional shells in the current project directory, click a tab or press ⌘⌥← / ⌘⌥→ while the terminal pane has focus to switch sessions (wrapping at either end), and use its × button to close it. Other tabs keep running while inactive. When a shell exits, its tab closes automatically. Closing the last tab leaves the pane open so you can start another with +.

Terminal tabs use the same OakTabBarView as editor tabs, including sizing, overflow, hover close buttons, and drag reordering. Drag a session to another terminal pane to move it without restarting the shell. Double-click empty tab-bar space to create a session; double-click a tab (when more than one exists), or choose Move Tab to New Window, to detach it. The context menu supports closing a tab, other tabs, or tabs on either side. Option-clicking a close button closes the other tabs.

Closing a window or quitting checks for foreground or background child processes and asks before ending active work. Sessions end when TextMate exits; reopening a saved window starts a new shell, not the previous processes or scrollback.

## Building

SwiftTerm 1.99.1 is pinned in Frameworks/OakSwiftUI/Package.swift and Package.resolved. It requires Swift 6.2 or later. `make debug` (or `make release`) builds the Swift component before compiling the terminal bridge, and embeds and signs `libOakSwiftUI.dylib` in the application’s `Contents/Frameworks` directory. SwiftTerm is linked into that library. The application requires macOS 14 or later, matching the Swift package’s deployment target. The first build downloads Swift package dependencies. TerminalThirdPartyLicenses.txt is included in the application resources.

The terminal bridge is OakTerminalPanelController. TerminalPanelViewController owns the bridge independently of its position/visibility, and DocumentWindowController supplies the initial directory and handles close/quit checks.

Terminal sessions follow the active editor’s font family, size, and zoom level. Font changes update all tabs, including hidden sessions; new and transferred sessions use the destination editor’s font.

## Opening files from terminal output

Hold Command to underline a detected local file, then Command-click to open it in the same TextMate window. Existing editor tabs are reused. References such as `src/main.swift:42:7` jump to the indicated line and column. Absolute paths, `~/` paths, quoted paths with spaces, and explicit `file://` terminal hyperlinks are supported. Ordinary clicks still select terminal text, and web hyperlinks retain their normal behaviour.

Relative paths use the session's shell working directory (queried from macOS, with OSC 7 directory reports as a fallback). Recent output retains its observed directory when the shell changes directories. This is best-effort for old output: resizing/reflow, cleared history, or multiple directory changes within a single output batch can lose that context. Explicit absolute file hyperlinks are unambiguous. Remote files are not downloaded, and plain-path detection is disabled in alternate-screen applications.

## Editor context for terminal agents

The bundled MCP server lets an agent query the current file, selected text, open documents, and unsaved buffer contents in its terminal's window. In a new terminal tab, run `tm-codex`, `tm-claude`, or `tm-opencode` to start the corresponding agent with editor context. Each launcher accepts `--check` to test the connection. Other MCP clients can obtain configuration with `"$TM_MCP_SERVER" --print-config`. See [Editor context MCP](editor-context-mcp.md) for setup and tool details.

## Explain Selection

Select text in the editor, then choose **Edit → Explain Selection…** or press **⌃⌥⌘E**. Choose Codex, Claude Code, or OpenCode and click **Explain**. TextMate remembers the last agent you chose. The agent must already be installed and signed in, just as when using its `tm-` launcher manually.

The action opens a separate terminal tab in the document's project folder (or the usual terminal starting directory) with an initial request to explain the selection. Existing terminal sessions keep running. The request contains a snapshot of the selected text, its file information, and line positions, including unsaved or untitled content. Later edits or selection changes do not change that request. Disjoint and rectangular selections are supported, up to 128 ranges and 8,192 UTF-16 code units in total; larger selections produce a message asking you to select less text.

The agent is asked to explain without editing files or executing the excerpt. Its normal permissions still apply, and its TextMate MCP connection can read additional context. The selected text is passed as a process argument, never typed into an existing shell. When the agent exits, the tab stays open with a login shell so its output or startup errors remain visible. The action is disabled when no text is selected or the terminal component is unavailable.

## Diagnostics for terminal agents

With an agent running through `tm-codex`, `tm-claude`, or `tm-opencode`, ask it to **“Read TextMate's diagnostics and explain the errors and warnings in this file.”** The `get_diagnostics` tool reads the language-server reports behind the editor's inline diagnostics, including messages, severity, source, codes, and source ranges. Ask for file locations in the response, then Command-click a location to jump to that line.

The tool reports whether diagnostics have been received and whether a server is available, and supports other loaded documents in the same window. Reports are cached and can lag unsaved edits. Terminal build logs are not collected by this tool. See [Using diagnostics](editor-context-mcp.md#using-diagnostics) for paging and status details.

## Navigate from the conversation

Ask an agent **“Show me that function in TextMate”**, **“Open this file at line 42”**, or **“Select the code for that diagnostic.”** Its `navigate_editor` tool opens or reuses an editor tab in the terminal's window, moves to a line, or selects a passage. It works with unsaved and untitled documents already in that window, as well as existing local files supplied by absolute path.

Keyboard focus stays in the terminal so you can keep chatting. Ask the agent to focus the editor if you want to start editing. Navigation preserves document contents and existing tabs. The agent can use current document revisions to avoid stale locations, and coordinates handle Unicode correctly. See [Navigate from the conversation](editor-context-mcp.md#navigate-from-the-conversation) for the tool arguments and file-loading behavior.

## Follow editor changes

Agents can follow file switches, selections, unsaved edits, open tabs, metadata, and diagnostics. Clients supporting MCP resource subscriptions can subscribe to `textmate://editor/context` and receive coalesced change notifications. The client decides whether to refresh context or wake the model when a notification arrives.

For clients that use tools, ask **“Follow my current file and selection, using get_editor_changes to refresh when they change.”** This tool returns a cursor with the current context. Subsequent calls with that cursor omit unchanged text and return a fresh snapshot when something changes. Following stays within the terminal's owning window, including after moving the terminal to another window.

Subscriptions are optional, and there are no background editor queries without a subscriber. The feature does not automatically start model turns or recurring calls in tool-only clients. See [Follow editor changes](editor-context-mcp.md#follow-editor-changes) for the subscription protocol and cursor behavior.
