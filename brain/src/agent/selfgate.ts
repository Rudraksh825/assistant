import { protectedRepoPath } from './boundary.js';

/**
 * A rebuild loads the agent's edits into the brain and the app, which run outside the sandbox. This looks at what
 * changed since the last build and says whether the user has to see it first. It reads text, so it catches plain code
 * and not code written to hide: `config.agent.selfModify: "ask"` is the setting that does not depend on it.
 */
export interface Flag { file: string; line: number; text: string; why: string }
export interface Review {
  /** Changed paths the agent can never write; a rebuild with any of these is refused outright. */
  protected: string[];
  flagged: Flag[];
}

const CODE = /\.(ts|tsx|mts|cts|js|mjs|cjs)$/;
const SWIFT = /\.swift$/;
const TESTS = /^(brain\/src\/test|app\/Tests)\//;
/** Files the build itself executes or obeys: any change to one is shown, whatever the change is. */
const BUILD_FILES = /(^|\/)(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|\.npmrc|\.pnpmfile\.cjs|tsconfig[^/]*\.json|Package\.swift|Package\.resolved|\.gitignore|\.gitattributes|\.swiftpm\/.*)$|^brain\/bin\/|^app\/Resources\/Info\.plist$|\.(sh|command|plist|entitlements)$/;

const RULES: [RegExp, RegExp, string][] = [
  [CODE, /\bchild_process\b|\b(spawn|spawnSync|exec|execSync|execFile|execFileSync|fork)\s*\(|\bprocess\.(binding|dlopen)\b|\bnew\s+Worker\b/, 'starts a process'],
  [CODE, /\bfetch\s*\(|['"](node:)?(http|https|http2|net|tls|dgram|dns|undici|ws)['"]|\bWebSocket\b|\bXMLHttpRequest\b|\bEventSource\b|\bsendBeacon\b/, 'opens a network connection'],
  [CODE, /@anthropic-ai\/|\bquery\s*\(|\bAnthropic\s*\(/, 'starts a model or agent run'],
  [CODE, /PreToolUse|PostToolUse|canUseTool|permissionMode|\bhooks\s*:|dangerouslyDisableSandbox|\bsandbox\b|\bdecide(Bash)?\s*\(|touchesBoundary|protectedPath|\bapprovals?\b|executeApproval|checkApproval|\.approve\s*\(|selfModify|writableRoots|\bbuiltins\b|['"]Bash['"]/, 'touches the guard, the sandbox or approvals'],
  [CODE, /\beval\s*\(|\bnew\s+Function\b|\bimport\s*\(|\brequire\s*\(|createRequire|['"](node:)?vm['"]|\bglobalThis\s*\[|\bprocess\.env\b/, 'loads code or reads the environment at run time'],
  [SWIFT, /\bProcess\s*\(|\bNSTask\b|posix_spawn|\bsystem\s*\(|\bpopen\s*\(|\bexecv|\bdlopen\s*\(|NSWorkspace\.shared\.open/, 'starts a process or another app'],
  [SWIFT, /NSAppleScript|OSAScript|NSUserAppleScriptTask|NSUserScriptTask|NSAppleEventDescriptor|CGEvent\b/, 'scripts or drives other apps'],
  [SWIFT, /NWConnection|CFSocket|CFStream|WKWebView|\bSocketPort\b/, 'opens a network connection'],
];
const SWIFT_HTTP = /URLSession|URLRequest|\bURL\s*\(\s*string\s*:/;
const LOOPBACK = /127\.0\.0\.1|localhost/;

/** Why one added line needs the user's eyes, or null. */
export function flagLine(file: string, text: string): string | null {
  if (TESTS.test(file)) return null;
  for (const [files, pattern, why] of RULES) if (files.test(file) && pattern.test(text)) return why;
  if (SWIFT.test(file) && SWIFT_HTTP.test(text) && !LOOPBACK.test(text)) return 'makes a request that is not plainly to this machine';
  return null;
}

/** Added lines of a `git diff -U0`, with their line numbers in the new file. */
export function addedLines(diff: string): { file: string; line: number; text: string }[] {
  const out: { file: string; line: number; text: string }[] = [];
  let file = '';
  let line = 0;
  for (const row of diff.split('\n')) {
    if (row.startsWith('+++ ')) file = row.slice(4).replace(/^b\//, '').replace(/\t.*$/, '');
    else if (row.startsWith('@@')) line = Number(/\+(\d+)/.exec(row)?.[1] ?? 0);
    else if (row.startsWith('+') && !row.startsWith('+++')) out.push({ file, line: line++, text: row.slice(1) });
  }
  return out;
}

/**
 * `changed`: repo-relative paths that differ from the last build. `diff`: the same change as `git diff -U0`.
 * `ignored`: git-ignored files inside the source folders, which the compiler would pick up without the diff showing them.
 */
export function review(changed: string[], diff: string, ignored: string[] = []): Review {
  const flagged: Flag[] = [];
  for (const file of changed) if (BUILD_FILES.test(file)) flagged.push({ file, line: 0, text: '', why: 'the build runs or obeys this file' });
  for (const file of ignored) flagged.push({ file, line: 0, text: '', why: 'a source file hidden from the diff by .gitignore' });
  for (const added of addedLines(diff)) {
    const why = flagLine(added.file, added.text);
    if (why) flagged.push({ ...added, text: added.text.trim().slice(0, 200), why });
  }
  return { protected: changed.filter(protectedRepoPath), flagged };
}
