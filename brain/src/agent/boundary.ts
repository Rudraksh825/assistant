import { dirname, relative, resolve, sep } from 'node:path';

export const PROTECTED = 'protected: ask the owner to change this by hand';

/** Where things are on this machine. Paths are absolute; pass them through `realpath` first when links matter. */
export interface Places { repoRoot: string; dataDir: string; home: string }

/**
 * Inside the Steward repo: the code that decides what the agent may do, everything a rebuild executes or loads
 * without the agent's diff being looked at (build scripts, built output, dependencies, the bundle), the command-line
 * client the owner runs by hand, and git internals.
 */
const REPO = [
  /^brain\/src\/agent\/(guard|boundary|engine|sandbox|executor|self|selfgate)\.ts$/,
  /^brain\/src\/domain\/approvals\.ts$/,
  /^brain\/src\/approvals-api\.ts$/,
  /^brain\/src\/test\/(guard|boundary|sandbox|selfgate|approvals)\.test\.ts$/,
  /^brain\/(dist|node_modules|bin)(\/|$)/,
  /^scripts(\/|$)/,
  /^build(\/|$)/,
  /^app\/\.build[^/]*(\/|$)/,
];
const REPO_ROOTS = [
  ...['guard', 'boundary', 'engine', 'sandbox', 'executor', 'self', 'selfgate'].map((f) => `brain/src/agent/${f}.ts`),
  'brain/src/domain/approvals.ts', 'brain/src/approvals-api.ts',
  ...['guard', 'boundary', 'sandbox', 'selfgate', 'approvals'].map((f) => `brain/src/test/${f}.test.ts`),
  'brain/dist', 'brain/node_modules', 'brain/bin', 'scripts', 'build', 'app/.build',
];

/** Directory and file names that other tools execute or obey wherever they sit: git internals, editor and agent settings, CI. */
const DIRS = ['.git', '.claude', '.cursor', '.vscode', '.idea', '.github', '.husky'];
const FILES = ['CLAUDE.md', 'CLAUDE.local.md', 'AGENTS.md', '.mcp.json', '.claude.json', '.cursorrules', '.envrc', '.gitconfig'];
const ANYWHERE = new RegExp(`(^|/)(${DIRS.map(escape).join('|')})(/|$)|(^|/)(${FILES.map(escape).join('|')})$`);

/** Under the home directory: what runs at login or in every shell, and credentials for other machines. */
const HOME = [
  '.claude', '.claude.json', '.gitconfig', '.config/git', '.config/gh', '.config/fish', '.ssh', '.gnupg', '.npmrc', '.curlrc', '.wgetrc', '.netrc',
  '.zshrc', '.zshenv', '.zprofile', '.zlogin', '.zlogout', '.bashrc', '.bash_profile', '.bash_login', '.bash_logout', '.profile', '.inputrc',
  'Library/LaunchAgents', 'Library/LaunchDaemons',
];
/** In the data dir: settings (agent and budget keys among them), secrets, the API token and the database. The agent has tools for what it may change. */
const DATA = /^(config\.json(\.tmp)?|secrets\.env|brain\.token|brain\.port|steward\.db(-wal|-shm|-journal)?)$/;
const DATA_ROOTS = ['config.json', 'config.json.tmp', 'secrets.env', 'brain.token', 'brain.port', 'steward.db', 'steward.db-wal', 'steward.db-shm', 'steward.db-journal'];
const SYSTEM = ['/Library/LaunchAgents', '/Library/LaunchDaemons', '/etc', '/private/etc'];

function escape(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
const under = (path: string, root: string): string | null => {
  const rel = relative(root, path);
  return rel === '' || (!rel.startsWith('..') && !rel.startsWith(sep) && !/^[A-Za-z]:/.test(rel)) ? rel.split(sep).join('/') : null;
};
const inside = (path: string, root: string) => under(path, root) !== null;

const ANYWHERE_I = new RegExp(ANYWHERE.source, 'i');
const REPO_I = REPO.map((re) => new RegExp(re.source, 'i'));

/** True when the agent must not write `abs`, whatever tool it uses. Case is ignored: the default macOS volume does. */
export function protectedPath(abs: string, at: Places): boolean {
  const path = abs.toLowerCase();
  if (ANYWHERE_I.test(path)) return true;
  if (SYSTEM.some((dir) => inside(path, dir.toLowerCase()))) return true;
  const home = at.home.toLowerCase();
  if (HOME.some((entry) => inside(path, resolve(home, entry.toLowerCase())))) return true;
  const data = under(path, at.dataDir.toLowerCase());
  if (data !== null && DATA.test(data)) return true;
  const repo = under(path, at.repoRoot.toLowerCase());
  return repo !== null && REPO_I.some((re) => re.test(repo));
}
/** `rel` is repo-relative with forward slashes, as git prints it. */
export const protectedRepoPath = (rel: string): boolean => ANYWHERE_I.test(rel) || REPO_I.some((re) => re.test(rel));

/** The fixed protected locations as absolute paths, for the sandbox profiles and for "could this prefix lead there". */
export function protectedRoots(at: Places): string[] {
  return [
    ...REPO_ROOTS.map((rel) => resolve(at.repoRoot, rel)),
    ...DIRS.map((dir) => resolve(at.repoRoot, dir)),
    ...FILES.map((file) => resolve(at.repoRoot, file)),
    ...DATA_ROOTS.map((file) => resolve(at.dataDir, file)),
    ...HOME.map((entry) => resolve(at.home, entry)),
    ...SYSTEM,
  ];
}

/** Glob patterns for the names protected at any depth under `root`. */
export function protectedGlobs(root: string): string[] {
  return [...DIRS.flatMap((dir) => [`${root}/**/${dir}`, `${root}/**/${dir}/**`]), ...FILES.map((file) => `${root}/**/${file}`)];
}

/** Every directory above a protected location, up to and including the roots: renaming one would move the protection away from the files. */
export function protectedAncestors(at: Places): string[] {
  const out = new Set<string>();
  for (const root of [at.repoRoot, at.dataDir]) {
    for (const path of protectedRoots(at)) {
      if (!inside(path, root)) continue;
      for (let dir = dirname(path); inside(dir, root); dir = dirname(dir)) {
        out.add(dir);
        if (dir === root) break;
      }
    }
  }
  return [...out];
}

const WRITE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit']);

export interface BoundaryEnv extends Places { cwd: string; realpath?: (path: string) => string }

/**
 * A tripwire in front of the guard, independent of it: true when a file tool would write a protected path.
 * Shell commands are not judged here: what a command does to a file cannot be told from its text, so the
 * sandbox profile refuses those writes in the kernel (see sandbox.ts).
 */
export function touchesBoundary(tool: string, input: unknown, env: BoundaryEnv): boolean {
  if (!WRITE_TOOLS.has(tool)) return false;
  const args = (typeof input === 'object' && input !== null ? input : {}) as Record<string, unknown>;
  const file = args.file_path ?? args.notebook_path;
  if (typeof file !== 'string') return false;
  const real = env.realpath ?? ((p: string) => p);
  const abs = real(resolve(env.cwd, file.replace(/^~(?=\/|$)/, env.home)));
  return protectedPath(abs, { repoRoot: real(env.repoRoot), dataDir: real(env.dataDir), home: real(env.home) });
}
