"""Exercise the shipped stdio executable and its private socket boundary."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import contextlib
import time
import shutil
import tomllib

EXECUTABLE = str(Path(sys.argv.pop(1)).resolve())


def request(identifier, method, **params):
    return {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}


READY = {"jsonrpc": "2.0", "method": "notifications/initialized"}

INITIALIZE = request(1, "initialize", protocolVersion="2025-11-25", capabilities={},
                     clientInfo={"name": "test", "version": "1"})


@contextlib.contextmanager
def context_server(handler):
    with tempfile.TemporaryDirectory(prefix="tm-context-", dir="/tmp") as directory:
        server = socket.socket(socket.AF_UNIX)
        server.bind(directory + "/s")
        server.listen(8)
        server.settimeout(0.1)
        stopping = threading.Event()
        errors = []
        def serve():
            while not stopping.is_set():
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                try:
                    with connection:
                        connection.settimeout(5)
                        message = json.loads(connection.makefile("rb").readline())
                        value = handler(message, connection)
                        if value is not None:
                            connection.sendall(json.dumps(value).encode() + b"\n")
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except Exception as error:
                    errors.append(error)
        thread = threading.Thread(target=serve)
        thread.start()
        try:
            yield dict(os.environ, TM_CONTEXT_SOCKET=directory + "/s", TM_CONTEXT_SESSION="test-session", TM_CONTEXT_TOKEN="secret-test-token")
        finally:
            stopping.set()
            server.close()
            thread.join(timeout=6)
            if errors: raise errors[0]
            if thread.is_alive(): raise RuntimeError("test context server did not stop")


class MCPTests(unittest.TestCase):
    def run_server(self, messages, environment=None):
        process = subprocess.run([EXECUTABLE], input="".join(json.dumps(m) + "\n" for m in messages),
                                 text=True, capture_output=True, env=environment, timeout=10, check=True)
        return [json.loads(line) for line in process.stdout.splitlines()]

    def test_initialization_tools_notifications_and_pipelining(self):
        replies = self.run_server([
            INITIALIZE,
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            request(2, "tools/list"), request(3, "ping"), request(4, "unknown"),
            request(5, "tools/call", name="not_a_tool"),
            request(6, "tools/call", name="get_editor_context", arguments=[]),
        ])
        self.assertEqual([r["id"] for r in replies], [1, 2, 3, 4, 5, 6])
        self.assertEqual(replies[0]["result"]["protocolVersion"], "2025-11-25")
        tools = replies[1]["result"]["tools"]
        self.assertEqual([t["name"] for t in tools],
                         ["get_editor_context", "list_open_documents", "read_document", "get_diagnostics"])
        self.assertTrue(all(t["annotations"]["readOnlyHint"] for t in tools))
        self.assertEqual(replies[2]["result"], {})
        self.assertEqual(replies[3]["error"]["code"], -32601)
        self.assertEqual(replies[4]["error"]["code"], -32602)
        self.assertEqual(replies[5]["error"]["code"], -32602)

    def test_initialization_required_and_version_fallback(self):
        replies = self.run_server([request(0, "tools/list"),
                                  request(1, "initialize", protocolVersion="future", capabilities={}, clientInfo={"name": "test", "version": "1"})])
        self.assertEqual(replies[0]["error"]["code"], -32000)
        self.assertEqual(replies[1]["result"]["protocolVersion"], "2025-11-25")

    def test_diagnostic_forwarding_and_argument_validation(self):
        received = []
        expected = {"documentId": "open-document", "offset": 2, "limit": 3, "reportId": "report-1"}
        def report(message, _):
            received.append(message)
            return {"status": "reported", "diagnostics": [{"severity": "warning", "message": "Example 😀"}], "reportId": "report-1"}
        with context_server(report) as environment:
            replies = self.run_server([INITIALIZE, READY, request(2, "tools/call", name="get_diagnostics", arguments=expected),
                                       request(3, "tools/call", name="get_diagnostics")], environment)
        self.assertEqual({m["method"] for m in received}, {"get_diagnostics"})
        self.assertCountEqual([m["arguments"] for m in received], [expected, {}])
        by_id = {reply["id"]: reply for reply in replies}
        value = json.loads(by_id[2]["result"]["content"][0]["text"])
        self.assertEqual(value["diagnostics"][0]["message"], "Example 😀")
        self.assertFalse(by_id[2]["result"]["isError"])
        invalid = [{"documentId": ""}, {"documentId": 1}, {"reportId": ""}, {"reportId": False},
                   {"offset": True}, {"offset": -1}, {"offset": 0.5}, {"limit": 0}, {"limit": 101},
                   {"limit": True}, {"severity": "error"}]
        replies = self.run_server([INITIALIZE, READY] + [
            request(index + 2, "tools/call", name="get_diagnostics", arguments=arguments)
            for index, arguments in enumerate(invalid)])
        self.assertEqual(len(replies), 1 + len(invalid))
        self.assertTrue(all(reply["error"]["code"] == -32602 for reply in replies[1:]))

    def test_malformed_and_oversized_input_recovers(self):
        data = '{broken\n' + 'x' * (1024 * 1024 + 1) + '\n' + json.dumps(INITIALIZE) + '\n'
        process = subprocess.run([EXECUTABLE], input=data, text=True, capture_output=True, timeout=10, check=True)
        replies = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual([r["error"]["code"] for r in replies[:2]], [-32700, -32700])
        self.assertEqual(replies[2]["id"], 1)

    def test_missing_connection_is_tool_error(self):
        environment = {k: v for k, v in os.environ.items() if not k.startswith("TM_CONTEXT_")}
        replies = self.run_server([INITIALIZE, READY, request(2, "tools/call", name="get_editor_context")], environment)
        self.assertTrue(replies[1]["result"]["isError"])

    def test_socket_forwarding_unicode_and_explicit_configuration(self):
        with tempfile.TemporaryDirectory(prefix="tm-mcp-", dir="/tmp") as directory:
            path = directory + "/context.sock"
            server = socket.socket(socket.AF_UNIX)
            server.bind(path)
            server.listen(1)
            server.settimeout(5)
            received = []
            failures = []

            def serve():
                try:
                    connection, _ = server.accept()
                    with connection:
                        received.append(json.loads(connection.makefile("rb").readline()))
                        body = json.dumps({"text": "unsaved 😀\n" + "a" * 20000}).encode() + b"\n"
                        # Deliberately fragment the response across reads.
                        connection.sendall(body[:7])
                        connection.sendall(body[7:])
                except Exception as error:
                    failures.append(error)

            thread = threading.Thread(target=serve)
            thread.start()
            environment = dict(os.environ, TM_CONTEXT_SOCKET=path, TM_CONTEXT_SESSION="session", TM_CONTEXT_TOKEN="token")
            replies = self.run_server([INITIALIZE, READY, request(2, "tools/call", name="read_document",
                                                          arguments={"documentId": "doc", "offset": 3})], environment)
            thread.join(timeout=6)
            server.close()
            self.assertFalse(failures)
            self.assertFalse(thread.is_alive())
            self.assertEqual(received, [{"session": "session", "token": "token", "method": "read_document",
                                         "arguments": {"documentId": "doc", "offset": 3}}])
            self.assertFalse(replies[1]["result"]["isError"])
            self.assertTrue(json.loads(replies[1]["result"]["content"][0]["text"])["text"].startswith("unsaved 😀"))
            config = json.loads(subprocess.check_output([EXECUTABLE, "--print-config"], env=environment))
            entry = config["mcpServers"]["textmate"]
            self.assertEqual(entry["command"], EXECUTABLE)
            self.assertEqual(entry["env"]["TM_CONTEXT_SESSION"], "session")


    def test_lifecycle_and_request_validation(self):
        replies = self.run_server([
            request(0, "initialize"), INITIALIZE,
            request(2, "tools/list"), READY,
            request(3, "initialize", **INITIALIZE["params"]),
            request(4, "tools/call", name="get_editor_context", arguments={"extra": True}),
            request(5, "tools/call", name="read_document", arguments={"documentId": "x", "offset": True}),
            request(6, "tools/call", name="read_document", arguments={"documentId": "x", "length": 32769}),
            request(7, "tools/list", cursor="invalid"),
            request(True, "ping"), request(None, "ping"), request(1.5, "ping"),
        ])
        by_id = {json.dumps(reply["id"]): reply for reply in replies}
        self.assertEqual(by_id["0"]["error"]["code"], -32602)
        self.assertEqual(by_id["2"]["error"]["code"], -32000)
        self.assertEqual(by_id["3"]["error"]["code"], -32600)
        for identifier in range(4, 8):
            self.assertEqual(by_id[str(identifier)]["error"]["code"], -32602)
        invalid_ids = [reply for reply in replies if reply["id"] is None]
        self.assertEqual(len(invalid_ids), 3)
        self.assertTrue(all(reply["error"]["code"] == -32600 for reply in invalid_ids))

    def test_connection_diagnostics(self):
        missing = {k: v for k, v in os.environ.items() if not k.startswith("TM_CONTEXT_")}
        process = subprocess.run([EXECUTABLE, "--check"], env=missing, text=True, capture_output=True)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("missing_environment", process.stderr)
        missing.update(TM_CONTEXT_SOCKET="/tmp/no-textmate-context-here/s", TM_CONTEXT_SESSION="closed", TM_CONTEXT_TOKEN="secret-test-token")
        process = subprocess.run([EXECUTABLE, "--check"], env=missing, text=True, capture_output=True)
        self.assertIn("service_unavailable", process.stderr)
        with context_server(lambda message, _: {"error": "The terminal has closed", "code": "session_unavailable"}) as environment:
            process = subprocess.run([EXECUTABLE, "--check"], env=environment, text=True, capture_output=True)
            self.assertIn("session_unavailable", process.stderr)
            self.assertNotIn(environment["TM_CONTEXT_TOKEN"], process.stderr)
        with context_server(lambda message, _: {"windowId": "correct-window", "documentName": "example.txt"}) as environment:
            process = subprocess.run([EXECUTABLE, "--check"], env=environment, text=True, capture_output=True, check=True)
            self.assertIn("correct-window", process.stdout)
            self.assertIn("example.txt", process.stdout)

    def test_overall_deadline_with_a_drip_response(self):
        def drip(message, connection):
            for _ in range(25):
                connection.sendall(b" ")
                time.sleep(0.2)
        with context_server(drip) as environment:
            start = time.monotonic()
            process = subprocess.run([EXECUTABLE, "--check"], env=environment, text=True, capture_output=True, timeout=5)
            self.assertIn("timeout", process.stderr)
            self.assertLess(time.monotonic() - start, 4)

    def test_cancellation_does_not_block_ping(self):
        started = threading.Event()
        def delayed(message, _):
            started.set()
            time.sleep(0.6)
            return {"text": "cancelled result"}
        with context_server(delayed) as environment:
            with subprocess.Popen([EXECUTABLE], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, env=environment) as process:
                def send(message):
                    process.stdin.write(json.dumps(message) + "\n")
                    process.stdin.flush()
                send(INITIALIZE)
                self.assertEqual(json.loads(process.stdout.readline())["id"], 1)
                send(READY)
                send(request(2, "tools/call", name="get_editor_context"))
                self.assertTrue(started.wait(2))
                send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 2}})
                send(request(3, "ping"))
                self.assertEqual(json.loads(process.stdout.readline())["id"], 3)
                process.stdin.close()
                self.assertEqual(process.stdout.read(), "")
                self.assertEqual(process.wait(timeout=5), 0)

    def test_launcher_preserves_arguments_directory_and_session(self):
        launcher = str(Path(EXECUTABLE).with_name("tm-codex"))
        with tempfile.TemporaryDirectory(prefix="tm-launch-", dir="/tmp") as directory:
            app = Path(directory) / 'app "quoted" 😀'
            app.mkdir()
            shutil.copy2(EXECUTABLE, app / "textmate-mcp")
            shutil.copy2(launcher, app / "tm-codex")
            stub = Path(directory) / "codex-stub"
            stub.write_text("#!" + sys.executable + "\nimport json, os, sys\nprint(json.dumps({'args': sys.argv[1:], 'cwd': os.getcwd(), 'session': os.environ['TM_CONTEXT_SESSION']}))\nsys.exit(23)\n")
            stub.chmod(0o700)
            with context_server(lambda message, _: {"windowId": "w", "documentName": "test"}) as environment:
                environment["TM_CODEX_COMMAND"] = str(stub)
                process = subprocess.run([str(app / "tm-codex"), "-m", "example-model", "--", "prompt with spaces"],
                                         cwd=directory, env=environment, text=True, capture_output=True, timeout=5)
                self.assertEqual(process.returncode, 23, process.stderr)
                actual = json.loads(process.stdout)
                self.assertEqual(actual["cwd"], os.path.realpath(directory))
                self.assertEqual(actual["session"], "test-session")
                self.assertEqual(actual["args"][3:], ["-m", "example-model", "--", "prompt with spaces"])
                self.assertEqual(actual["args"][-2:], ["--", "prompt with spaces"])
                self.assertIn("--no-daemon", actual["args"])
                config = tomllib.loads(actual["args"][actual["args"].index("-c")+1])["mcp_servers"]["textmate"]
                self.assertEqual(config["command"], str((app / "textmate-mcp").resolve()))
                self.assertEqual(config["env"], {})
                self.assertEqual(config["env_vars"], ["TM_CONTEXT_SOCKET", "TM_CONTEXT_SESSION", "TM_CONTEXT_TOKEN"])
                self.assertNotIn(environment["TM_CONTEXT_TOKEN"], " ".join(actual["args"]))


    @unittest.skipUnless(shutil.which("codex"), "Codex CLI is not installed")
    def test_launcher_configuration_with_installed_codex(self):
        launcher = str(Path(EXECUTABLE).with_name("tm-codex"))
        with context_server(lambda message, _: {"windowId": "w", "documentName": "test"}) as environment:
            environment["TM_CODEX_COMMAND"] = shutil.which("codex")
            process = subprocess.run([launcher, "mcp", "get", "textmate", "--json"], env=environment,
                                     text=True, capture_output=True, timeout=10)
            self.assertEqual(process.returncode, 0, process.stderr)
            config = json.loads(process.stdout)
            self.assertEqual(config["name"], "textmate")
            self.assertEqual(config["transport"]["command"], EXECUTABLE)
            self.assertNotIn(environment["TM_CONTEXT_TOKEN"], process.stdout)


    def test_claude_launcher_arguments_connection_and_credentials(self):
        launcher = str(Path(EXECUTABLE).with_name("tm-claude"))
        with tempfile.TemporaryDirectory(prefix="tm-claude-", dir="/tmp") as directory:
            app = Path(directory) / 'app "quoted" 😀'
            app.mkdir()
            shutil.copy2(EXECUTABLE, app / "textmate-mcp")
            shutil.copy2(launcher, app / "tm-claude")
            stub = Path(directory) / "claude-stub"
            stub.write_text("#!" + sys.executable + "\n" +
                "import json, os, subprocess, sys\n" +
                "arguments = sys.argv[1:]\n" +
                "config = json.loads(arguments[arguments.index('--mcp-config')+1])['mcpServers']['textmate']\n" +
                "environment = dict(os.environ)\n" +
                "for key, value in config['env'].items(): environment[key] = os.path.expandvars(value)\n" +
                "probe = subprocess.run([config['command'], '--check'], env=environment, text=True, capture_output=True)\n" +
                "print(json.dumps({'args': arguments, 'cwd': os.getcwd(), 'probe': probe.returncode}))\n" +
                "sys.exit(23)\n")
            stub.chmod(0o700)
            for user_arguments in [["Explain the selection"], ["--model", "sonnet", "--resume", "conversation-id", "--", "prompt with spaces"]]:
                with self.subTest(arguments=user_arguments):
                    received = []
                    def context(message, _):
                        received.append(message)
                        return {"windowId": "claude-window", "documentName": "selected.txt"}
                    with context_server(context) as environment:
                        environment["TM_CLAUDE_COMMAND"] = str(stub)
                        process = subprocess.run([str(app / "tm-claude"), *user_arguments], cwd=directory,
                                                 env=environment, text=True, capture_output=True, timeout=5)
                        self.assertEqual(process.returncode, 23, process.stderr)
                        actual = json.loads(process.stdout)
                        self.assertEqual(actual["cwd"], os.path.realpath(directory))
                        self.assertEqual(actual["probe"], 0)
                        arguments = actual["args"]
                        index = arguments.index("--mcp-config")
                        config = json.loads(arguments[index+1])["mcpServers"]["textmate"]
                        self.assertEqual(arguments[:index] + arguments[index+2:], user_arguments)
                        if "--" in arguments: self.assertLess(index+1, arguments.index("--"))
                        else: self.assertEqual(index+2, len(arguments))
                        self.assertEqual(config["command"], str((app / "textmate-mcp").resolve()))
                        self.assertEqual(config["type"], "stdio")
                        self.assertEqual(config["env"]["TM_CONTEXT_TOKEN"], "${TM_CONTEXT_TOKEN}")
                        self.assertNotIn("--strict-mcp-config", arguments)
                        self.assertNotIn(environment["TM_CONTEXT_TOKEN"], " ".join(arguments))
                        self.assertEqual(len(received), 2)
                        self.assertTrue(all(m["token"] == environment["TM_CONTEXT_TOKEN"] for m in received))

    def test_claude_launcher_help_check_and_missing_installation(self):
        launcher = str(Path(EXECUTABLE).with_name("tm-claude"))
        help_result = subprocess.run([launcher, "--help"], text=True, capture_output=True, check=True)
        self.assertIn("TM_CLAUDE_COMMAND", help_result.stdout)
        with context_server(lambda message, _: {"windowId": "claude-window", "documentName": "test.txt"}) as environment:
            environment["TM_CLAUDE_COMMAND"] = "/tmp/nonexistent-claude-installation"
            process = subprocess.run([launcher, "--check"], env=environment, text=True, capture_output=True, check=True)
            self.assertIn("claude-window", process.stdout)
            process = subprocess.run([launcher], env=environment, text=True, capture_output=True)
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("Claude Code CLI was not found", process.stderr)
            self.assertIn("TM_CLAUDE_COMMAND", process.stderr)


    def test_opencode_launcher_preserves_inline_configuration_and_arguments(self):
        launcher = str(Path(EXECUTABLE).with_name("tm-opencode"))
        retained = {"model": "existing/model", "instructions": ["https://example.test/path/*literal*/"],
                    "mcp": {"other": {"type": "local", "command": ["other-server"], "enabled": False},
                            "textmate": {"type": "remote", "url": "https://old-server.test"}}}
        commented = '// inline settings\n' + json.dumps(retained, indent=2).replace('\n}', ',\n}')
        with tempfile.TemporaryDirectory(prefix="tm-opencode-", dir="/tmp") as directory:
            app = Path(directory) / 'app "quoted" 😀'
            app.mkdir()
            shutil.copy2(EXECUTABLE, app / "textmate-mcp")
            shutil.copy2(launcher, app / "tm-opencode")
            stub = Path(directory) / "opencode-stub"
            stub.write_text("#!" + sys.executable + "\n" +
                "import json, os, subprocess, sys\n" +
                "config = json.loads(os.environ['OPENCODE_CONFIG_CONTENT'])\n" +
                "server = config['mcp']['textmate']\n" +
                "environment = dict(os.environ)\n" +
                "for key, value in server['environment'].items(): environment[key] = os.environ[value[5:-1]]\n" +
                "probe = subprocess.run(server['command'] + ['--check'], env=environment, text=True, capture_output=True)\n" +
                "print(json.dumps({'args': sys.argv[1:], 'cwd': os.getcwd(), 'config': config, 'probe': probe.returncode}))\n" +
                "sys.exit(23)\n")
            stub.chmod(0o700)
            arguments = ["run", "--model", "provider/model", "--", "prompt with spaces"]
            for inline in [None, json.dumps(retained), commented]:
                with self.subTest(inline=inline), context_server(lambda message, _: {"windowId": "opencode-window", "documentName": "test"}) as environment:
                    environment["TM_OPENCODE_COMMAND"] = str(stub)
                    environment.pop("OPENCODE_CONFIG_CONTENT", None)
                    if inline is not None: environment["OPENCODE_CONFIG_CONTENT"] = inline
                    process = subprocess.run([str(app / "tm-opencode"), *arguments], cwd=directory,
                                             env=environment, text=True, capture_output=True, timeout=5)
                    self.assertEqual(process.returncode, 23, process.stderr)
                    actual = json.loads(process.stdout)
                    self.assertEqual(actual["args"], arguments)
                    self.assertEqual(actual["cwd"], os.path.realpath(directory))
                    self.assertEqual(actual["probe"], 0)
                    server = actual["config"]["mcp"]["textmate"]
                    self.assertEqual(server["command"], [str((app / "textmate-mcp").resolve())])
                    self.assertEqual(server["type"], "local")
                    self.assertTrue(server["enabled"])
                    self.assertNotIn("url", server)
                    self.assertEqual(server["environment"]["TM_CONTEXT_TOKEN"], "{env:TM_CONTEXT_TOKEN}")
                    self.assertNotIn(environment["TM_CONTEXT_TOKEN"], json.dumps(actual))
                    if inline is not None:
                        self.assertEqual(actual["config"]["model"], retained["model"])
                        self.assertEqual(actual["config"]["instructions"], retained["instructions"])
                        self.assertEqual(actual["config"]["mcp"]["other"], retained["mcp"]["other"])

    def test_opencode_launcher_help_check_and_missing_installation(self):
        launcher = str(Path(EXECUTABLE).with_name("tm-opencode"))
        result = subprocess.run([launcher, "--help"], text=True, capture_output=True, check=True)
        self.assertIn("TM_OPENCODE_COMMAND", result.stdout)
        with context_server(lambda message, _: {"windowId": "opencode-window", "documentName": "test"}) as environment:
            environment["TM_OPENCODE_COMMAND"] = "/tmp/nonexistent-opencode-installation"
            result = subprocess.run([launcher, "--check"], env=environment, text=True, capture_output=True, check=True)
            self.assertIn("opencode-window", result.stdout)
            result = subprocess.run([launcher], env=environment, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("OpenCode CLI was not found", result.stderr)
            self.assertIn("TM_OPENCODE_COMMAND", result.stderr)

    def test_opencode_launcher_rejects_invalid_existing_configuration(self):
        launcher = str(Path(EXECUTABLE).with_name("tm-opencode"))
        with context_server(lambda message, _: {"windowId": "opencode-window", "documentName": "test"}) as environment:
            environment["TM_OPENCODE_COMMAND"] = sys.executable
            for inline in ['{broken', '[]', '{"mcp": []}', '/*unterminated']:
                with self.subTest(inline=inline):
                    environment["OPENCODE_CONFIG_CONTENT"] = inline
                    result = subprocess.run([launcher], env=environment, text=True, capture_output=True, timeout=5)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("OPENCODE_CONFIG_CONTENT must contain", result.stderr)
                    self.assertIn("Existing configuration was not replaced", result.stderr)


if __name__ == "__main__":
    unittest.main()
