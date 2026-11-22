import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { createSelf, type SelfModifyInput } from '../agent/self.js';

const repo = mkdtempSync(join(tmpdir(), 'steward-self-'));
const tmp = mkdtempSync(join(tmpdir(), 'steward-self-tmp-'));
const git = (...args: string[]) => execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8' }).trim();
const write = (path: string, text: string) => {
  mkdirSync(join(repo, path, '..'), { recursive: true });
  writeFileSync(join(repo, path), text);
};
const read = (path: string) => readFileSync(join(repo, path), 'utf8');

after(() => {
  rmSync(repo, { recursive: true, force: true });
  rmSync(tmp, { recursive: true, force: true });
});

test('snapshot keeps branch, HEAD and index untouched; restore brings the tree back', async () => {
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 'dev@example.com');
  git('config', 'user.name', 'Dev');
  write('.gitignore', 'build/\n');
  write('src/a.ts', 'one\n');
  git('add', '-A');
  git('commit', '-q', '-m', 'init');

  write('src/a.ts', 'two\n');
  write('src/new.ts', 'untracked\n');
  write('build/out.bin', 'ignored\n');
  write('staged.txt', 'staged\n');
  git('add', 'staged.txt');
  const before = { head: git('rev-parse', 'HEAD'), branch: git('branch', '--show-current'), status: git('status', '--porcelain'), log: git('rev-list', '--count', 'HEAD') };

  const self = createSelf({ repoRoot: repo, tmpDir: tmp });
  const snap = await self.snapshot('test');
  assert.match(snap.ref, /^refs\/steward\/checkpoints\/\d{8}T\d{9}Z$/);
  assert.deepEqual({ head: git('rev-parse', 'HEAD'), branch: git('branch', '--show-current'), status: git('status', '--porcelain'), log: git('rev-list', '--count', 'HEAD') }, before);
  const files = git('ls-tree', '-r', '--name-only', snap.ref).split('\n').sort();
  assert.deepEqual(files, ['.gitignore', 'src/a.ts', 'src/new.ts', 'staged.txt']);
  assert.equal(git('show', `${snap.ref}:src/a.ts`), 'two');
  assert.equal(git('rev-parse', `${snap.ref}^`), before.head);
  assert.equal((await self.list())[0]!.ref, snap.ref);

  write('src/a.ts', 'three\n');
  write('src/later.ts', 'made after the checkpoint\n');
  rmSync(join(repo, 'src/new.ts'));
  const restored = await self.restore(snap.ref);

  assert.equal(read('src/a.ts'), 'two\n');
  assert.equal(read('src/new.ts'), 'untracked\n');
  assert.equal(existsSync(join(repo, 'src/later.ts')), false);
  assert.equal(read('build/out.bin'), 'ignored\n', 'ignored files survive a restore');
  assert.deepEqual({ head: git('rev-parse', 'HEAD'), branch: git('branch', '--show-current'), status: git('status', '--porcelain'), log: git('rev-list', '--count', 'HEAD') }, before);
  assert.equal(git('show', `${restored.undo}:src/later.ts`), 'made after the checkpoint', 'the pre-restore state is itself checkpointed');
  await assert.rejects(self.restore('nope'), /no checkpoint/);
});

test('snapshot works in a repo with no commits yet', async () => {
  const empty = mkdtempSync(join(tmpdir(), 'steward-self-empty-'));
  try {
    execFileSync('git', ['-C', empty, 'init', '-q']);
    writeFileSync(join(empty, 'a.txt'), 'a\n');
    const snap = await createSelf({ repoRoot: empty, tmpDir: tmp }).snapshot();
    assert.equal(execFileSync('git', ['-C', empty, 'show', `${snap.ref}:a.txt`], { encoding: 'utf8' }), 'a\n');
  } finally {
    rmSync(empty, { recursive: true, force: true });
  }
});

