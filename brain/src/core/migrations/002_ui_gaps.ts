export default `
ALTER TABLE tasks ADD COLUMN startedAt INTEGER;
ALTER TABLE chat_messages ADD COLUMN costUsd REAL;
ALTER TABLE meetings ADD COLUMN prepStatus TEXT CHECK (prepStatus IN ('running','failed'));
ALTER TABLE meetings ADD COLUMN prepError TEXT;
ALTER TABLE jobs ADD COLUMN schedule TEXT
`;
