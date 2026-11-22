import { tmpdir } from 'node:os';
import { basename, resolve, sep } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { PROTECTED, protectedPath, protectedRoots } from './boundary.js';

/** What one run may touch. Built per run by the runtime; `decide` itself keeps no state. */
export interface Policy {
  repoRoot: string;
  dataDir: string;
  home: string;
  /** Directory relative paths resolve against. */
  cwd: string;
  /** Extra roots the agent may write (config.agent.writableRoots). */
  writableRoots: string[];
  /** Connector tool (full `mcp__server__tool` name) → the server's read-only annotation. A tool missing here falls back to the name rules. */
  connectorReadOnly?: ReadonlyMap<string, boolean>;
  /**
   * Relay runs (approval executor, connector bridge): this call with this input and nothing else.
   * `approved` means the user approved that exact payload, which lifts the other rules for it; without it the call must still pass them.
   */
  exact?: { tool: string; input: Record<string, unknown>; approved: boolean };
  /** Allow this tool (if the other rules pass) and nothing else. */
  onlyTool?: string;
  /** Resolves symlinks so a link inside a root cannot point a write outside it. Identity when omitted. */
  realpath?: (path: string) => string;
  /** The brain's own API port: never reachable from the agent's shell, since approving is done there. */
  apiPort?: number;
  /** Where a command name resolves on the PATH the shell will use. Omitted in tests, where every binary is trusted. */
  which?: (command: string) => string | null;
}

/**
 * `allow`: runs as asked; for Bash that means outside the sandbox, so it is given only to commands recognised word for word.
 * `sandbox` (Bash only): runs with no network and writes confined to the writable roots minus the protected paths.
 * `deny`: does not run. `approvable` says the user may approve that exact payload instead.
 */
export type Decision = { verdict: 'allow' } | { verdict: 'sandbox'; why: string } | { verdict: 'deny'; reason: string; approvable: boolean };
type Deny = Extract<Decision, { verdict: 'deny' }>;

const ALLOW: Decision = { verdict: 'allow' };
export const APPROVAL_HINT = 'External writes need approval. Call steward.request_approval with the exact tool and input.';
/** An action another person or service would see: the user can approve it. */
const external = (why: string): Deny => ({ verdict: 'deny', approvable: true, reason: `${why}. ${APPROVAL_HINT}` });
/** Never allowed, approval or not. */
const forbidden = (why: string): Deny => ({ verdict: 'deny', approvable: false, reason: `${why}. This cannot be approved; do not retry it, tell the user instead.` });
const guarded = (detail = ''): Deny => ({ verdict: 'deny', approvable: false, reason: detail ? `${PROTECTED} (${detail})` : PROTECTED });
const sandbox = (why: string): Decision => ({ verdict: 'sandbox', why });

const STEWARD = 'mcp__steward__';
const SAFE_BUILTINS = new Set(['ToolSearch', 'StructuredOutput', 'Glob', 'WebSearch', 'WebFetch', 'Task', 'Agent', 'TodoWrite', 'TaskOutput', 'BashOutput', 'KillShell', 'TaskStop', 'ListMcpResourcesTool', 'ReadMcpResourceTool']);
const WRITE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit']);

export function decide(toolName: string, input: unknown, policy: Policy): Decision {
  try {
    const args = (typeof input === 'object' && input !== null ? input : {}) as Record<string, unknown>;
    if (policy.exact) {
      if (toolName === 'ToolSearch') return ALLOW;
      if (toolName !== policy.exact.tool) return forbidden(`This run may only call ${policy.exact.tool}`);
      // The relay model tends to add optional parameters; it is told the exact JSON and may try again.
      if (!isDeepStrictEqual(args, policy.exact.input)) {
        return { verdict: 'deny', approvable: false, reason: `The input must be exactly this JSON, with no added or changed fields. Call again with: ${JSON.stringify(policy.exact.input)}` };
      }
      if (policy.exact.approved) return ALLOW;
    }
    if (policy.onlyTool && toolName !== 'ToolSearch' && toolName !== policy.onlyTool) return forbidden(`This run may only call ${policy.onlyTool}`);

    if (toolName.startsWith(STEWARD)) return ALLOW;
    if (toolName.startsWith('mcp__')) return decideConnector(toolName, args, policy);
    if (SAFE_BUILTINS.has(toolName)) return ALLOW;
    if (toolName === 'Read') return decideRead(args.file_path, policy);
    if (toolName === 'Grep') return decideGrep(args.path, policy);
    if (WRITE_TOOLS.has(toolName)) return decideWrite(args.file_path ?? args.notebook_path, policy);
    if (toolName === 'Bash') return typeof args.command === 'string' ? decideBash(args.command, policy) : forbidden('Bash needs a command string');
    return forbidden(`Unknown tool ${toolName}`);
  } catch (err) {
    return forbidden(`The guard could not check this call (${(err as Error).message})`);
  }
}


const READ_VERBS = new Set(['search', 'list', 'get', 'read', 'find', 'whoami', 'view', 'describe', 'lookup', 'summary', 'transcript', 'scan', 'check', 'count', 'download']);
/** Plainly a write whatever the annotation says. */
const NEVER = new Set(['send', 'delete', 'trash', 'post', 'reply', 'forward', 'publish', 'remove', 'destroy']);
/** Write verbs. With an annotation they are checked in the verb position; without one, anywhere in the name. */
const WRITE_VERBS = new Set([
  ...NEVER, 'create', 'update', 'save', 'schedule', 'respond', 'mark', 'unmark', 'label', 'unlabel', 'merge', 'submit', 'share', 'unshare',
  'upload', 'untrash', 'add', 'set', 'write', 'edit', 'move', 'archive', 'spawn', 'stop', 'cancel', 'invite', 'apply', 'restore', 'retire',
  'rename', 'duplicate', 'copy', 'convert', 'dismiss', 'certify', 'uncertify', 'complete', 'replace', 'react',
]);
/** Ambiguous words: a read on some servers, a write on others. Only an annotation can clear them. */
const UNCLEAR = new Set(['run', 'resolve', 'prepare', 'link', 'fill', 'generate', 'use', 'bulk', 'authenticate', 'draft', 'export']);
/** Tools that pass a request through: the name says nothing about what the request does. */
const PASS_THROUGH = new Set(['fetch', 'query', 'run', 'execute', 'exec', 'call', 'invoke', 'request', 'eval', 'sql', 'graphql', 'http', 'https', 'api', 'rest', 'proxy', 'script', 'command', 'shell', 'rpc']);
const PASS_THROUGH_KEYS = /^(url|uri|endpoint|method|http_?method|verb|sql|statement|body|payload|data|headers|command|cmd|script|code|mutation)$/i;
const METHOD_KEY = /^(method|http_?method|verb|request_?method)$/i;
const BODY_KEY = /^(body|payload|data|json|form|form_?data|content)$/i;
const TARGET_KEY = /^(url|uri|endpoint)$/i;
const SQL_START = /^(select|with|insert|update|upsert|delete|drop|alter|create|truncate|replace|merge|grant|revoke|call|exec|execute|copy|begin|commit|rollback|explain|show|describe|desc|pragma|set|use|vacuum|attach|detach|analyze|refresh|lock)\b/i;
const SQL_READ_START = /^(select|with|show|describe|desc|explain)\b/i;
const SQL_WRITE = /\b(insert|update|upsert|delete|drop|alter|create|truncate|replace|merge|grant|revoke|call|exec|execute|copy|attach|detach|vacuum|refresh|lock|into)\b/i;
/** Statements recognisable as such even in a field that usually holds a search phrase. */
const SQL_SHAPED = /^(insert\s+into|delete\s+from|update\s+\S+\s+set|merge\s+into|replace\s+into|truncate\s+(table\s+)?\w|(drop|alter|create)\s+(or\s+replace\s+)?(temp(orary)?\s+)?(table|view|index|schema|database|function|procedure|trigger|role|user|materialized)\b|grant\s+\w+.*\s+to\s|revoke\s+\w+.*\s+from\s)/i;
const SQL_KEY = /^(sql|statement|stmt|sql_?query)$/i;