/** A repo whose build script does whatever `hook.sh` outside the repo says, and whose current tree is on record as built. */
function buildable() {
  const root = mkdtempSync(join(tmpdir(), 'steward-self-build-'));
  const hook = join(tmp, `hook-${Math.random().toString(36).slice(2)}.sh`);
  const g = (...args: string[]) => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8' }).trim();
  const put = (path: string, text: string) => {
    mkdirSync(join(root, path, '..'), { recursive: true });
    writeFileSync(join(root, path), text);
  };
  g('init', '-q');
  put('.gitignore', 'brain/dist/\n');
  put('scripts/build.sh', `[ -f "${hook}" ] && . "${hook}"\necho "==> step one"\necho done\n`);
  put('brain/src/agent/guard.ts', 'export const guard = 1;\n');
  put('brain/src/jobs/x.ts', 'export const x = 1;\n');
  put('app/Sources/Steward/A.swift', 'let a = 1\n');
  const asked: { input: SelfModifyInput; threadId?: string }[] = [];
  let built = 0;
  let mode: 'auto' | 'ask' = 'auto';
  const self = createSelf({ repoRoot: root, tmpDir: tmp, onBuilt: () => built++, mode: () => mode, requestApproval: (input, threadId) => { asked.push({ input, threadId }); return `approval-${asked.length}`; } });
  const record = async () => g('update-ref', 'refs/steward/built', (await self.snapshot('built')).commit);
  return { root, hook, put, self, asked, record, built: () => built, setMode: (m: 'auto' | 'ask') => (mode = m), read: (path: string) => readFileSync(join(root, path), 'utf8'), done: () => rmSync(root, { recursive: true, force: true }) };
}

test('rebuild: a missing script or a missing build record refuses; a plain change builds straight away', async () => {
  assert.deepEqual(await createSelf({ repoRoot: tmp, tmpDir: tmp }).rebuild(), { ok: false, log: `${join(tmp, 'scripts', 'build.sh')} not found` });
  const r = buildable();
  try {
    const first = await r.self.rebuild();
    assert.equal(first.ok, false);
    assert.match(first.log, /no record of the last build/);
    assert.equal(r.built(), 0);

    await r.record();
    const same = await r.self.rebuild();
    assert.equal(same.ok, true);
    assert.match(same.log, /==> step one\ndone/);
    assert.equal(r.built(), 1);

    r.put('brain/src/jobs/x.ts', 'export const x = 2;\n');
    r.put('app/Sources/Steward/A.swift', 'let a = 2\n');
    assert.equal((await r.self.rebuild()).ok, true);
    assert.equal(r.built(), 2);
    assert.equal(r.asked.length, 0);

    writeFileSync(r.hook, 'echo broken >&2\nexit 3\n');
    const failed = await r.self.rebuild();
    assert.equal(failed.ok, false);
    assert.match(failed.log, /broken[\s\S]*exit 3/);
    assert.equal(r.built(), 2);
  } finally {
    r.done();
  }
});

