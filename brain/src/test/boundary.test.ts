import assert from 'node:assert/strict';
import { test } from 'node:test';
import { protectedAncestors, protectedPath, protectedRepoPath, protectedRoots, touchesBoundary } from '../agent/boundary.js';

const at = { repoRoot: '/repo', dataDir: '/home/u/data', home: '/home/u' };
const env = { ...at, cwd: '/repo/brain' };

test('the agent cannot write the safety boundary, and can write the rest of its source', () => {
  for (const file of ['/repo/brain/src/agent/guard.ts', 'src/agent/guard.ts', '/repo/brain/src/test/guard.test.ts', '/repo/brain/src/domain/approvals.ts', '/repo/brain/dist/agent/guard.js',
    '/repo/brain/dist/agent/guard.js.map', '/repo/brain/dist/domain/approvals.js', '/repo/brain/src/agent/boundary.ts', '/repo/brain/src/agent/../agent/Guard.ts',
    '/repo/brain/src/agent/engine.ts', '/repo/brain/src/agent/sandbox.ts', '/repo/brain/src/agent/executor.ts', '/repo/brain/src/agent/self.ts', '/repo/brain/src/agent/selfgate.ts',
    '/repo/brain/src/approvals-api.ts', '/repo/scripts/build.sh', '/repo/scripts', '/repo/build/Steward.app/x', '/repo/app/.build/debug/Steward', '/repo/app/.build-main/x',
    '/repo/brain/node_modules/zod/index.js', '/repo/.git/hooks/pre-commit', '/repo/sub/.git/config', '/repo/CLAUDE.md', '/repo/docs/AGENTS.md', '/repo/.claude/settings.json',
    '/repo/.github/workflows/ci.yml', '/repo/.mcp.json', '/home/u/data/config.json', '/home/u/data/secrets.env', '/home/u/data/brain.token', '/home/u/data/steward.db-wal',
    '~/.claude/settings.json', '~/.zshrc', '~/.gitconfig', '~/Library/LaunchAgents/x.plist', '~/.ssh/authorized_keys', '/elsewhere/project/.git/hooks/x']) {
    for (const tool of ['Write', 'Edit', 'MultiEdit']) assert.equal(touchesBoundary(tool, { file_path: file }, env), true, `${tool} ${file}`);
  }
  for (const file of ['/repo/brain/src/agent/tools.ts', '/repo/brain/src/domain/tasks.ts', '/repo/app/Sources/Steward/Guard.swift', '/elsewhere/brain/src/agent/guard.ts', '/repo/brain/src/agent/guard.ts.bak/x',
    '/repo/README.md', '/repo/brain/src/api.ts', '/home/u/data/memory/profile.md', '/home/u/data/agent/config.json', '/repo/scripts-notes.md', '/repo/docs/build/x.md']) {
    assert.equal(touchesBoundary('Write', { file_path: file }, env), false, file);
  }
  assert.equal(touchesBoundary('Read', { file_path: '/repo/brain/src/agent/guard.ts' }, env), false);
  assert.equal(touchesBoundary('NotebookEdit', { notebook_path: '/repo/scripts/x.ipynb' }, env), true);
  // A link into the repo is judged by where it points.
  assert.equal(touchesBoundary('Edit', { file_path: '/tmp/link/guard.ts' }, { ...env, realpath: (p) => p.replace('/tmp/link', '/repo/brain/src/agent') }), true);
});

test('shell commands are not judged by the tripwire: the guard and the sandbox profile do that', () => {
  assert.equal(touchesBoundary('Bash', { command: 'echo x > brain/src/agent/guard.ts' }, env), false);
});

test('protected roots cover every fixed protected path, and their parent folders are known', () => {
  const roots = protectedRoots(at);
  for (const root of roots) assert.equal(protectedPath(root, at), true, root);
  for (const path of ['/repo/brain/src/agent/guard.ts', '/repo/scripts', '/repo/brain/dist', '/repo/.git', '/home/u/data/config.json', '/home/u/.claude', '/home/u/Library/LaunchAgents']) assert.ok(roots.includes(path), path);
  const above = protectedAncestors(at);
  for (const dir of ['/repo', '/repo/brain', '/repo/brain/src', '/repo/brain/src/agent', '/repo/brain/src/domain', '/home/u/data']) assert.ok(above.includes(dir), dir);
  assert.ok(!above.includes('/home/u') && !above.includes('/'));
});

test('repo-relative paths, as git prints them', () => {
  for (const rel of ['brain/src/agent/guard.ts', 'scripts/run.sh', 'CLAUDE.md', 'brain/src/test/sandbox.test.ts', '.github/workflows/x.yml']) assert.equal(protectedRepoPath(rel), true, rel);
  for (const rel of ['brain/src/agent/tools.ts', 'app/Package.swift', 'README.md', 'brain/package.json']) assert.equal(protectedRepoPath(rel), false, rel);
});
