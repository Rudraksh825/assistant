export default `
ALTER TABLE sessions ADD COLUMN notes TEXT NOT NULL DEFAULT '';
CREATE TABLE item_context (
  id TEXT PRIMARY KEY,
  subject TEXT NOT NULL UNIQUE,
  status TEXT CHECK (status IN ('running','ok','failed')),
  body TEXT NOT NULL DEFAULT '',
  error TEXT,
  fetchedAt INTEGER,
  costUsd REAL NOT NULL DEFAULT 0,
  draftStatus TEXT CHECK (draftStatus IN ('running','ok','failed')),
  draft TEXT,
  draftApprovalId TEXT,
  draftNote TEXT,
  draftAt INTEGER,
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL
)
`;
