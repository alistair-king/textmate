# A2A reviews between TextMate terminal tabs

TextMate routes fixed diff reviews between agents. Automatic reviews run in
independent background workers. Manual reviews run in the receiving terminal
conversation with its existing tool permissions. Use embedded terminal tabs
running agent launchers such as `tm-codex` or `tm-claude`.

## Automatic reviews

Start an agent normally with `tm-codex`, `tm-claude`, `tm-copilot`,
`tm-opencode`, or `tm-pi`. Its MCP connection registers automatically for
that launch directory. No Agent Card URLs need to be copied. Sessions
launched in related Git worktrees discover each other using their common
Git directory. Unrelated projects have separate reviewer lists. Moving a
terminal to another window preserves its registration. Launch a new agent
from the new project directory when switching projects.

The MCP server supplies standing instructions to request independent review
before reporting a coding task complete, address actionable findings, and
re-review relevant fixes. The agent sends
a fixed diff, source worktree, and base revision to `a2a_send_review`, omitting
`cardUrl`. Supply a stable `messageId` for retries of the exact same diff.
The tool selects a reviewer automatically and waits for findings. It prefers
a different live session in the same repository. With only one session,
that session's independent background reviewer handles the request.
`a2a_list_reviewers` shows the connected reviewers and their launch directories.

Automatic pickup uses a fresh background **Codex CLI** conversation for each
review, even when the requesting terminal runs another agent. It uses the
existing Codex installation and sign-in, a read-only sandbox, and a ten-minute
execution limit. It receives the fixed review request and reads source from
the sender's registered worktree. Editor credentials are removed from its
environment. It publishes findings through the owning MCP helper without
interrupting the terminal conversation. These reviews consume the configured
Codex model's usage. Install/sign in to Codex first, or set `TM_CODEX_COMMAND`
to its executable before launching the terminal agent. The bundled ChatGPT
CLI is also detected. Other providers can submit requests without a Codex
installation if another registered session has a working Codex reviewer.

Agent hosts decide how to apply MCP instructions and existing tool permissions.
Automatic review requests depend on the agent following those instructions.
Failed or unavailable reviews are returned explicitly and must be reported as
such. A sender can cancel a queued or running review with `a2a_cancel_task`;
the worker stops the process after observing cancellation. Closing the MCP
connection stops its worker. Old registrations retire when their processes or
terminals close; reconnecting registers again with fresh addresses.

Set `TM_A2A_AUTOMATIC=0` when launching an agent to disable automatic
registration, background pickup, and the standing review instructions for that
session. For example, `TM_A2A_AUTOMATIC=0 tm-codex` retains the manual workflow
below. Explicit card URLs continue to use asynchronous submission.

## Try the round-trip

1. Launch the updated TextMate build. Open two embedded terminal tabs and
   start an agent in each with `TM_A2A_AUTOMATIC=0` for this manual walkthrough.
2. In the reviewer tab, ask **“Use `a2a_opt_in` and show me the Agent Card URL
   and window ID.”**
3. In the sender tab, paste the Agent Card URL and ask **“Use
   `a2a_send_review` with this card URL. Send the supplied diff and include
   its source worktree and base revision. Show me the task ID and status.”**
   Supply a fixed diff. Review text can be up to 64 KiB in UTF-8 bytes.
   Split larger diffs into separate reviews. The returned task starts in
   `TASK_STATE_SUBMITTED`.
4. To check window routing, move the reviewer tab to a new window before
   claiming. In that same conversation, ask **“Use `a2a_claim` and show me
   the task ID and window ID. Check the current editor context, review the
   supplied diff, and use `a2a_reply` to return findings with file and line
   references.”** After a move, the task ID should match and the window ID
   and editor context should identify the destination.
5. In the sender tab, ask **“Use `a2a_get_task` with the original card URL and
   task ID and show me the findings.”** Expect `TASK_STATE_COMPLETED` with
   a findings artifact.

Pickup in this manual mode is explicit. `a2a_claim` returns the in-progress task before claiming
the next queued task. A reviewer can close a claimed review with
`a2a_reply` using `outcome: "rejected"` or `outcome: "failed"` and put the
reason in `findings`. The sender can use `a2a_cancel_task` with the card URL
and task ID to cancel a queued or in-progress review. A sender can supply a
stable `messageId` to retry a submission. File and line references are
relative to the diff and worktree supplied by the sender.

## Local A2A clients

TextMate owns the in-memory task state and terminal routing. Its bundled
MCP helper uses the existing authenticated editor-context socket. In-app
senders use the card URL as an opaque local address. TextMate authorizes
task retrieval against the submitting terminal's registration.

The first reviewer opt-in starts an IPv4 loopback HTTP listener on an
ephemeral port. Fetch the Agent Card from the full per-reviewer URL returned
by opt-in, with path `/agents/<reviewer-id>/.well-known/agent-card.json`. It
advertises the interface URL for asynchronous, single-turn text reviews
using the [A2A 1.0 HTTP+JSON binding](https://a2a-protocol.org/v1.0.0/specification/#11-httpjsonrest-protocol-binding).

Use the exact `127.0.0.1:<port>` from the card URL as the HTTP Host. Each HTTP
request has a three-second deadline. Send `A2A-Version: 1.0` and an
`Authorization: Bearer <token>` header on task requests. The token lives in
the mode-0600 file named by the opt-in response's `credentialFile` field.
All holders of a route's bearer share one HTTP sender identity. They can
list, retrieve, or cancel that identity's HTTP tasks. In-app tasks are
scoped to the submitting terminal.

Use `POST <interface-url>/message:send` with
`configuration.returnImmediately: true` for submission. Blocking sends are
unsupported. Poll `GET <interface-url>/tasks/<task-id>`, list with
`GET <interface-url>/tasks`, or cancel with
`POST <interface-url>/tasks/<task-id>:cancel`.

Closing the reviewer terminal or exiting its MCP process retires the route
and marks outstanding tasks as failed. After that process exits, a new MCP
process in the same tab can opt in and receive a new route. Recent task
results stay in memory and remain available through the original route,
with a limit of 32 tasks per route and 64 routes. Older finished tasks and
retired routes are evicted as their limits fill. The listener and task
state are released on TextMate shutdown.
