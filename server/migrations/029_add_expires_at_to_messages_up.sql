-- When a disappearing message goes away. NULL means never. The sender's app
-- says how long a message lives; the server turns that into a time and deletes
-- the message then (the cleanup job), and meanwhile leaves it out of history.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_messages_expires ON messages (expires_at) WHERE expires_at IS NOT NULL;
