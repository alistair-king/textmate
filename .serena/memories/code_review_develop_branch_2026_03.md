# Code Review: develop branch (2026-03-26)

Full review of ~15,000 lines of diff across develop vs origin/master. Covers all modified original TextMate files.

## CRITICAL (10 items)

1. **OakTextView/OTVStatusBar.mm** — Retain cycle in `flashLspError` timer (strong self capture, no dealloc invalidation)
2. **OakTextView** — Synchronous 3s main-thread spin-wait in format-on-save blocks UI
3. **OakDownloadManager** — Use-after-free: `__bridge` cast doesn't retain SecKeyRef before backing CFArray released
4. **OakDownloadManager** — Method declares NSString* return but returns SecKeyRef bridged to id
5. **oak/compat.h:37** — `oak::vfork()` recurses infinitely (unqualified vfork resolves to itself)
6. **LSPClient.mm:~1075** — `signal(SIGPIPE, SIG_IGN)` per-client-init mutates process-global state
7. **LSPClient.mm:~3058** — Strong self capture in shutdown keeps client alive 3s, stale delegate callbacks
8. **LSPClient.mm:~1675** — `_initialized` set by response order not by matching initialize request ID
9. **LSPClient.mm:~2144** — `convertToJSON:` truncates int64→int32 via intValue
10. **RMateServer.mm** — Refactor broke shared_ptr sharing semantics, `mate -w` terminal tracking silently broken

## REQUIRED (12 items)

1. OakTextView: PHP-specific definition filtering duplicated in Cmd+Click and lspGoToDefinition
2. OakTextView: Inconsistent line splitting (newlineCharacterSet vs @"\n") — wrong CRLF offsets
3. OakTextView: applyWorkspaceEdit file writes silently discard errors
4. OakTextView: _lspTheme initialized 4 times with different values
5. OakTextView: Dead deprecated showLSPHoverTooltipWithContent left with "might need it" comment
6. OakAppKit: Circular dependency OakAppKit→Preferences→OakAppKit for 4 clipboard constants
7. OakDownloadManager: CFErrorRef leaks in signature verification
8. OakDownloadManager: Deprecated Security Transform APIs (deprecated macOS 12)
9. plist/fs_cache.mm: Missing nil guard on .UTF8String crashes when node[@"link"] is nil
10. LSPClient: No dealloc — orphaned NSTask and stuck readability handlers
11. LSPClient: Single-server-per-workspace assumption blocks multi-language projects
12. BundleEditor/Find: Incomplete NSEditor protocol conformance

## STYLE/CODE SMELL (10 items)

1. OakTextView.mm 7495+ lines — LSP/Copilot/formatter/markdown should be extracted
2. OakTextView: Fragile _didApplyCodeActionEdit boolean coordination flag
3. OakTextView: Static mutable lastHandledRequestId unsafe across instances
4. OakAppKit: Three identical "Modern API always available" comments — WHY not WHAT
5. plist::any_t::empty() semantic trap (returns true for default int 0)
6. core/type.cc: Unnecessary O(n) copy per grammar
7. core/tbz_t: Uninitialized _status
8. AppController: goto across switch statement
9. AppController: Substring match on log content driving UI behavior
10. LSPClient: PHP-specific filtering in generic LSP framework

## POSITIVE

- Boost removal and ragel→hand-written parser migration are sound
- plist::any_t wrapper around std::variant is clean
- CMake migration and API modernization well-executed
- LSP protocol implementation broadly correct with wide feature coverage