test('rebuild: a change that starts processes or opens connections waits for approval of that exact tree', async () => {
  const r = buildable();
  try {
    await r.record();
    r.put('brain/src/jobs/x.ts', "import { execFile } from 'node:child_process';\nexport const x = () => execFile('git', ['push']);\n");
    r.put('app/Sources/Steward/A.swift', 'let a = try await URLSession.shared.data(from: URL(string: "https://example.com")!)\n');
    const held = await r.self.rebuild({ threadId: 'thread-1' });
    assert.deepEqual([held.ok, held.approvalId, r.built()], [false, 'approval-1', 0]);
    assert.match(held.log, /needs the owner's approval/);
    const { input, threadId } = r.asked[0]!;
    assert.equal(threadId, 'thread-1');
    assert.deepEqual(input.files, ['app/Sources/Steward/A.swift', 'brain/src/jobs/x.ts']);
    assert.match(input.stat, /2 files changed/);
    assert.deepEqual(input.flagged.map((f) => [f.file, f.line, f.why]), [
      ['app/Sources/Steward/A.swift', 1, 'makes a request that is not plainly to this machine'],
      ['brain/src/jobs/x.ts', 1, 'starts a process'],
      ['brain/src/jobs/x.ts', 2, 'starts a process'],
    ]);
    assert.equal(input.flaggedTotal, 3);
    assert.match(input.tree, /^[0-9a-f]{40}$/);

    // Approved for one tree, the source moved on: the approval no longer covers it.
    r.put('brain/src/jobs/x.ts', "import { execFile } from 'node:child_process';\nexport const x = () => execFile('rm', ['-rf', '/']);\n");
    const stale = await r.self.rebuild({ approvedTree: input.tree });
    assert.equal(stale.ok, false);
    assert.match(stale.log, /changed after this rebuild was approved/);
    assert.equal(r.built(), 0);

    r.put('brain/src/jobs/x.ts', "import { execFile } from 'node:child_process';\nexport const x = () => execFile('git', ['push']);\n");
    assert.equal((await r.self.rebuild({ approvedTree: input.tree })).ok, true);
    assert.equal(r.built(), 1);
  } finally {
    r.done();
  }
});

test('rebuild: "ask" holds every change; a protected path in the diff refuses the build outright', async () => {
  const r = buildable();
  try {
    await r.record();
    r.setMode('ask');
    assert.equal((await r.self.rebuild()).ok, true, 'nothing changed, nothing to ask');
    r.put('brain/src/jobs/x.ts', 'export const x = 3;\n');
    const held = await r.self.rebuild();
    assert.deepEqual([held.ok, held.approvalId], [false, 'approval-1']);
    assert.deepEqual([r.asked[0]!.input.files, r.asked[0]!.input.flagged], [['brain/src/jobs/x.ts'], []]);

    r.setMode('auto');
    r.put('brain/src/agent/guard.ts', 'export const guard = 0;\n');
    r.put('scripts/extra.sh', 'echo hi\n');
    for (const opts of [{}, { approvedTree: r.asked[0]!.input.tree }]) {
      const refused = await r.self.rebuild(opts);
      assert.equal(refused.ok, false);
      assert.match(refused.log, /^protected: ask the owner to change this by hand\. These changed since the last build: brain\/src\/agent\/guard\.ts, scripts\/extra\.sh/);
    }
    assert.equal(r.built(), 1);
    assert.equal(r.asked.length, 1);
  } finally {
    r.done();
  }
});

test('rebuild: source that changes under the compiler is put back to what was judged when it would not have passed', async () => {
  const r = buildable();
  try {
    await r.record();
    // A harmless file appearing during the build does not undo it.
    writeFileSync(r.hook, `echo note > "${r.root}/notes.txt"\n`);
    assert.equal((await r.self.rebuild()).ok, true);
    assert.equal(r.built(), 1);
    // Code that needs approval slipping in during the build does.
    writeFileSync(r.hook, `echo "import 'node:child_process';" >> "${r.root}/brain/src/jobs/x.ts"\n`);
    const out = await r.self.rebuild();
    assert.equal(out.ok, false);
    assert.match(out.log, /kept changing during the build/);
    assert.equal(r.built(), 1);
    assert.equal(r.read('brain/src/jobs/x.ts'), 'export const x = 1;\n');
  } finally {
    r.done();
  }
});

test('restore refuses a checkpoint that would roll a protected file back', async () => {
  const r = buildable();
  try {
    const old = await r.self.snapshot('old');
    r.put('brain/src/jobs/x.ts', 'export const x = 9;\n');
    assert.equal((await r.self.restore(old.ref)).restored, old.ref);
    assert.equal(r.read('brain/src/jobs/x.ts'), 'export const x = 1;\n');
    r.put('brain/src/agent/guard.ts', 'export const guard = 2; // hardened by hand\n');
    await assert.rejects(r.self.restore(old.ref), /^Error: protected: ask the owner to change this by hand \(the checkpoint differs in brain\/src\/agent\/guard\.ts\)/);
    assert.equal(r.read('brain/src/agent/guard.ts'), 'export const guard = 2; // hardened by hand\n');
  } finally {
    r.done();
  }
});
