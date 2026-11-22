import assert from 'node:assert/strict';
import { execFile, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { approvedProfile, SANDBOX_EXEC, sandboxSettings, type SandboxEnv } from '../agent/sandbox.js';

// Real paths: the kernel matches against where a file is, and the temp folder is reached through a link.
const base = realpathSync(mkdtempSync(join(tmpdir(), 'steward-sandbox-')));
const env: SandboxEnv = { repoRoot: join(base, 'repo'), dataDir: join(base, 'data'), home: join(base, 'home'), writableRoots: [], secretFiles: [join(base, 'data', 'brain.token'), join(base, 'data', 'secrets.env')] };
const file = (path: string, text = 'ORIGINAL\n') => {
  mkdirSync(join(path, '..'), { recursive: true });
  writeFileSync(path, text);
};
for (const rel of ['brain/src/agent/guard.ts', 'brain/src/agent/tools.ts', 'brain/dist/main.js', 'scripts/build.sh', '.git/hooks/pre-commit', '.git/config', 'CLAUDE.md', 'README.md']) file(join(env.repoRoot, rel));
for (const rel of ['config.json', 'brain.token', 'secrets.env', 'memory/profile.md']) file(join(env.dataDir, rel));
for (const rel of ['.claude/settings.json', '.zshrc', '.gitconfig', 'notes/x.md']) file(join(env.home, rel));
after(() => rmSync(base, { recursive: true, force: true }));

const available = process.platform === 'darwin' && existsSync(SANDBOX_EXEC);
/** Runs a command the way an approved one runs. */
const approved = (command: string) => spawnSync(SANDBOX_EXEC, ['-p', approvedProfile(env), '/bin/bash', '-c', command], { encoding: 'utf8', cwd: env.repoRoot, timeout: 15_000 });
const read = (path: string) => readFileSync(path, 'utf8');

test('agent sandbox settings: no domain, no loopback, writes only in the roots, every protected path denied', () => {
  const s = sandboxSettings({ ...env, writableRoots: [join(env.home, 'notes')] });
  assert.equal(s.enabled, true);
  assert.equal(s.failIfUnavailable, true, 'no sandbox means no shell, not an unconfined one');
  assert.deepEqual(s.network!.allowedDomains, []);
  assert.equal(s.network!.allowLocalBinding, false);
  assert.equal(s.network!.allowAllUnixSockets, false);
  assert.deepEqual(s.filesystem!.allowWrite, [env.repoRoot, env.dataDir, join(env.home, 'notes')]);
  assert.deepEqual(s.filesystem!.denyRead, env.secretFiles);
  const denied = s.filesystem!.denyWrite!;
  for (const path of [
    join(env.repoRoot, 'brain/src/agent/guard.ts'), join(env.repoRoot, 'brain/src/agent/boundary.ts'), join(env.repoRoot, 'brain/src/agent/engine.ts'), join(env.repoRoot, 'brain/src/domain/approvals.ts'),
    join(env.repoRoot, 'brain/dist'), join(env.repoRoot, 'brain/node_modules'), join(env.repoRoot, 'scripts'), join(env.repoRoot, 'build'), join(env.repoRoot, '.git'), join(env.repoRoot, 'CLAUDE.md'),
    `${env.repoRoot}/**/.git`, `${env.repoRoot}/**/.git/**`, `${env.repoRoot}/**/.claude/**`, `${join(env.home, 'notes')}/**/.git`,
    join(env.dataDir, 'config.json'), join(env.dataDir, 'secrets.env'), join(env.dataDir, 'brain.token'), join(env.dataDir, 'steward.db'), join(env.dataDir, 'steward.db-wal'),
    join(env.home, '.claude'), join(env.home, '.zshrc'), join(env.home, '.gitconfig'), join(env.home, 'Library/LaunchAgents'),
  ]) assert.ok(denied.includes(path), path);
  assert.ok(s.credentials!.envVars!.some((v) => (v as { name: string }).name === 'ANTHROPIC_API_KEY'));
});

test('approved commands: the kernel still refuses the protected paths and the secrets', { skip: !available && 'needs macOS sandbox-exec' }, () => {
  const refused = (command: string, untouched?: string) => {
    const out = approved(command);
    assert.notEqual(out.status, 0, `${command} should fail: ${out.stdout}${out.stderr}`);
    assert.match(out.stderr, /Operation not permitted/, command);
    if (untouched) assert.equal(read(untouched), 'ORIGINAL\n', command);
  };
  const guard = join(env.repoRoot, 'brain/src/agent/guard.ts');
  refused(`echo HACK > ${guard}`, guard);
  refused(`python3 -c "open('${guard}','w').write('HACK')"`, guard);
  refused(`ln ${guard} ${env.repoRoot}/alias && echo HACK > ${env.repoRoot}/alias`, guard);
  refused(`mv ${env.repoRoot}/brain/src/agent ${env.repoRoot}/brain/src/agent2`, guard);
  refused(`mv ${env.repoRoot}/brain ${env.repoRoot}/brain2`, guard);
  refused(`rm ${guard}`, guard);
  refused(`echo HACK >> ${env.repoRoot}/scripts/build.sh`, join(env.repoRoot, 'scripts/build.sh'));
  refused(`echo x > ${env.repoRoot}/scripts/new.sh`);
  refused(`echo HACK > ${env.repoRoot}/brain/dist/main.js`, join(env.repoRoot, 'brain/dist/main.js'));
  refused(`echo HACK > ${env.repoRoot}/.git/hooks/pre-commit`, join(env.repoRoot, '.git/hooks/pre-commit'));
  refused(`mkdir -p ${env.repoRoot}/sub/.git/hooks && echo x > ${env.repoRoot}/sub/.git/hooks/post-checkout`);
  refused(`echo HACK > ${env.repoRoot}/CLAUDE.md`, join(env.repoRoot, 'CLAUDE.md'));
  refused(`mkdir ${env.repoRoot}/.claude`);
  refused(`echo '{}' > ${env.dataDir}/config.json`, join(env.dataDir, 'config.json'));
  refused(`echo HACK > ${env.home}/.claude/settings.json`, join(env.home, '.claude/settings.json'));
  refused(`echo HACK >> ${env.home}/.zshrc`, join(env.home, '.zshrc'));
  refused(`cat ${env.dataDir}/brain.token`);
  refused(`cp ${env.dataDir}/secrets.env ${env.repoRoot}/copy`);
  assert.equal(existsSync(join(env.repoRoot, 'copy')), false);

  // What an approved command is for still works: ordinary files, git's own bookkeeping, and the network.
  for (const command of [
    `echo ok > ${env.repoRoot}/brain/src/agent/tools.ts`, `echo ok > ${env.repoRoot}/README.md`, `echo ok > ${env.repoRoot}/.git/config`, `echo ok > ${env.dataDir}/memory/profile.md`,
    `cat ${guard}`, `cat ${env.dataDir}/config.json`,
  ]) {
    const out = approved(command);
    assert.equal(out.status, 0, `${command}: ${out.stderr}`);
  }
});

test('approved commands keep the network', { skip: !available && 'needs macOS sandbox-exec' }, async () => {
  const server = createServer((_, res) => res.end('reached'));
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const port = (server.address() as { port: number }).port;
    // Asynchronous on purpose: the server above answers from this same process.
    const out = await new Promise<string>((resolve) => {
      execFile(SANDBOX_EXEC, ['-p', approvedProfile(env), '/bin/bash', '-c', `curl -s -m 5 http://127.0.0.1:${port}/`], (_err, stdout) => resolve(stdout));
    });
    assert.equal(out, 'reached');
  } finally {
    server.close();
  }
});
