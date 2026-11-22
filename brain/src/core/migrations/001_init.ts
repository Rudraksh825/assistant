// Column names match the TypeScript field names so rows map to types without a translation layer.
// Arrays and objects are stored as JSON text.
export default `
CREATE TABLE initiatives (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  notes TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active','paused','done','dropped')),
  weight REAL NOT NULL CHECK (weight BETWEEN 0 AND 3),
  horizon TEXT,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL
);

CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  initiativeId TEXT REFERENCES initiatives(id) ON DELETE SET NULL,
  title TEXT NOT NULL,
  notes TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active','paused','done','dropped')),
  color TEXT,
  weight REAL NOT NULL CHECK (weight BETWEEN 0 AND 3),
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL
);
CREATE INDEX projects_initiative ON projects(initiativeId);

CREATE TABLE tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  notes TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('inbox','todo','doing','waiting','done','dropped')),
  priority INTEGER NOT NULL CHECK (priority IN (0,1,2,3)),
  projectId TEXT REFERENCES projects(id) ON DELETE SET NULL,
  parentId TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  dueAt INTEGER,
  scheduledFor INTEGER,
  snoozedUntil INTEGER,
  estimateMin INTEGER,
  pinned INTEGER NOT NULL,
  manualRank REAL,
  score REAL NOT NULL,
  scoreReasons TEXT NOT NULL,
  waitingOn TEXT,
  people TEXT NOT NULL,
  tags TEXT NOT NULL,
  links TEXT NOT NULL,
  source TEXT NOT NULL,
  sourceRef TEXT,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL,
  completedAt INTEGER
);
CREATE INDEX tasks_status ON tasks(status, score DESC);
CREATE INDEX tasks_project ON tasks(projectId);
CREATE INDEX tasks_due ON tasks(dueAt) WHERE dueAt IS NOT NULL;
CREATE INDEX tasks_source ON tasks(source, sourceRef);

CREATE TABLE suggestions (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('new_task','update_task','complete_task','followup','link','insight','question')),
  title TEXT NOT NULL,
  rationale TEXT NOT NULL,
  payload TEXT NOT NULL,
  source TEXT NOT NULL,
  sourceRef TEXT,
  sourceUrl TEXT,
  confidence REAL NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending','accepted','dismissed')),
  createdAt INTEGER NOT NULL,
  decidedAt INTEGER
);
CREATE INDEX suggestions_status ON suggestions(status, createdAt DESC);

CREATE TABLE signals (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  kind TEXT NOT NULL,
  externalId TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  url TEXT,
  actor TEXT,
  occurredAt INTEGER NOT NULL,
  payload TEXT NOT NULL,
  triage TEXT NOT NULL CHECK (triage IN ('new','ignored','suggested','linked')),
  processedAt INTEGER,
  UNIQUE (source, externalId)
);
CREATE INDEX signals_time ON signals(occurredAt DESC);
CREATE INDEX signals_triage ON signals(triage, occurredAt);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  pid INTEGER,
  name TEXT,
  cwd TEXT NOT NULL,
  repo TEXT,
  branch TEXT,
  ticket TEXT,
  state TEXT NOT NULL CHECK (state IN ('working','waiting','blocked','idle','ended')),
  stateSince INTEGER NOT NULL,
  title TEXT,
  lastUserPrompt TEXT,
  lastAssistantText TEXT,
  pr TEXT,
  taskId TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  startedAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL
);
CREATE INDEX sessions_state ON sessions(state, updatedAt DESC);

CREATE TABLE meetings (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL CHECK (source IN ('calendar','meeting')),
  externalId TEXT NOT NULL,
  title TEXT NOT NULL,
  startAt INTEGER NOT NULL,
  endAt INTEGER NOT NULL,
  attendees TEXT NOT NULL,
  joinUrl TEXT,
  location TEXT,
  summary TEXT,
  actionItems TEXT NOT NULL,
  recordingUrl TEXT,
  prepNote TEXT,
  updatedAt INTEGER NOT NULL,
  UNIQUE (source, externalId)
);
CREATE INDEX meetings_start ON meetings(startAt);

CREATE TABLE people (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  handles TEXT NOT NULL,
  notes TEXT NOT NULL,
  lastContactAt INTEGER
);
CREATE INDEX people_name ON people(name COLLATE NOCASE);

CREATE TABLE notes (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('live','dump','meeting','journal','brief')),
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  taskId TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  meetingId TEXT REFERENCES meetings(id) ON DELETE SET NULL,
  pinned INTEGER NOT NULL,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL
);
CREATE INDEX notes_kind ON notes(kind, updatedAt DESC);

CREATE TABLE approvals (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  summary TEXT NOT NULL,
  tool TEXT NOT NULL,
  input TEXT NOT NULL,
  preview TEXT NOT NULL,
  target TEXT,
  status TEXT NOT NULL CHECK (status IN ('pending','approved','denied','executed','failed','expired')),
  result TEXT,
  threadId TEXT,
  createdAt INTEGER NOT NULL,
  decidedAt INTEGER
);
CREATE INDEX approvals_status ON approvals(status, createdAt DESC);

CREATE TABLE nudges (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('session','meeting','task','brief','approval','question','insight','budget','system')),
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  priority INTEGER NOT NULL CHECK (priority IN (0,1,2)),
  actions TEXT NOT NULL,
  dedupeKey TEXT,
  createdAt INTEGER NOT NULL,
  expiresAt INTEGER,
  dismissedAt INTEGER
);
CREATE INDEX nudges_active ON nudges(dismissedAt, createdAt DESC);
CREATE INDEX nudges_dedupe ON nudges(dedupeKey) WHERE dedupeKey IS NOT NULL;

CREATE TABLE chat_threads (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL,
  agentSessionId TEXT
);

CREATE TABLE chat_messages (
  id TEXT PRIMARY KEY,
  threadId TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('user','assistant','tool','system')),
  text TEXT NOT NULL,
  tool TEXT,
  createdAt INTEGER NOT NULL
);
CREATE INDEX chat_messages_thread ON chat_messages(threadId, createdAt);

CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  "trigger" TEXT NOT NULL CHECK ("trigger" IN ('user','schedule','event')),
  model TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('running','ok','error','cancelled')),
  inputTokens INTEGER NOT NULL,
  outputTokens INTEGER NOT NULL,
  costUsd REAL NOT NULL,
  billing TEXT NOT NULL CHECK (billing IN ('api','login')),
  summary TEXT,
  startedAt INTEGER NOT NULL,
  endedAt INTEGER
);
CREATE INDEX runs_started ON runs(startedAt DESC);

CREATE TABLE activity (
  id TEXT PRIMARY KEY,
  app TEXT NOT NULL,
  bundleId TEXT,
  title TEXT,
  startAt INTEGER NOT NULL,
  endAt INTEGER NOT NULL,
  idle INTEGER NOT NULL,
  sessionId TEXT,
  taskId TEXT REFERENCES tasks(id) ON DELETE SET NULL
);
CREATE INDEX activity_time ON activity(startAt, endAt);

CREATE TABLE jobs (
  name TEXT PRIMARY KEY,
  enabled INTEGER NOT NULL,
  lastRunAt INTEGER,
  lastStatus TEXT
);

CREATE TABLE kv (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updatedAt INTEGER NOT NULL
);
`;
