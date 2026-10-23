// Run with: node test_sdk.mjs /path/to/sdk/dist/esm /path/to/textmate-mcp
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { createServer } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
const root = resolve(process.argv[2]);
const { Client } = await import(pathToFileURL(join(root, 'client/index.js')));
const { StdioClientTransport } = await import(pathToFileURL(join(root, 'client/stdio.js')));
const directory = await mkdtemp('/tmp/tm-sdk-');
const socket = join(directory, 's');
let requests = 0;
const server = createServer(connection => {
  let input = '';
  connection.on('data', chunk => {
    input += chunk.toString();
    if (!input.includes('\n')) return;
    const message = JSON.parse(input.split('\n')[0]);
    assert.equal(message.session, 'sdk-session');
    assert.equal(message.token, 'sdk-token');
    requests++;
    connection.end(JSON.stringify({windowId: 'sdk-window', document: {name: 'unsaved.txt'}, selections: [{text: 'live 😀'}]})+'\n');
  });
});
await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
const client = new Client({name: 'textmate-compatibility-test', version: '1.0'});
const transport = new StdioClientTransport({command: resolve(process.argv[3]),
  env: {...process.env, TM_CONTEXT_SOCKET: socket, TM_CONTEXT_SESSION: 'sdk-session', TM_CONTEXT_TOKEN: 'sdk-token'}, stderr: 'pipe'});
try {
  await client.connect(transport);
  const list = await client.listTools();
  assert.deepEqual(list.tools.map(tool => tool.name), ['get_editor_context','list_open_documents','read_document']);
  const result = await client.callTool({name: 'get_editor_context', arguments: {}});
  assert.equal(result.isError, false);
  assert.equal(JSON.parse(result.content[0].text).selections[0].text, 'live 😀');
  assert.equal(requests, 1);
  await client.ping();
  console.log('Official MCP SDK: initialization, discovery, tool call, Unicode and ping passed.');
} finally {
  await client.close();
  await new Promise(resolve => server.close(resolve));
  await rm(directory, {recursive: true, force: true});
}
