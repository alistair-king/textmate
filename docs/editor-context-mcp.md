# Querying TextMate from a terminal agent

TextMate bundles a read-only MCP server, `textmate-mcp`, and launchers for Codex (`tm-codex`), Claude Code (`tm-claude`), and OpenCode (`tm-opencode`). Agents can query live editor buffers, including unsaved changes and untitled documents. Queries stay within the window owning the terminal session, even while the terminal has keyboard focus. Moving a terminal to another window updates its context without restarting the agent.

## Start Codex

Launch the updated TextMate app and open a **new terminal tab**, then run:

```sh
tm-codex
```

The launcher checks the editor connection, finds Codex CLI, and starts it with temporary MCP settings for this terminal. It preserves the current directory and forwards arguments, including prompts, model options, `exec`, and `resume`. For example:

```sh
tm-codex "Tell me which file is open and explain my selection"
```

The bundled command directory is added to new terminals' PATH. If a shell startup file replaces PATH entirely, run the launcher by its full path:

```sh
"${TM_MCP_SERVER%/*}/tm-codex"
```

Install and sign in to [Codex CLI](https://learn.chatgpt.com/docs/cli) first if necessary. The launcher checks PATH, the ChatGPT application's bundled CLI, and common Homebrew locations. Set `TM_CODEX_COMMAND` to the absolute executable path for another installation. Codex must support `--no-daemon`; this ensures a terminal uses its own connection environment rather than a previously started shared server. An older CLI reporting an unknown option needs updating.

The launcher neither writes Codex configuration nor places session credentials in command arguments. It passes the names of the environment variables Codex must forward, as described in [Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp). User-supplied Codex configuration options still work and can override the launcher's settings.

## Start Claude Code

Install and sign in to [Claude Code](https://code.claude.com/docs/en/setup), then open a new terminal in the updated TextMate app and run:

```sh
tm-claude
# Or start with a prompt:
tm-claude "Explain the selected text in TextMate"
```

The launcher checks the editor connection and supplies a temporary `textmate` server using Claude's [`--mcp-config` option](https://code.claude.com/docs/en/cli-reference). Claude's [environment variable expansion](https://code.claude.com/docs/en/mcp#environment-variable-expansion-in-mcpjson) forwards the terminal credentials by reference, so their values do not appear in arguments or configuration files.

Claude's existing MCP servers and permission settings stay enabled. Session arguments, such as `--model`, `--continue`, `--resume`, and print mode, are forwarded. Administrative subcommands should be run directly with `claude`.

The launcher searches PATH, `~/.local/bin/claude`, the older `~/.claude/local/claude` location, and common Homebrew locations. Set `TM_CLAUDE_COMMAND` to an explicit executable path for another installation. To launch by full path when shell startup files replace PATH:

```sh
"${TM_MCP_SERVER%/*}/tm-claude"
```

## Start OpenCode

Install and configure [OpenCode](https://opencode.ai/docs/), then open a new TextMate terminal and run:

```sh
tm-opencode
# Or run a prompt without the terminal UI:
tm-opencode run "Explain the selected text in TextMate"
```

The launcher adds a local `textmate` MCP server through OpenCode's [`OPENCODE_CONFIG_CONTENT` runtime configuration](https://opencode.ai/docs/config/#precedence-order). Existing inline JSON/JSONC settings, other MCP servers, provider settings, permissions, and arguments are preserved. Only the inline `mcp.textmate` entry is replaced for the current terminal. Malformed inline configuration produces an error without echoing or replacing its contents.

The server's `environment` fields use OpenCode's [`{env:VARIABLE}` references](https://opencode.ai/docs/config/#env-vars), so connection credentials remain in environment variables rather than arguments or configuration files. Global and project settings continue to load normally, and administrator-managed settings retain OpenCode's usual precedence.

The launcher searches PATH, `~/.opencode/bin/opencode`, `~/.local/bin/opencode`, and common Homebrew locations. Set `TM_OPENCODE_COMMAND` to another absolute executable path if needed. To launch by full path when shell startup files replace PATH:

```sh
"${TM_MCP_SERVER%/*}/tm-opencode"
```

Use `tm-opencode --check` to test the editor connection without starting OpenCode. Commands that attach to an already running remote OpenCode server use that server's configuration; start a local OpenCode session for this terminal's editor context.

## Check the connection

```sh
tm-codex --check
tm-claude --check
tm-opencode --check
# or:
"$TM_MCP_SERVER" --check
```

A successful check identifies the connected window and current document without reading document content. Errors distinguish missing environment variables, an unavailable service, permission denial, a closed or unauthorized session, an invalid response, and a timeout.

Open a new terminal if its variables are missing. Restarting TextMate ends existing sessions; old credentials cannot reconnect. After rebuilding, restart the app to load the updated service. A new terminal tab alone does not update an already running application binary.

## Other MCP clients

Inside a TextMate terminal, run:

```sh
"$TM_MCP_SERVER" --print-config
```

This prints an `mcpServers` JSON entry with the helper's absolute path and explicit `TM_CONTEXT_SOCKET`, `TM_CONTEXT_SESSION`, and `TM_CONTEXT_TOKEN` values. Register that entry using the client's configuration mechanism. These connection values belong to this terminal; generate separate configuration for separate tabs. Do not commit generated credentials to a project.

Clients supporting environment forwarding can pass those three variables from the launching shell instead. Explicit forwarding matters because MCP clients may inherit only a restricted environment. `TM_MCP_SERVER` holds the helper's absolute path.

The helper runs without arguments as an MCP stdio server. Standard output contains protocol messages only. No Python, Node, TCP listener, or external service is needed by the TextMate integration at runtime. The chosen agent CLI is installed separately.

## Tools

- `get_editor_context`: current document metadata, cursor, selections and selected text, plus roughly 2,048 UTF-16 code units around the cursor. Selected text has an 8,192-unit combined budget; at most 128 ranges are returned. Column selections expand into rows with the limit applied during expansion. Truncation is explicit.
- `list_open_documents`: up to 256 document IDs and metadata in the associated window. Includes path (null for untitled documents), name, language, modified state, loaded state, and an opaque content revision.
- `read_document`: reads a loaded document by `documentId`, with optional `offset` (default 0) and `length` (default 16,384; maximum 32,768). Returns text, total length, next offset, revision, and truncation status. It does not open arbitrary paths or load inactive buffers.

Offsets and lengths count **UTF-16 code units**, starting at zero. Line and column numbers start at one; lines split on LF. Ranges are half-open. Text boundaries preserve surrogate pairs, and reads reject offsets inside a pair. Continue with the returned `nextOffset` and compare document ID and revision between requests, since the user can edit between calls. A requested length of one at a supplementary character may return no text; request at least two units to advance.

No-document context returns a null document. Closed windows, revoked sessions, foreign document IDs, malformed arguments, and unavailable services produce errors rather than falling back to another window or disk content.

## Implementation

`EditorContextService` owns one private Unix socket per application instance, in a mode-0700 temporary directory; the socket has mode 0600. Each terminal receives a separate random capability token. Every request validates credentials and resolves the terminal's current owning window. Terminal closure revokes its registration. Normal application termination removes the socket; an abrupt process kill may leave an inaccessible directory in the system temporary area.

The main thread captures metadata, bounded raw selection ranges, and an immutable snapshot sharing the buffer's existing storage. Background workers build a sparse UTF-16/line index and extract only requested text. The index is reused for an unchanged buffer, and edits invalidate the cached snapshot. In-flight snapshots remain consistent even when the user edits or closes the document.

Local requests have a three-second overall deadline, covering connection, I/O, main-thread scheduling, and rendering. Reads and writes use deadline-aware polling; a peer sending a slow trickle of bytes cannot extend the deadline. The service admits at most eight concurrent connections, and messages are limited to 1 MiB.

The native helper implements MCP's stdio tools capability for protocol revisions 2024-11-05, 2025-03-26, 2025-06-18, and 2025-11-25. It validates initialization, waits for `notifications/initialized`, rejects invalid tool arguments and duplicate in-flight IDs, and remains able to process pings and cancellation while tool calls run. Cancellation suppresses the result; an outstanding editor request is allowed to finish within its deadline. Editor text is untrusted content for the agent to interpret.

## Verification

Build with `make debug` or `make release`. The MCP helper and all three launchers are embedded and signed inside the application bundle. Run the native and executable regression tests with:

```sh
ctest --test-dir build-debug -R '^(EditorContext|DocumentWindow|selection|textmate-mcp)$' --output-on-failure
```

The tests cover live and immutable buffers, Unicode and pagination, multiple and rectangular selections, large documents, concurrent contexts in real windows, moving a live terminal, closure and revocation, launcher argument and path handling, initialization, cancellation, diagnostics, and slow-peer deadlines. If Codex is installed, an additional executable test checks the generated configuration with the actual CLI without invoking a model.

An optional interoperability test uses the official MCP TypeScript SDK installed separately for development:

```sh
npm install --prefix /tmp/textmate-mcp-sdk --ignore-scripts @modelcontextprotocol/sdk
node Applications/textmate-mcp/tests/test_sdk.mjs \
  /tmp/textmate-mcp-sdk/node_modules/@modelcontextprotocol/sdk/dist/esm \
  build-debug/Applications/textmate-mcp/textmate-mcp
```

Alternatively, set CMake's `TEXTMATE_MCP_SDK_DIR` to that SDK `dist/esm` directory to add the `textmate-mcp-sdk` CTest target. Tests need permission to create local Unix sockets, and AppKit tests require access to a graphical login session.

For an optional real-Claude startup check, supply an installed Claude executable:

```sh
python3 Applications/textmate-mcp/tests/test_claude_cli.py \
  build-debug/Applications/textmate-mcp/textmate-mcp /absolute/path/to/claude
```

This check uses isolated temporary settings and a local API stub that rejects inference. It verifies the actual launcher's inline configuration, environment expansion, and MCP startup without logging in or sending a request to a real model.

An optional real-OpenCode check verifies the launcher, configuration references, and MCP discovery using isolated temporary settings, with no login or model inference:

```sh
python3 Applications/textmate-mcp/tests/test_opencode_cli.py \
  build-debug/Applications/textmate-mcp/textmate-mcp /absolute/path/to/opencode
```
