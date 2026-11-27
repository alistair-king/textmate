#!/usr/bin/env python3
"""A language server for Compare's window tests.

Usage: fake_compare_lsp.py <extra-folder>

Definitions: the word at the position names a line `func <word>`, looked for
in the requested document, then in the files of the workspace root and then
of <extra-folder>. Hover: `func <word>` as code and "Docs for **<word>**.".
Columns are Python string indices, which are UTF-16 units only for text
without characters outside the BMP: keep the fixtures to those.
Speaks Content-Length framed JSON-RPC over stdio and exits when stdin closes.
"""

import json
import os
import re
import sys
from urllib.parse import unquote, urlparse

EXTRA = sys.argv[1] if len(sys.argv) > 1 else None
documents = {}  # uri -> text
root = None


def send(message):
	body = json.dumps(message).encode("utf-8")
	sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
	sys.stdout.buffer.flush()


def read():
	length = None
	while True:
		line = sys.stdin.buffer.readline()
		if not line:
			return None
		line = line.strip()
		if not line:
			break
		if line.lower().startswith(b"content-length:"):
			length = int(line.split(b":", 1)[1])
	return json.loads(sys.stdin.buffer.read(length)) if length else {}


def path_of(uri):
	return unquote(urlparse(uri).path)


def word_at(text, line, character):
	lines = text.split("\n")
	if line >= len(lines):
		return None
	for match in re.finditer(r"\w+", lines[line]):
		if match.start() <= character <= match.end():
			return match.group(0)
	return None


def find_in(text, word):
	for number, line in enumerate(text.split("\n")):
		match = re.search(r"\bfunc\s+(%s)\b" % re.escape(word), line)
		if match:
			return number, match.start(1)
	return None


def files_in(folder):
	for directory, _, names in os.walk(folder):
		for name in sorted(names):
			if name.endswith(".cmpt"):
				yield os.path.join(directory, name)


def definition(uri, word):
	found = find_in(documents.get(uri, ""), word)
	if found:
		return uri, found
	for folder in (root, EXTRA):
		for path in files_in(folder) if folder else ():
			with open(path, encoding="utf-8") as f:
				found = find_in(f.read(), word)
			if found:
				return "file://" + path, found
	return None


while True:
	message = read()
	if message is None:
		break
	method, params, identifier = message.get("method"), message.get("params") or {}, message.get("id")
	if method == "initialize":
		root = path_of(params.get("rootUri") or "") or params.get("rootPath")
		send({"jsonrpc": "2.0", "id": identifier, "result": {"capabilities": {"textDocumentSync": 1, "definitionProvider": True, "hoverProvider": True}}})
	elif method == "textDocument/didOpen":
		documents[params["textDocument"]["uri"]] = params["textDocument"]["text"]
	elif method == "textDocument/didChange":
		documents[params["textDocument"]["uri"]] = params["contentChanges"][-1]["text"]
	elif method in ("textDocument/definition", "textDocument/hover"):
		uri = params["textDocument"]["uri"]
		position = params["position"]
		word = word_at(documents.get(uri, ""), position["line"], position["character"])
		result = None
		if word and method == "textDocument/hover":
			result = {"contents": {"kind": "markdown", "value": "```cmpt\nfunc %s\n```\n---\nDocs for **%s**." % (word, word)}}
		elif word:
			found = definition(uri, word)
			if found:
				target, (line, character) = found
				place = {"line": line, "character": character}
				result = {"uri": target, "range": {"start": place, "end": {"line": line, "character": character + len(word)}}}
		send({"jsonrpc": "2.0", "id": identifier, "result": result})
	elif method == "exit":
		break
	elif identifier is not None and method:  # shutdown and anything else
		send({"jsonrpc": "2.0", "id": identifier, "result": None})
