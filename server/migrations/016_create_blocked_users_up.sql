-- Who each user has blocked. A blocked person's direct messages, typing
-- indicators and read receipts don't reach the user who blocked them, and
-- neither sees the other's online status. Group chats are not affected.
CREATE TABLE IF NOT EXISTS blocked_users (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, blocked_user_id),
    CHECK (user_id <> blocked_user_id)
);

-- "Has anyone blocked this user?" for the contact list.
CREATE INDEX IF NOT EXISTS idx_blocked_users_blocked ON blocked_users(blocked_user_id);
