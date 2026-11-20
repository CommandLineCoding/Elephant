-- "Delete for everyone": the sender removes one of their own messages. The row
-- stays as a tombstone (content cleared, deleted_at set) so history keeps its
-- order and replies still point at something.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- "Delete for me": one person's view of one message. The message is skipped in
-- their history, conversation list and unread counts; everyone else still sees it.
CREATE TABLE IF NOT EXISTS message_hides (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, message_id)
);

CREATE INDEX IF NOT EXISTS idx_message_hides_message ON message_hides(message_id);
