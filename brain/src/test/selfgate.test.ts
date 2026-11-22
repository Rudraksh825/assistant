import assert from 'node:assert/strict';
import { test } from 'node:test';
import { addedLines, flagLine, review } from '../agent/selfgate.js';

test('added lines that start processes, open connections, start agent runs or touch the safety wiring are flagged', () => {
  const flagged: [string, string][] = [
    ['brain/src/jobs/x.ts', "import { spawn } from 'node:child_process';"],
    ['brain/src/jobs/x.ts', "  execFile('git', ['push']);"],
    ['brain/src/jobs/x.ts', "  const res = await fetch('https://example.com', { method: 'POST' });"],
    ['brain/src/jobs/x.ts', "import https from 'node:https';"],
    ['brain/src/jobs/x.ts', "const net = require('net');"],
    ['brain/src/jobs/x.ts', '  new WebSocket(url);'],
    ['brain/src/jobs/x.ts', "import { query } from '@anthropic-ai/claude-agent-sdk';"],
    ['brain/src/jobs/x.ts', '  for await (const m of query({ prompt })) {}'],
    ['brain/src/jobs/x.ts', "  hooks: { PreToolUse: [] },"],
    ['brain/src/jobs/x.ts', "  permissionMode: 'bypassPermissions',"],
    ['brain/src/agent/tools.ts', '  ctx.repos.approvals.approve(id, undefined, ctx.agent.executeApproval);'],
    ['brain/src/agent/tools.ts', "  repos['approvals'].create(x);"],
    ['brain/src/agent/index.ts', "const READ_BUILTINS = ['Read', 'Bash'];"],
    ['brain/src/agent/chat.ts', '  dangerouslyDisableSandbox: true,'],
    ['brain/src/jobs/x.ts', "  const f = new Function('return 1');"],
    ['brain/src/jobs/x.ts', "  const m = await import(name);"],
    ['brain/src/jobs/x.ts', '  eval(code);'],
    ['brain/src/core/config.ts', "  agent: { selfModify: 'auto' },"],
    ['app/Sources/Steward/X.swift', '    let p = Process()'],
    ['app/Sources/Steward/X.swift', '    NSAppleScript(source: s)?.executeAndReturnError(nil)'],
    ['app/Sources/Steward/X.swift', '    let (data, _) = try await URLSession.shared.data(from: url)'],
    ['app/Sources/Steward/X.swift', '    var req = URLRequest(url: URL(string: "https://example.com/hook")!)'],
    ['app/Sources/Steward/X.swift', '    NSWorkspace.shared.open(url)'],
    ['app/Sources/StewardKit/X.swift', '    let c = NWConnection(host: h, port: p, using: .tcp)'],
  ];
  for (const [file, text] of flagged) assert.ok(flagLine(file, text), `${file}: ${text}`);

  const plain: [string, string][] = [
    ['brain/src/domain/tasks.ts', '  return tasks.filter((t) => t.status === "todo");'],
    ['brain/src/jobs/briefs.ts', "  const title = 'Morning brief';"],
    ['brain/src/agent/prompts.ts', '- Be brief, concrete and warm.'],
    ['app/Sources/Steward/X.swift', '    Text(task.title).font(Typo.body)'],
    ['app/Sources/StewardKit/Brain/BrainClient.swift', '    let url = URL(string: "http://127.0.0.1:\\(port)/state")!'],
    ['docs/notes.md', 'run fetch( and spawn( by hand'],
    ['brain/src/test/x.test.ts', "import { spawn } from 'node:child_process';"],
  ];
  for (const [file, text] of plain) assert.equal(flagLine(file, text), null, `${file}: ${text}`);
});

test('review: protected paths, build files, hidden sources and flagged lines, from a real diff', () => {
  const diff = [
    'diff --git a/brain/src/jobs/x.ts b/brain/src/jobs/x.ts',
    '--- a/brain/src/jobs/x.ts', '+++ b/brain/src/jobs/x.ts',
    '@@ -3,0 +4,2 @@ import x', "+import { execFile } from 'node:child_process';", '+const quiet = 1;',
    '@@ -20 +22 @@', "-  old();", "+  execFile('sh', ['-c', cmd]);",
    'diff --git a/app/Sources/Steward/A.swift b/app/Sources/Steward/A.swift',
    '--- a/app/Sources/Steward/A.swift', '+++ b/app/Sources/Steward/A.swift',
    '@@ -1 +1 @@', '-let a = 1', '+let a = 2',
  ].join('\n');
  assert.deepEqual(addedLines(diff), [
    { file: 'brain/src/jobs/x.ts', line: 4, text: "import { execFile } from 'node:child_process';" },
    { file: 'brain/src/jobs/x.ts', line: 5, text: 'const quiet = 1;' },
    { file: 'brain/src/jobs/x.ts', line: 22, text: "  execFile('sh', ['-c', cmd]);" },
    { file: 'app/Sources/Steward/A.swift', line: 1, text: 'let a = 2' },
  ]);
  const r = review(['brain/src/jobs/x.ts', 'app/Sources/Steward/A.swift', 'brain/package.json', 'scripts/build.sh', 'brain/src/agent/guard.ts', '.gitignore'], diff, ['brain/src/hidden.ts']);
  assert.deepEqual(r.protected, ['scripts/build.sh', 'brain/src/agent/guard.ts']);
  assert.deepEqual(r.flagged.map((f) => [f.file, f.line, f.why]), [
    ['brain/package.json', 0, 'the build runs or obeys this file'],
    ['scripts/build.sh', 0, 'the build runs or obeys this file'],
    ['.gitignore', 0, 'the build runs or obeys this file'],
    ['brain/src/hidden.ts', 0, 'a source file hidden from the diff by .gitignore'],
    ['brain/src/jobs/x.ts', 4, 'starts a process'],
    ['brain/src/jobs/x.ts', 22, 'starts a process'],
  ]);
  assert.deepEqual(review(['app/Sources/Steward/A.swift'], diff.split('diff --git')[2]!), { protected: [], flagged: [] });
});
