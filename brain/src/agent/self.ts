import { execFile, spawn } from 'node:child_process';
import { existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { PROTECTED, protectedRepoPath } from './boundary.js';
import { review, type Flag } from './selfgate.js';

const exec = promisify(execFile);
const REF_PREFIX = 'refs/steward/checkpoints/';
/** The tree of the last successful build, written by scripts/build.sh whoever ran it. */
const BUILT_REF = 'refs/steward/built';
const BUILD_TIMEOUT = 20 * 60_000;
const MAX_FLAGS = 60;
const IDENTITY = { GIT_AUTHOR_NAME: 'Steward', GIT_AUTHOR_EMAIL: 'steward@localhost', GIT_COMMITTER_NAME: 'Steward', GIT_COMMITTER_EMAIL: 'steward@localhost' };
const SOURCE_DIRS = ['brain/src', 'app/Sources'];

/** What the user is shown before a rebuild that needs their say. `tree` pins the approval to exactly this source. */
export interface SelfModifyInput { tree: string; files: string[]; stat: string; flagged: Flag[]; flaggedTotal: number; why: string }
export interface RebuildResult { ok: boolean; log: string; approvalId?: string }

export interface SelfDeps {
  repoRoot: string;
  /** Where temporary index files go. */
  tmpDir: string;
  onLog?: (line: string) => void;
  onBuilt?: () => void;
  /** `config.agent.selfModify`. Default 'ask'. */
  mode?: () => 'auto' | 'ask';
  /** Queues a `self_modify` approval and returns its id. Without it a rebuild that needs approval is refused. */
  requestApproval?: (input: SelfModifyInput, threadId?: string) => string;
}

export function createSelf({ repoRoot, tmpDir, onLog, onBuilt, mode, requestApproval }: SelfDeps) {
  let building: Promise<RebuildResult> | null = null;

  const git = async (args: string[], index?: string): Promise<string> => {
    const { stdout } = await exec('git', ['-C', repoRoot, ...args], { env: { ...process.env, ...IDENTITY, ...(index && { GIT_INDEX_FILE: index }) }, maxBuffer: 64 * 1024 * 1024 });
    return stdout.trim();
  };
  const withIndex = async <T>(fn: (index: string) => Promise<T>): Promise<T> => {
    const index = join(tmpDir, `index-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`);
    try {
      return await fn(index);
    } finally {
      rmSync(index, { force: true });
      rmSync(`${index}.lock`, { force: true });
    }
  };
  /** The working tree (tracked changes and untracked files, not ignored ones) as a tree object. Touches no ref. */
  const currentTree = () => withIndex(async (index) => {
    await git(['add', '-A'], index);
    return git(['write-tree'], index);
  });
  const changedPaths = async (from: string, to: string) => (await git(['diff', '--name-only', '--no-renames', from, to])).split('\n').filter(Boolean);
  const putBack = (commit: string) => withIndex(async (index) => {
    await git(['read-tree', commit], index);
    await git(['checkout-index', '-a', '-f'], index);
    // Against the checkpoint's index, "untracked" means "created after the checkpoint".
    await git(['clean', '-fd', '-q'], index);
  });

  const self = {
    /**
     * Saves the working tree (tracked changes and untracked files, not ignored ones) as a commit under
     * refs/steward/checkpoints/. It goes through a throwaway index, so the user's branch, HEAD and staging area are untouched.
     */
    async snapshot(label = ''): Promise<{ ref: string; commit: string }> {
      const tree = await currentTree();
      const head = await git(['rev-parse', '--verify', '-q', 'HEAD']).catch(() => '');
      const commit = await git(['commit-tree', tree, ...(head ? ['-p', head] : []), '-m', `steward checkpoint${label ? `: ${label}` : ''}`]);
      const ref = `${REF_PREFIX}${new Date().toISOString().replace(/[-:.]/g, '')}`;
      await git(['update-ref', ref, commit]);
      return { ref, commit };
    },

    async list(): Promise<{ ref: string; commit: string; at: string; subject: string }[]> {
      const out = await git(['for-each-ref', '--sort=-refname', '--format=%(refname)%09%(objectname)%09%(creatordate:iso-strict)%09%(subject)', REF_PREFIX]);
      return out ? out.split('\n').map((line) => { const [ref, commit, at, subject] = line.split('\t'); return { ref: ref!, commit: commit!, at: at!, subject: subject ?? '' }; }) : [];
    },

    /**
     * Puts the working tree back to a checkpoint: its files are rewritten and files created since are removed
     * (ignored files stay). The current state is checkpointed first, so a restore can itself be undone.
     * A checkpoint whose protected files differ from the current ones is refused: restoring is done by the brain,
     * outside the sandbox, and must not become a way to roll the guard back.
     */
    async restore(ref: string): Promise<{ restored: string; undo: string }> {
      const name = ref.startsWith(REF_PREFIX) ? ref : `${REF_PREFIX}${ref}`;
      const commit = await git(['rev-parse', '--verify', '-q', `${name}^{commit}`]).catch(() => '');
      if (!commit) throw new Error(`no checkpoint ${ref}`);
      const undo = await self.snapshot(`before restoring ${name.slice(REF_PREFIX.length)}`);
      const guarded = (await changedPaths(undo.commit, commit)).filter(protectedRepoPath);
      if (guarded.length) throw new Error(`${PROTECTED} (the checkpoint differs in ${guarded.slice(0, 8).join(', ')})`);
      await putBack(commit);
      return { restored: name, undo: undo.ref };
    },

    /** True while a build runs: the engine holds the agent's shell and file writes so the source cannot change under the compiler. */
    building: () => building !== null,

    /**
     * Gate, then scripts/build.sh. One build at a time: a second caller gets the running build's outcome.
     * `approvedTree` is the tree a `self_modify` approval was given for; the source must still be exactly that.
     */
    rebuild(opts: { threadId?: string; approvedTree?: string } = {}): Promise<RebuildResult> {
      building ??= gated(opts).catch((err: Error) => ({ ok: false, log: `Rebuild failed before it started: ${err.message}` })).finally(() => (building = null));
      return building;
    },
  };

  async function gated(opts: { threadId?: string; approvedTree?: string }): Promise<RebuildResult> {
    const script = join(repoRoot, 'scripts', 'build.sh');
    if (!existsSync(script)) return { ok: false, log: `${script} not found` };
    const built = await git(['rev-parse', '--verify', '-q', `${BUILT_REF}^{tree}`]).catch(() => '');
    if (!built) return { ok: false, log: 'There is no record of the last build to compare the source against. Ask the owner to run scripts/build.sh by hand once; it writes that record.' };

    for (let attempt = 0; ; attempt++) {
      const tree = await currentTree();
      const verdict = await judge(built, tree, opts);
      if (verdict) return verdict;
      const out = await build(script, tree);
      if (!out.ok) return out;
      const after = await currentTree();
      if (after === tree) {
        onBuilt?.();
        return out;
      }
      // The source moved while it was being compiled. If what moved would have passed on its own, the build stands.
      const moved = await inspect(tree, after);
      if (!moved.protected.length && !moved.flagged.length && (opts.approvedTree === undefined && mode?.() !== 'ask')) {
        onBuilt?.();
        return out;
      }
      // Otherwise unreviewed code may be in the build: put the reviewed source back and build that instead, once.
      const commit = await git(['commit-tree', tree, '-m', 'steward: source as reviewed']);
      await putBack(commit);
      if (attempt >= 1) return { ok: false, log: `${out.log}\n(the source kept changing during the build; nothing was relaunched)` };
    }
  }

  async function inspect(from: string, to: string) {
    const files = await changedPaths(from, to);
    const diff = files.length ? await git(['diff', '-U0', '--no-renames', '--no-color', from, to]) : '';
    const ignored = (await git(['ls-files', '--others', '--ignored', '--exclude-standard', '--', ...SOURCE_DIRS]).catch(() => '')).split('\n').filter(Boolean);
    return { files, ...review(files, diff, ignored) };
  }

  /** Null when the build may go ahead; otherwise the refusal, or the approval that was queued. */
  async function judge(built: string, tree: string, opts: { threadId?: string; approvedTree?: string }): Promise<RebuildResult | null> {
    const { files, protected: guarded, flagged } = await inspect(built, tree);
    if (guarded.length) return { ok: false, log: `${PROTECTED}. These changed since the last build: ${guarded.slice(0, 12).join(', ')}. The owner builds such a change with scripts/build.sh.` };
    if (opts.approvedTree !== undefined) {
      return opts.approvedTree === tree ? null : { ok: false, log: 'The source changed after this rebuild was approved, so the approval no longer covers it. Ask again.' };
    }
    const ask = mode?.() === 'ask';
    if (!flagged.length && !(ask && files.length)) return null;
    const why = flagged.length ? 'The change adds code that reaches outside the app or near its safety checks.' : 'Settings ask for your approval before any self-made change is built.';
    if (!requestApproval) return { ok: false, log: `This rebuild needs the owner's approval. ${why}` };
    const stat = files.length ? await git(['diff', '--stat', '--no-renames', '--no-color', built, tree]) : '';
    const id = requestApproval({ tree, files, stat, flagged: flagged.slice(0, MAX_FLAGS), flaggedTotal: flagged.length, why }, opts.threadId);
    return { ok: false, approvalId: id, log: `Not built yet: this rebuild needs the owner's approval (${id}). ${why} They decide in the app; do not rebuild again or work around it.` };
  }

  function build(script: string, tree: string): Promise<RebuildResult> {
    return new Promise((resolve) => {
      let log = '';
      // The script refuses to build anything but the tree that was judged.
      const child = spawn('/bin/bash', [script], { cwd: repoRoot, env: { ...process.env, STEWARD_GATED_TREE: tree }, stdio: ['ignore', 'pipe', 'pipe'] });
      const timer = setTimeout(() => child.kill('SIGKILL'), BUILD_TIMEOUT);
      const take = (chunk: Buffer) => {
        const text = chunk.toString('utf8');
        log = (log + text).slice(-8000);
        const line = text.trim().split('\n').pop();
        if (line) onLog?.(line.slice(0, 120));
      };
      child.stdout.on('data', take);
      child.stderr.on('data', take);
      child.on('error', (err) => {
        clearTimeout(timer);
        resolve({ ok: false, log: `${log}\n${err.message}`.trim() });
      });
      child.on('close', (code, signal) => {
        clearTimeout(timer);
        const ok = code === 0;
        resolve({ ok, log: ok ? log : `${log}\n(build failed: ${signal ? `killed by ${signal}` : `exit ${code}`})` });
      });
    });
  }

  return self;
}

export type Self = ReturnType<typeof createSelf>;
