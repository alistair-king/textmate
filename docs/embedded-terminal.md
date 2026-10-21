# Embedded terminal

Show the panel using the Terminal title-bar button, View → Show Terminal Panel, or Control–Option–Command–A. Choose its edge under View → Terminal Panel Position. The panel now contains a SwiftTerm terminal. The edge and size last chosen are shared by all windows, and restored windows reopen with their own saved state.

Each window starts one login shell on first use, using the account's configured shell. It starts in the project folder, the current document's folder, or the home folder when neither is available. Opening another document does not change an existing shell's directory.

Hiding or repositioning the panel preserves the running session and scrollback. Showing it focuses the terminal; hiding it returns focus to the editor. Normal terminal controls and copy/paste are provided by SwiftTerm, and ⌘K clears the display and scrollback and redraws the shell prompt while the terminal has focus. When the shell exits, use Restart Shell to start a fresh session in the original directory.

Closing a window or quitting checks for foreground or background child processes and asks before ending active work. Sessions end when TextMate exits; reopening a saved window starts a new shell, not the previous processes or scrollback.

## Building

SwiftTerm 1.99.1 is pinned in Frameworks/OakSwiftUI/Package.swift and Package.resolved. It requires Swift 6.2 or later. `make debug` and `make release` build the Swift component before the application. The first build downloads Swift package dependencies. TerminalThirdPartyLicenses.txt is included in the application resources.

The terminal bridge is OakTerminalPanelController. TerminalPanelViewController owns the bridge independently of its position/visibility, and DocumentWindowController supplies the initial directory and handles close/quit checks.