export function connectorWords(toolName: string): string[] {
  const [, server = '', ...rest] = toolName.split('__');
  const words = rest.join('__').replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  const serverWords = new Set(server.toLowerCase().split(/[^a-z0-9]+/));
  // "slack_read_channel" on the Slack server: the service prefix is not the verb.
  while (words.length > 1 && serverWords.has(words[0]!)) words.shift();
  return words;
}

/** What the input itself says the call does, whatever the tool is called or annotated as. */
function writeInInput(args: Record<string, unknown>, strict: boolean, depth = 0): string | null {
  const keys = Object.keys(args);
  const sendsTo = keys.some((k) => TARGET_KEY.test(k));
  for (const [key, value] of Object.entries(args)) {
    if (METHOD_KEY.test(key) && typeof value === 'string' && !/^(get|head|options)$/i.test(value.trim())) return `the input asks for ${value.trim().toUpperCase() || 'an unnamed method'}`;
    if (sendsTo && BODY_KEY.test(key) && value !== null && value !== undefined && value !== '') return 'the input carries a request body';
    if (typeof value === 'string') {
      const text = value.replace(/--[^\n]*|\/\*[\s\S]*?\*\//g, ' ').trim();
      // A field or tool made for statements is read as one; elsewhere only what cannot be a search phrase counts.
      const statement = strict || SQL_KEY.test(key) ? SQL_START.test(text) && (!SQL_READ_START.test(text) || SQL_WRITE.test(text)) : SQL_SHAPED.test(text) || (SQL_READ_START.test(text) && /;\s*\S/.test(text) && SQL_WRITE.test(text));
      if (statement) return 'the input is a statement that changes data';
      if (/^(mutation|subscription)\b/i.test(text) || /(^|[\s}])mutation\s*[\w(]*\s*[({]/i.test(text)) return 'the input is a GraphQL mutation';
    } else if (depth < 3 && typeof value === 'object' && value !== null && !Array.isArray(value)) {
      const nested = writeInInput(value as Record<string, unknown>, strict, depth + 1);
      if (nested) return nested;
    }
  }
  return null;
}

function decideConnector(toolName: string, args: Record<string, unknown>, policy: Policy): Decision {
  const words = connectorWords(toolName);
  if (!words.length) return external(`${toolName} is not a known read`);
  if (words.some((w) => NEVER.has(w))) return external(`${toolName} writes to an external service`);
  const write = writeInInput(args, words.some((w) => PASS_THROUGH.has(w)));
  if (write) return external(`${toolName} would write: ${write}`);
  const annotated = policy.connectorReadOnly?.get(toolName);
  if (annotated === true) return WRITE_VERBS.has(words[0]!) ? external(`${toolName} looks like a write`) : ALLOW;
  if (annotated === false) return external(`${toolName} is not read-only`);
  if (words.some((w) => WRITE_VERBS.has(w) || UNCLEAR.has(w))) return external(`${toolName} looks like a write`);
  if (words.some((w) => PASS_THROUGH.has(w)) || Object.keys(args).some((k) => PASS_THROUGH_KEYS.test(k))) {
    return external(`${toolName} passes a request through and its server does not mark it read-only, so its name proves nothing`);
  }
  return words.slice(0, 3).some((w) => READ_VERBS.has(w)) ? ALLOW : external(`${toolName} is not a known read`);
}


const expand = (path: string, home: string) => (path === '~' ? home : path.startsWith('~/') ? home + path.slice(1) : path);
const real = (path: string, p: Policy) => (p.realpath ? p.realpath(path) : path);
const within = (path: string, root: string) => path === root || path.startsWith(root.endsWith(sep) ? root : root + sep);
const located = (path: string, p: Policy) => real(resolve(p.cwd, expand(path, p.home)), p);
const places = (p: Policy) => ({ repoRoot: real(resolve(p.repoRoot), p), dataDir: real(resolve(p.dataDir), p), home: real(resolve(p.home), p) });
const isProtected = (abs: string, p: Policy) => protectedPath(abs, places(p));

/** The secrets file, the API token, and the API key the agent's own process carries in API billing. */
const SECRET_FILE = /(^|[/\s'"=])(secrets\.env|brain\.token)\b|ANTHROPIC_API_KEY/;
const SELF_APPROVAL = /\/approvals\/[^\s'"]*\/approve\b|\/approvals\/\S*\s+approve\b/;
const isSecret = (abs: string) => /\/(secrets\.env|brain\.token)$/.test(abs);
/** Directories any process may write, so nothing found in them can be trusted to be the owner's. */
const TEMP = ['/tmp', '/private/tmp', '/var/folders', '/private/var/folders', '/var/tmp', '/private/var/tmp', tmpdir()];

function decideRead(file: unknown, p: Policy): Decision {
  if (typeof file !== 'string') return forbidden('Read needs file_path');
  return isSecret(located(file, p)) ? forbidden('Steward secrets are not readable by the agent') : ALLOW;
}

function decideGrep(path: unknown, p: Policy): Decision {
  const abs = located(typeof path === 'string' ? path : '.', p);
  const data = real(p.dataDir, p);
  return isSecret(abs) || within(data, abs) ? forbidden('Searching here would read Steward secrets; search memory/ or a subfolder instead') : ALLOW;
}

const writableRoots = (p: Policy) => [p.repoRoot, p.dataDir, ...p.writableRoots.map((r) => expand(r, p.home))].map((r) => real(resolve(r), p));

function decideWrite(file: unknown, p: Policy): Decision {
  if (typeof file !== 'string') return forbidden('A file path is required');
  const abs = located(file, p);
  if (isSecret(abs)) return forbidden('Steward secrets are not writable by the agent');
  if (isProtected(abs, p)) return guarded();
  return writableRoots(p).some((root) => within(abs, root))
    ? ALLOW
    : forbidden(`${abs} is outside the Steward repo and data dir; the user can add a folder to config.agent.writableRoots`);
}


interface Segment {
  argv: string[];
  /** stdin comes from a pipe. */
  piped: boolean;
  /** Output redirection targets. */
  outs: string[];
  /** Here-document and here-string bodies. */
  bodies: string[];
  /** Command and process substitutions found in this segment. */
  subs: string[];
  /**
   * Every word is spelled out: bare safe characters, single-quoted text, or double-quoted text with nothing the shell
   * expands. No escapes, substitutions, globs, comments, input redirection, grouping or backgrounding. Only then is what
   * we read here certain to be what the shell runs.
   */
  literal: boolean;
}

function closing(src: string, open: number): number {
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    const c = src[i];
    if (c === '\\') i++;
    else if (c === "'") {
      i = src.indexOf("'", i + 1);
      if (i < 0) return -1;
    } else if (c === '(') depth++;
    else if (c === ')' && --depth === 0) return i;
  }
  return -1;
}

const BARE = /[A-Za-z0-9_@%+=:,./-]/;

/** Splits a shell command into simple commands. Returns null when quoting is unbalanced. */
export function lex(src: string): Segment[] | null {
  const segs: Segment[] = [];
  const fresh = (piped: boolean): Segment => ({ argv: [], piped, outs: [], bodies: [], subs: [], literal: true });
  let seg = fresh(false);
  let word: string | null = null;
  let target: '>' | '<' | '<<<' | null = null;
  const heredocs: { seg: Segment; delim: string; literal: boolean; tabs: boolean }[] = [];
  let i = 0;

  const endWord = () => {
    if (word === null) return;
    // "~name" is another user's home, which nothing here resolves.
    if (word.startsWith('~') && word !== '~' && !word.startsWith('~/')) seg.literal = false;
    if (target === '>') seg.outs.push(word);
    else if (target === '<<<') seg.bodies.push(word);
    else if (target === null) seg.argv.push(word);
    target = null;
    word = null;
  };
  const endSeg = (piped: boolean) => {
    endWord();
    segs.push(seg);
    seg = fresh(piped);
  };
  const substitution = (open: number): boolean => {
    const end = closing(src, open);
    if (end < 0) return false;
    seg.subs.push(src.slice(open + 1, end));
    seg.literal = false;
    word = (word ?? '') + '$()';
    i = end + 1;
    return true;
  };
  const backticks = (): boolean => {
    const end = src.indexOf('`', i + 1);
    if (end < 0) return false;
    seg.subs.push(src.slice(i + 1, end));
    seg.literal = false;
    word = (word ?? '') + '$()';
    i = end + 1;
    return true;
  };

  while (i < src.length) {
    const c = src[i]!;
    const next = src[i + 1];
    if (c === '\\') {
      seg.literal = false;
      if (next !== '\n') word = (word ?? '') + (next ?? '');
      i += 2;
    } else if (c === "'") {
      const end = src.indexOf("'", i + 1);
      if (end < 0) return null;
      // A quoted leading tilde is a directory named "~", which the path checks would misread as home.
      if (!word && src[i + 1] === '~') seg.literal = false;
      word = (word ?? '') + src.slice(i + 1, end);
      i = end + 1;
    } else if (c === '"') {
      if (!word && next === '~') seg.literal = false;
      word = word ?? '';
      i++;
      for (;;) {
        if (i >= src.length) return null;
        const d = src[i]!;
        if (d === '"') {
          i++;
          break;
        }
        if (d === '\\' && i + 1 < src.length) {
          seg.literal = false;
          word += src[i + 1];
          i += 2;
        } else if (d === '$' && src[i + 1] === '(') {
          if (!substitution(i + 1)) return null;
        } else if (d === '`') {
          if (!backticks()) return null;
        } else {
          if (d === '$' || d === '!') seg.literal = false;
          word += d;
          i++;
        }
      }
    } else if ((c === '$' || c === '<' || c === '>') && next === '(') {
      if (!substitution(i + 1)) return null;
    } else if (c === '`') {
      if (!backticks()) return null;
    } else if (c === '\n') {
      seg.literal = false;
      endSeg(false);
      seg.literal = false;
      i++;
      while (heredocs.length) {
        const h = heredocs.shift()!;
        const lines: string[] = [];
        while (i < src.length) {
          const eol = src.indexOf('\n', i);
          const line = src.slice(i, eol < 0 ? src.length : eol);
          i = eol < 0 ? src.length : eol + 1;
          if ((h.tabs ? line.replace(/^\t+/, '') : line) === h.delim) break;
          lines.push(line);
        }
        const body = lines.join('\n');
        h.seg.bodies.push(body);
        // An unquoted delimiter means the shell expands $(...) inside the body.
        if (!h.literal) for (const m of body.matchAll(/\$\(([^()]*)\)|`([^`]*)`/g)) h.seg.subs.push(m[1] ?? m[2] ?? '');
      }
    } else if (c === ' ' || c === '\t') {
      endWord();
      i++;
    } else if (c === '#' && word === null) {
      seg.literal = false;
      const eol = src.indexOf('\n', i);
      i = eol < 0 ? src.length : eol;
    } else if (c === ';') {
      endSeg(false);
      i += next === ';' ? 2 : 1;
    } else if (c === '&') {
      if (next === '>') {
        endWord();
        target = '>';
        i += src[i + 2] === '>' ? 3 : 2;
      } else {
        if (next !== '&') seg.literal = false;
        endSeg(false);
        i += next === '&' ? 2 : 1;
      }
    } else if (c === '|') {
      if (next === '|') {
        endSeg(false);
        i += 2;
      } else {
        endSeg(true);
        i += next === '&' ? 2 : 1;
      }
    } else if (c === '(' || c === ')') {
      seg.literal = false;
      endSeg(false);
      seg.literal = false;
      i++;
    } else if (c === '<') {
      endWord();
      seg.literal = false;
      if (src.startsWith('<<<', i)) {
        target = '<<<';
        i += 3;
      } else if (next === '<') {
        i += 2;
        const tabs = src[i] === '-';
        if (tabs) i++;
        while (src[i] === ' ') i++;
        const m = /^(?:'([^']*)'|"([^"]*)"|\\?([^\s;&|<>()]+))/.exec(src.slice(i));
        if (!m) return null;
        heredocs.push({ seg, delim: m[1] ?? m[2] ?? m[3]!, literal: m[3] === undefined || m[0].startsWith('\\'), tabs });
        i += m[0].length;
      } else {
        target = '<';
        i++;
      }
    } else if (c === '>') {
      if (word !== null && /^\d+$/.test(word)) word = null;
      endWord();
      i++;
      if (src[i] === '>' || src[i] === '|') i++;
      if (src[i] === '&') {
        i++;
        while (i < src.length && /[\d-]/.test(src[i]!)) i++;
      } else target = '>';
    } else {
      // A tilde is home only at the start of a word; anywhere else, and any other character the shell might expand, ends certainty.
      if (c === '~' ? word !== null : !BARE.test(c) || (c === '=' && word === null)) seg.literal = false;
      word = (word ?? '') + c;
      i++;
    }
  }
  endSeg(false);
  return segs.filter((s) => s.argv.length || s.subs.length || s.outs.length || s.bodies.length);
}

const MAX_DEPTH = 6;
const DYNAMIC = /[$`{*?[]/;
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*\+?=/;
const KEYWORDS = new Set(['{', '}', '!', '[', '[[', 'if', 'then', 'else', 'elif', 'fi', 'do', 'done', 'while', 'until', 'time', 'function']);
/** Commands that run the rest of their arguments as a command. Flag arity varies, so every suffix is checked. */
const WRAPPERS = new Set(['env', 'command', 'exec', 'nohup', 'nice', 'timeout', 'gtimeout', 'caffeinate', 'xargs', 'builtin', 'noglob', 'stdbuf', 'arch', 'watch', 'parallel', 'script', 'expect', 'unbuffer', 'setsid', 'chronic']);
const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh', 'fish']);
const REMOTE_SHELLS = new Set(['nc', 'ncat', 'netcat', 'telnet', 'socat', 'ssh', 'scp', 'sftp', 'ftp', 'mosh', 'mail', 'mailx', 'sendmail', 'msmtp', 'mutt', 'shortcuts']);
const LOCAL_HOST = /^(localhost|[\w-]+\.localhost|127(\.\d{1,3}){3}|::1|0\.0\.0\.0)$/i;
/** Commands whose every path operand is written, removed or changed. */
const WRITERS = new Set(['tee', 'rm', 'rmdir', 'unlink', 'touch', 'mkdir', 'chmod', 'chown', 'chgrp', 'chflags', 'truncate', 'mv', 'sponge', 'xattr']);
/** Commands that write only their last operand. */
const COPIERS = new Set(['cp', 'ln', 'install', 'rsync', 'ditto']);

function hostOf(token: string): string | null {
  if (token.startsWith(':')) return 'localhost';
  try {
    return new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(token) ? token : `http://${token}`).hostname.replace(/^\[|\]$/g, '');
  } catch {
    return null;
  }
}
const allLocal = (urls: string[]) => urls.length > 0 && urls.every((u) => LOCAL_HOST.test(hostOf(u) ?? ''));

const PUBLISHERS = /^(npm|pnpm|yarn|bun|npx|cargo|vsce|lerna|nx|poetry|flit|hatch|uv|dotnet|mvn|gradle|expo|eas|clasp)$/;
const CLOUD = /^(aws|gcloud|az|kubectl|helm|terraform|pulumi|doctl|heroku|fly|flyctl|vercel|netlify|firebase|wrangler|railway|supabase)$/;
const CLOUD_READ = /^(get|describe|list|ls|logs|show|plan|status|version|whoami|view|diff|help|top|explain|validate|fmt)$|^(describe|list|get)-/;
const COMPOSE_URL = /^(mailto|sms|imessage|tel|facetime(-audio)?|slack|msteams|whatsapp|tg|discord|skype|zoommtg|shortcuts):/i;
/** The one AppleScript that runs: a local notification with literal text. Anything else can drive other apps. */
const NOTIFICATION = /^display notification "[^"\\]*"( with title "[^"\\]*")?( subtitle "[^"\\]*")?( sound name "[^"\\]*")?$/;

export function decideBash(command: string, policy: Policy): Decision {
  const segs = lex(command);
  if (!segs) return sandbox('its quoting is unbalanced');
  return scan(segs, policy, 0) ?? outside(segs, policy);
}

/** Looks for what is recognisably not allowed. Finding nothing proves nothing: the caller sandboxes whatever is left. */
function scan(segs: Segment[], policy: Policy, depth: number): Deny | null {
  if (depth > MAX_DEPTH) return null;
  let cwd: string | null = policy.cwd;
  // What can never run outranks what the user could approve: `git push && <write to a protected path>` is not approvable.
  let approvable: Deny | null = null;
  for (const seg of segs) {
    for (const sub of seg.subs) {
      const inner = lex(sub);
      const d = inner && scan(inner, policy, depth + 1);
      if (d && !d.approvable) return d;
      approvable ??= d;
    }
    const d = scanSegment(seg, { ...policy, cwd: cwd ?? policy.cwd }, depth, cwd === null);
    if (d && !d.approvable) return d;
    approvable ??= d;
    if (seg.argv[0] === 'cd') cwd = seg.argv[1] && !DYNAMIC.test(seg.argv[1]) && cwd !== null ? resolve(cwd, expand(seg.argv[1], policy.home)) : null;
  }
  return approvable;
}

/**
 * A path the command writes. With a variable or pattern in it only the part before that is known, so the write is
 * refused when that part could still lead to a protected path.
 */
function writeTarget(raw: string, p: Policy, cwdUnknown: boolean, whole = false): Deny | null {
  if (!raw || raw === '-' || /^\/dev\/(null|stdout|stderr|tty|fd\/\d+)$/.test(raw)) return null;
  const known = raw.replace(/^\$(HOME\b|\{HOME\})/, p.home).replace(/^\$(PWD\b|\{PWD\})/, cwdUnknown ? '$PWD' : p.cwd);
  const at = known.search(DYNAMIC);
  const fixed = at < 0 ? known : known.slice(0, at);
  if (cwdUnknown && !/^[~/]/.test(fixed)) return null;
  const abs = located(fixed || '.', p);
  if (isSecret(abs)) return forbidden('Steward secrets are not writable by the agent');
  if (isProtected(abs, p)) return guarded();
  // Moving or removing a folder takes the protected files inside it along.
  if (at < 0) return whole && protectedRoots(places(p)).some((root) => within(root, abs)) ? guarded('protected files live inside this folder') : null;
  const partial = fixed !== '' && !fixed.endsWith('/');
  const reaches = protectedRoots(places(p)).some((root) => (partial ? root.startsWith(abs) : within(root, abs)));
  return reaches ? guarded('the target is built when the command runs and could be a protected path; write the path out') : null;
}

function scanSegment(seg: Segment, p: Policy, depth: number, cwdUnknown: boolean): Deny | null {
  const text = [...seg.argv, ...seg.outs].join(' ');
  if (SECRET_FILE.test(text) || seg.bodies.some((b) => SECRET_FILE.test(b))) return forbidden('Steward secrets are not readable by the agent');
  // Approving is the one thing only the user may do, and it is done over the local API.
  if (SELF_APPROVAL.test(text) || seg.bodies.some((b) => SELF_APPROVAL.test(b))) return forbidden('Approvals are the user\'s to give');
  if (p.apiPort && new RegExp(`:${p.apiPort}(?!\\d)`).test(text)) return forbidden('The Steward API is not reachable from the agent\'s shell; use the steward tools');
  for (const out of seg.outs) {
    const d = writeTarget(out, p, cwdUnknown);
    if (d) return d;
  }
  return scanArgv(seg.argv, seg, p, depth, cwdUnknown);
}

function scanArgv(input: string[], seg: Segment, p: Policy, depth: number, cwdUnknown: boolean): Deny | null {
  const argv = [...input];
  while (argv.length && (KEYWORDS.has(argv[0]!) || ASSIGNMENT.test(argv[0]!))) argv.shift();
  if (!argv.length || depth > MAX_DEPTH || DYNAMIC.test(argv[0]!)) return null;
  const cmd = basename(argv[0]!);
  const args = argv.slice(1);
  const recurse = (script: string): Deny | null => {
    const inner = lex(script);
    return inner && scan(inner, p, depth + 1);
  };
  const suffixes = (rest: string[]): Deny | null => {
    let approvable: Deny | null = null;
    for (let i = 0; i < rest.length; i++) {
      const d = scanArgv(rest.slice(i), seg, p, depth + 1, cwdUnknown);
      if (d && !d.approvable) return d;
      approvable ??= d;
    }
    return approvable;
  };
  const targets = (paths: string[], whole = false): Deny | null => {
    for (const path of paths) {
      const d = writeTarget(path, p, cwdUnknown, whole);
      if (d) return d;
    }
    return null;
  };
  const operands = args.filter((a) => !a.startsWith('-'));

  if (cmd === 'sudo' || cmd === 'doas' || cmd === 'su') return forbidden(`${cmd} is not allowed`);
  if (cmd === 'security' && args[0] !== 'find-identity') return forbidden('The keychain is off limits');
  if (cmd === 'printenv' || ((cmd === 'env' || cmd === 'set' || cmd === 'export') && args.every((a) => a.startsWith('-')))) return forbidden('Dumping the environment would print credentials');
  if (REMOTE_SHELLS.has(cmd)) return external(`${cmd} talks to another machine or person`);

  if (WRITERS.has(cmd)) {
    const d = targets(operands, cmd === 'mv' || cmd === 'rm' || cmd === 'rmdir' || cmd === 'unlink');
    if (d) return d;
  }
  if (COPIERS.has(cmd)) {
    const d = targets(operands.slice(-1));
    if (d) return d;
  }
  if (cmd === 'dd') {
    const d = targets(args.filter((a) => a.startsWith('of=')).map((a) => a.slice(3)));
    if (d) return d;
  }
  // Without a way to tell the script from the files, every operand of an in-place edit counts as a file.
  if ((cmd === 'sed' || cmd === 'gsed' || cmd === 'perl' || cmd === 'ruby') && args.some((a) => /^-[a-zA-Z]*i|^--in-place/.test(a))) {
    const d = targets(operands);
    if (d) return d;
  }

  if (WRAPPERS.has(cmd)) return suffixes(args);
  if (cmd === 'eval') return recurse(args.join(' '));
  if (cmd === 'alias') return suffixes(args.map((a) => a.replace(/^[^=]*=/, '')).flatMap((a) => a.split(/\s+/)));
  if (cmd === 'find') {
    const at = args.findIndex((a) => /^-(exec|execdir|ok|okdir)$/.test(a));
    return at < 0 ? null : suffixes(args.slice(at + 1));
  }
  if (SHELLS.has(cmd) || cmd === 'source' || cmd === '.') {
    const c = args.findIndex((a) => /^-[a-z]*c$/.test(a));
    for (const script of [...(c >= 0 && args[c + 1] !== undefined ? [args[c + 1]!] : []), ...seg.bodies]) {
      const d = recurse(script);
      if (d) return d;
    }
    return null;
  }
  if (cmd === 'osascript') {
    return notification(args) && !seg.bodies.length ? null : external('AppleScript and JXA can drive other apps, send messages and run shell commands; only a plain `display notification "…"` runs unasked');
  }

  if (cmd === 'git') return scanGit(args, suffixes, recurse);
  if (cmd === 'gh') return scanGh(args);
  if (cmd === 'curl') return scanCurl(args);
  if (cmd === 'wget') {
    const write = args.some((a) => /^--(post-data|post-file|body-data|body-file)\b/.test(a) || (/^--method\b/.test(a) && !/=(GET|HEAD)$/i.test(a)));
    return !write || allLocal(args.filter((a) => /^https?:\/\//i.test(a))) ? null : external('wget with a request body goes to a remote host');
  }
  if (cmd === 'http' || cmd === 'https' || cmd === 'xh') {
    const plain = [...operands];
    const method = /^[A-Z]+$/.test(plain[0] ?? '') ? plain.shift()! : null;
    const write = (method !== null && method !== 'GET' && method !== 'HEAD') || plain.slice(1).some((a) => /^[^=:@\s]+(:=|=(?!=)|@)/.test(a));
    return !write || allLocal(plain.slice(0, 1)) ? null : external(`${cmd} with a write method or body goes to a remote host`);
  }
  if (cmd === 'rsync' && args.some((a) => /^rsync:\/\/|^[^/\s-][^/\s]*:/.test(a))) return external('rsync to a remote host');
  if (cmd === 'open' && args.some((a) => COMPOSE_URL.test(a))) return external('Opening this URL composes a message or call in another app');

  if (PUBLISHERS.test(cmd) && args.slice(0, 4).some((a) => /^(publish|unpublish|deploy|release)$/.test(a))) return external(`${cmd} publishes outside this machine`);
  if (CLOUD.test(cmd) && !operands.slice(0, 3).some((a) => CLOUD_READ.test(a))) return external(`${cmd} changes remote infrastructure unless it is a plain read`);
  if ((cmd === 'docker' || cmd === 'podman' || cmd === 'gem' || cmd === 'pod') && args.includes('push')) return external(`${cmd} push publishes outside this machine`);
  if (cmd === 'twine' && args[0] === 'upload') return external('twine upload publishes outside this machine');

  if (cmd === 'rm') return scanRm(args, p, cwdUnknown);
  return null;
}

const GIT_VALUE_FLAGS = new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path', '--super-prefix', '--config-env', '--attr-source']);
const RUNS_COMMANDS = new Set(['submodule', 'bisect', 'rebase', 'filter-branch']);

function scanGit(args: string[], suffixes: (rest: string[]) => Deny | null, recurse: (script: string) => Deny | null): Deny | null {
  let i = 0;
  for (; i < args.length && args[i]!.startsWith('-') && args[i] !== '--version' && args[i] !== '--help'; i++) {
    if (GIT_VALUE_FLAGS.has(args[i]!)) i++;
  }
  const sub = args[i];
  const rest = args.slice(i + 1);
  if (sub === undefined) return null;
  if (sub === 'push' || sub === 'send-email' || sub === 'send-pack' || sub === 'svn' || sub === 'p4') return external(`git ${sub} publishes commits`);
  if (sub === 'remote' && rest.includes('set-url')) return external('git remote set-url changes where pushes go');
  if ((sub === 'lfs' || sub === 'subtree') && rest.includes('push')) return external(`git ${sub} push publishes commits`);
  if (RUNS_COMMANDS.has(sub)) {
    for (const a of rest) {
      const d = /\s/.test(a) ? recurse(a) : null;
      if (d) return d;
    }
    return suffixes(rest);
  }
  return null;
}

/**
 * gh subcommands that only read and only print. Left out on purpose: `pr checkout`, `repo clone`, `run download` and
 * `release download` (they write files from the network outside the sandbox) and `browse` (it opens a browser window).
 */
const GH_READS: Record<string, ReadonlySet<string> | '*'> = {
  pr: new Set(['list', 'view', 'status', 'checks', 'diff']),
  issue: new Set(['list', 'view', 'status']),
  repo: new Set(['view', 'list']),
  run: new Set(['list', 'view', 'watch']),
  workflow: new Set(['list', 'view']),
  release: new Set(['list', 'view']),
  gist: new Set(['list', 'view']),
  label: new Set(['list']),
  auth: new Set(['status']),
  cache: new Set(['list']),
  variable: new Set(['list', 'get']),
  secret: new Set(['list']),
  ruleset: new Set(['list', 'view', 'check']),
  project: new Set(['list', 'view', 'item-list', 'field-list']),
  extension: new Set(['list']),
  config: new Set(['get', 'list']),
  codespace: new Set(['list', 'view']),
  org: new Set(['list']),
  search: '*', status: '*', help: '*', version: '*',
};

function ghCommand(args: string[]): [group?: string, action?: string] {
  const plain: string[] = [];
  for (let i = 0; i < args.length && plain.length < 2; i++) {
    if (args[i] === '-R' || args[i] === '--repo') i++;
    else if (!args[i]!.startsWith('-')) plain.push(args[i]!);
  }
  return [plain[0], plain[1]];
}

function scanGh(args: string[]): Deny | null {
  const [group, action] = ghCommand(args);
  if (group === undefined) return null;
  if (group === 'api') return scanGhApi(args.slice(args.indexOf('api') + 1));
  const reads = GH_READS[group];
  if (reads === '*' || (reads && action !== undefined && reads.has(action))) return null;
  return external(`gh ${group}${action ? ` ${action}` : ''} is not a known read`);
}

function scanGhApi(args: string[]): Deny | null {
  let method: string | null = null;
  let fields = false;
  let endpoint: string | null = null;
  const values: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    const flag = /^(-X|--method)(?:=?(.+))?$/.exec(a);
    if (flag) method = (flag[2] ?? args[++i] ?? '').toUpperCase();
    else if (/^(-f|-F|--field|--raw-field)(=|$)/.test(a) || /^-[fF]./.test(a)) {
      fields = true;
      values.push(a.includes('=') && a.startsWith('--') ? a.slice(a.indexOf('=') + 1) : /^-[fF]./.test(a) ? a.slice(2) : args[++i] ?? '');
    } else if (a === '--input' || a.startsWith('--input=')) return external('gh api --input sends a request body');
    else if (/^(-H|--header|-q|--jq|-t|--template|--hostname|--cache|-p|--preview)$/.test(a)) i++;
    else if (!a.startsWith('-') && endpoint === null) endpoint = a;
  }
  if (endpoint === 'graphql') {
    const body = values.join('\n');
    return /\bmutation\b/i.test(body) || /^query=@/m.test(body) || !/^query=/m.test(body) ? external('gh api graphql may run a mutation') : null;
  }
  if (method !== null && method !== 'GET' && method !== 'HEAD') return external(`gh api ${method} writes to GitHub`);
  // Without an explicit method, fields turn the request into a POST.
  return fields && method === null ? external('gh api with fields is a POST') : null;
}

const CURL_DATA = /^(--data(-raw|-binary|-urlencode|-ascii)?|--json|--form(-string)?|--upload-file)(=|$)/;
const CURL_VALUE_LONG = new Set([
  '--header', '--output', '--user', '--user-agent', '--referer', '--cookie', '--cookie-jar', '--write-out', '--max-time', '--connect-timeout',
  '--retry', '--retry-delay', '--retry-max-time', '--proxy', '--cacert', '--cert', '--key', '--resolve', '--limit-rate', '--range', '--max-redirs',
  '--unix-socket', '--oauth2-bearer', '--interface', '--output-dir', '--ciphers', '--dns-servers',
]);
const CURL_VALUE_SHORT = 'HouAebcwmxErzYy';

function scanCurl(args: string[]): Deny | null {
  let write = false;
  const urls: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === '--url') urls.push(args[++i] ?? '');
    else if (a.startsWith('--url=')) urls.push(a.slice(6));
    else if (a === '--request' || a.startsWith('--request=')) {
      const m = a.includes('=') ? a.slice(10) : args[++i] ?? '';
      if (!/^(GET|HEAD|OPTIONS)$/i.test(m)) write = true;
    } else if (CURL_DATA.test(a)) {
      write = true;
      if (!a.includes('=')) i++;
    } else if (a.startsWith('--')) {
      if (CURL_VALUE_LONG.has(a)) i++;
    } else if (a.startsWith('-') && a.length > 1) {
      const x = a.indexOf('X');
      const letters = x >= 0 ? a.slice(1, x) : a.slice(1);
      if (/[dFT]/.test(letters)) write = true;
      if (x >= 0) {
        if (!/^(GET|HEAD|OPTIONS)$/i.test(a.slice(x + 1) || args[++i] || '')) write = true;
      } else if ('dFT'.includes(letters.at(-1)!) || CURL_VALUE_SHORT.includes(letters.at(-1)!)) i++;
    } else urls.push(a);
  }
  return !write || allLocal(urls) ? null : external('curl with a write method or request body goes to a remote host');
}

function scanRm(args: string[], p: Policy, cwdUnknown: boolean): Deny | null {
  const dashdash = args.indexOf('--');
  const flags = args.filter((a, i) => a.startsWith('-') && (dashdash < 0 || i < dashdash));
  if (!flags.some((f) => f === '--recursive' || (!f.startsWith('--') && /[rR]/.test(f)))) return null;
  const targets = args.filter((a, i) => !a.startsWith('-') || (dashdash >= 0 && i > dashdash));
  const roots = writableRoots(p);
  for (const target of targets) {
    if (/[$`]/.test(target) || (cwdUnknown && !/^[~/]/.test(target))) continue;
    // Everything from the first glob segment on is "whatever is inside": the fixed prefix is what must be in bounds.
    const parts = target.split('/');
    const glob = parts.findIndex((part) => /[*?[{]/.test(part));
    const globbed = glob >= 0;
    const abs = located((globbed ? parts.slice(0, glob) : parts).join('/') || (target.startsWith('/') ? '/' : '.'), p);
    const ok = roots.some((root) => (globbed ? within(abs, root) : abs !== root && within(abs, root)));
    if (!ok) return forbidden(`rm -r is limited to paths inside the Steward repo and data dir (${abs} is not)`);
  }
  return null;
}


/**
 * The only commands that leave the sandbox: network reads, spelled out word for word, optionally piped through a few
 * text filters. Everything here is an allowlist (commands, flags, operand shapes): what is not listed stays inside.
 */
function outside(segs: Segment[], policy: Policy): Decision {
  let p = policy;
  let reads = 0;
  for (const seg of segs) {
    const [cmd, ...args] = seg.argv;
    if (!seg.literal || seg.subs.length || seg.bodies.length) return sandbox('it uses variables, substitutions, patterns, escapes or input redirection');
    if (!cmd || !/^[a-z][a-z0-9_.-]*$/.test(cmd)) return sandbox(`${cmd ?? 'it'} is not a plain command name`);
    if (cmd === 'cd' && args.length === 1 && !seg.outs.length) {
      p = { ...p, cwd: located(args[0]!, p) };
      continue;
    }
    if (seg.outs.some((out) => out !== '/dev/null' && !writable(out, p))) return sandbox('it redirects output outside the writable folders');
    const filter = FILTERS[cmd];
    if (!(filter ? seg.piped && filter(args) : READERS[cmd]?.(args, p))) return sandbox(`${[cmd, ...args.slice(0, 2)].join(' ')} is not one of the network reads that run outside the sandbox`);
    if (p.which && !trustedBinary(cmd, p)) return sandbox(`${cmd} does not resolve to a program outside the folders the agent can write`);
    if (!filter) reads++;
  }
  return reads ? ALLOW : sandbox('it is a local command');
}

const inTemp = (abs: string, p: Policy) => TEMP.some((dir) => within(abs, dir) || within(abs, real(dir, p)));
/** A literal path the agent may write, judged like a Write call, and not somewhere a later command would trust. */
function writable(path: string, p: Policy): boolean {
  return decideWrite(path, p).verdict === 'allow' && !inTemp(located(path, p), p);
}
function trustedBinary(cmd: string, p: Policy): boolean {
  const found = p.which!(cmd);
  if (!found) return false;
  const abs = real(found, p);
  return !inTemp(abs, p) && !writableRoots(p).some((root) => within(abs, root));
}

/** A remote host by name. Addresses and local names are refused: they are how a "read" reaches a service on this machine. */
function remoteUrl(url: string, schemes = /^https?:\/\//): boolean {
  if (!schemes.test(url) || !/^[a-z]+:\/\/[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]+$/.test(url)) return false;
  const host = hostOf(url) ?? '';
  return /^([a-z0-9-]+\.)+[a-z]{2,}$/i.test(host) && !/\.(localhost|local|internal|lan|home|arpa|test|invalid)$/i.test(host);
}
const JQ_ENV = /\benv\b|\$ENV|\$__|input_filename|getpath\s*\(\s*\[\s*"env"/;

/** Walks flags against an allowlist. `takesValue` flags consume the next word (or the `=value` part); the check sees that value. */
function flagsOk(args: string[], plain: RegExp, valued: Record<string, (value: string) => boolean>): string[] | null {
  const operands: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (!a.startsWith('-') || a === '-') {
      operands.push(a);
      continue;
    }
    const eq = a.startsWith('--') ? a.indexOf('=') : -1;
    const name = eq > 0 ? a.slice(0, eq) : a;
    const check = valued[name];
    if (check) {
      const value = eq > 0 ? a.slice(eq + 1) : args[++i];
      if (value === undefined || !check(value)) return null;
    } else if (eq > 0 || !plain.test(a)) return null;
  }
  return operands;
}
const any = () => true;
const number = (v: string) => /^\d+(\.\d+)?$/.test(v);
const word = (v: string) => /^[\w./-]+$/.test(v);
const expression = (v: string) => !JQ_ENV.test(v);

function ghRead(args: string[], p: Policy): boolean {
  // gh asks git about the folder it is in, and git obeys that folder's configuration.
  if (scanGh(args) || inTemp(real(p.cwd, p), p)) return false;
  const [group] = ghCommand(args);
  if (group === undefined) return false;
  // --web opens a browser window; --show-token prints a credential; a jq or template expression can read the environment.
  if (args.some((a) => a === '--web' || a === '-w' || a === '--show-token' || (group === 'auth' && a === '-t'))) return false;
  return args.every((a, i) => (/^(-q|--jq|-t|--template)$/.test(args[i - 1] ?? '') || /^--(jq|template)=/.test(a) ? expression(a) : true));
}

const GIT_REMOTE = /^(origin|upstream)$/;
const GIT_SCP = /^[A-Za-z0-9._-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}:[A-Za-z0-9._/~-]+$/;
const gitUrl = (v: string) => remoteUrl(v, /^(https|ssh|git):\/\//) || GIT_SCP.test(v);
const gitRef = (v: string) => /^\+?[\w./-]+(:[\w./-]+)?$/.test(v) && !v.startsWith('-');

/**
 * git reads over the network. Git runs whatever its configuration names (hooks, ssh command, credential helper), so this
 * holds only where the agent cannot write that configuration: `.git` is protected inside the writable roots, bare
 * repositories are not picked up (the runtime sets safe.bareRepository=explicit), and temp directories are refused.
 */
function gitRead(args: string[], p: Policy): boolean {
  let i = 0;
  let dir = p.cwd;
  for (; args[i] === '-C' && args[i + 1] !== undefined; i += 2) dir = located(args[i + 1]!, { ...p, cwd: dir });
  const sub = args[i];
  const rest = args.slice(i + 1);
  if (inTemp(real(dir, p), p)) return false;
  if (sub === 'ls-remote') {
    const ops = flagsOk(rest, /^(--heads|--tags|--refs|--branches|--quiet|-q|-h|-t|--symref|--exit-code|--get-url)$/, { '--sort': word });
    return !!ops && (ops.length === 0 || ((GIT_REMOTE.test(ops[0]!) || gitUrl(ops[0]!)) && ops.slice(1).every(gitRef)));
  }
  if (sub === 'fetch') {
    const ops = flagsOk(rest, /^(--all|--prune|-p|--prune-tags|--tags|-t|--no-tags|--quiet|-q|--verbose|-v|--dry-run|--force|-f|--unshallow|--atomic)$/, { '--depth': number });
    return !!ops && (ops.length === 0 || ((GIT_REMOTE.test(ops[0]!) || gitUrl(ops[0]!)) && ops.slice(1).every(gitRef)));
  }
  // Pull rewrites the working tree with what it fetched, so it takes the repository's own remotes only, never a URL.
  if (sub === 'pull') {
    const ops = flagsOk(rest, /^(--ff-only|--ff|--no-ff|--rebase|--no-rebase|--prune|-p|--tags|--no-tags|--quiet|-q|--verbose|-v|--stat|--no-stat)$/, {});
    return !!ops && ops.length <= 2 && (ops.length === 0 || GIT_REMOTE.test(ops[0]!)) && ops.slice(1).every((ref) => /^[\w./-]+$/.test(ref));
  }
  if (sub === 'clone') {
    const ops = flagsOk(rest, /^(--single-branch|--no-single-branch|--no-tags|--quiet|-q|--verbose|-v|--progress|--no-checkout|-n)$/, { '--depth': number, '--branch': word, '-b': word, '--filter': (v) => /^(blob:none|tree:0)$/.test(v) });
    if (!ops || ops.length < 1 || ops.length > 2 || !gitUrl(ops[0]!)) return false;
    const target = ops[1] ?? basename(ops[0]!.replace(/\/+$/, '')).replace(/\.git$/, '');
    return /^[\w./~-]+$/.test(target) && writable(target, { ...p, cwd: dir });
  }
  return false;
}

const CURL_PLAIN = /^(-[sSLfiIvG46]+|--silent|--show-error|--location|--fail|--fail-with-body|--include|--head|--verbose|--get|--compressed|--no-progress-meter|--ipv4|--ipv6|--http1\.1|--http2)$/;
function curlRead(args: string[], p: Policy): boolean {
  const header = (v: string) => !v.startsWith('@');
  const method = (v: string) => /^(GET|HEAD)$/.test(v);
  const output = (v: string) => v === '-' || v === '/dev/null' || writable(v, p);
  const format = (v: string) => !v.startsWith('@') && !/%output|%\{stderr\}|%header/.test(v);
  const urls = flagsOk(args, CURL_PLAIN, {
    '-H': header, '--header': header, '-A': any, '--user-agent': any, '-e': any, '--referer': any, '-m': number, '--max-time': number,
    '--connect-timeout': number, '--retry': number, '--max-redirs': number, '-r': word, '--range': word, '-X': method, '--request': method,
    '-o': output, '--output': output, '-w': format, '--write-out': format, '--url': (v) => remoteUrl(v),
  });
  const named = args.filter((a, i) => args[i - 1] === '--url' || a.startsWith('--url=')).length;
  return !!urls && urls.every((u) => remoteUrl(u)) && urls.length + named > 0 && scanCurl(args) === null;
}

/** wget saves under a name the server influences unless told where to write, so an explicit `-O` is required. */
function wgetRead(args: string[], p: Policy): boolean {
  const output = (v: string) => v === '-' || v === '/dev/null' || writable(v, p);
  const joined = args.map((a) => (/^-q?O-$/.test(a) ? ['-q', '-O', '-'] : /^-qO$/.test(a) ? ['-q', '-O'] : [a])).flat();
  if (!joined.includes('-O') && !joined.some((a) => a.startsWith('--output-document'))) return false;
  const urls = flagsOk(joined, /^(-q|--quiet|-nv|--no-verbose|-S|--server-response)$/, { '-O': output, '--output-document': output, '-T': number, '--timeout': number, '--tries': number, '-t': number, '--header': (v) => !v.startsWith('@') });
  return !!urls && urls.length > 0 && urls.every((u) => remoteUrl(u));
}

const notification = (args: string[]) => args.length === 2 && args[0] === '-e' && NOTIFICATION.test(args[1]!);

const READERS: Record<string, (args: string[], p: Policy) => boolean> = { gh: ghRead, git: gitRead, curl: curlRead, wget: wgetRead, osascript: notification };

const count = (v: string) => /^[+-]?\d+$/.test(v);
const only = (plain: RegExp, valued: Record<string, (value: string) => boolean>, operands: number) => (args: string[]) => {
  const ops = flagsOk(args, plain, valued);
  return !!ops && ops.length === operands;
};
/** Text filters a network read may be piped through. They take stdin only: no file operands, no way to run a command. */
const FILTERS: Record<string, (args: string[]) => boolean> = {
  jq: (args) => {
    const ops = flagsOk(args, /^(-[rcsejSMaCn]+|--raw-output|--compact-output|--slurp|--exit-status|--join-output|--sort-keys|--monochrome-output|--tab)$/, { '--indent': count });
    return !!ops && ops.length === 1 && expression(ops[0]!);
  },
  head: only(/^-\d+$/, { '-n': count, '-c': count }, 0),
  tail: only(/^-\d+$/, { '-n': count, '-c': count }, 0),
  wc: only(/^-[lwcm]+$/, {}, 0),
  sort: only(/^-[bdfhinruV]+$/, { '-k': word, '-t': (v) => v.length === 1 }, 0),
  uniq: only(/^-[cdiu]+$/, {}, 0),
  cut: only(/^-s$/, { '-d': (v) => v.length === 1, '-f': word, '-c': word }, 0),
  tr: only(/^-[cds]+$/, {}, 2),
  grep: only(/^(-[ivcnoEFwxqhs]+|--color=never)$/, { '-m': count, '-A': count, '-B': count, '-C': count, '-e': any }, 1),
};
